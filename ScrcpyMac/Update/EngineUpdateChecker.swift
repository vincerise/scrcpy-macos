//  EngineUpdateChecker.swift
//  ScrcpyMac
//

import Foundation

struct EngineReleaseInfo {
    /// 去掉 `v` 前缀的版本号，例如 `5.0.2`。
    let version: String
    /// release 的 tag，例如 `v5.0.2`。
    let tag: String
    let assetName: String
    let assetURL: URL
    let sumsURL: URL?
    let notes: String?
}

enum EngineUpdateError: LocalizedError {
    case network(String)
    case rateLimited
    case noMatchingAsset
    case checksumMismatch(expected: String, actual: String)
    case extractFailed(String)
    case smokeTestFailed(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .rateLimited:
            // GitHub 对未认证请求限 60 次/小时，这是最容易被用户撞上的失败，
            // 所以文案要说清楚「等一会儿」而不是让人以为网络坏了。
            return "GitHub 的匿名访问额度用完了（每小时 60 次），过一会儿再试。"
        case .noMatchingAsset:
            return "这个 release 里没有适配本机架构的 macOS 包。"
        case .checksumMismatch(let expected, let actual):
            return "下载的文件校验不通过（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        case .extractFailed(let detail):
            return detail.isEmpty ? "解压失败。" : "解压失败：\(detail)"
        case .smokeTestFailed(let detail):
            return detail.isEmpty ? "下载的引擎无法运行。" : detail
        }
    }
}

/// 从官方 release 检查并下载新引擎。
final class EngineUpdateChecker {

    enum CheckResult {
        case upToDate(current: String)
        case available(EngineReleaseInfo)
        case notModified(current: String)
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/Genymobile/scrcpy/releases/latest")!
    private static let etagKey = "update.etag"
    /// 上一次成功解析出来的最新版本号。304 只说明「资源没变」，
    /// 而调用方可能已经比上次更旧（比如删掉了本地引擎），得靠它判断要不要重取正文。
    private static let lastVersionKey = "update.last-version"
    /// 带在请求上的 UA。GitHub 的 API 对**没有** User-Agent 的请求直接返 403，
    /// 不设这个头就永远走不到 200/304 分支上去。
    private static let userAgent = "ScrcpyMac/\(AppInfo.version)"

    private let lock = NSLock()
    private var currentDownload: UpdateDownloader?

    // MARK: - 检查

    /// 查询最新 release。带 ETag 缓存：命中时 GitHub 返 304 且不计入配额。
    func check(current: String, completion: @escaping (Result<CheckResult, Error>) -> Void) {
        check(current: current, allowRetry: true, completion: completion)
    }

    private func check(current: String,
                       allowRetry: Bool,
                       completion: @escaping (Result<CheckResult, Error>) -> Void) {
        var request = URLRequest(url: EngineUpdateChecker.apiURL)
        request.timeoutInterval = 15
        request.setValue(EngineUpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 重试那一次必须不带条件头，否则服务端仍然回 304，拿不到正文。
        if allowRetry,
           let etag = UserDefaults.standard.string(forKey: EngineUpdateChecker.etagKey), !etag.isEmpty {
            // 原样带上，不要剥掉 `W/` 前缀：GitHub 返回的是弱 ETag，
            // 去掉前缀服务端就不认了，每次都变成全量请求，白白吃配额。
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(EngineUpdateError.network("更新器已释放。")))
                }
                return
            }
            let result = self.evaluate(data: data, response: response, error: error, current: current)

            // 304 意味着「自上次缓存以来没变」。如果上次缓存到的版本比当前版本新
            // （用户删掉了引擎、或者没装更新就重启了旧版本），光拿 304 会误报
            // 「已是最新」。这时去掉 If-None-Match 再要一次正文。
            if case .success(.notModified(let version)) = result,
               allowRetry,
               let last = UserDefaults.standard.string(forKey: EngineUpdateChecker.lastVersionKey),
               Version.isNewer(last, than: version) {
                self.check(current: current, allowRetry: false, completion: completion)
                return
            }

            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func evaluate(data: Data?, response: URLResponse?, error: Error?, current: String) -> Result<CheckResult, Error> {
        if let error {
            return .failure(EngineUpdateError.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(EngineUpdateError.network("服务器没有返回可识别的响应。"))
        }

        switch http.statusCode {
        case 304:
            // 内容没变，我们拿不到新的 tag，保持当前版本号即可。
            return .success(.notModified(current: current))

        case 200:
            break

        case 403, 429:
            // 额度耗尽时 GitHub 用 403（偶尔 429）并带这个头说明原因。
            // 不区分的话用户会以为是网络问题，一直重试。
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                return .failure(EngineUpdateError.rateLimited)
            }
            return .failure(EngineUpdateError.network("GitHub 拒绝了请求（HTTP \(http.statusCode)）。"))

        default:
            return .failure(EngineUpdateError.network("GitHub 返回了 HTTP \(http.statusCode)。"))
        }

        guard let data else {
            return .failure(EngineUpdateError.network("响应内容为空。"))
        }

        do {
            let info = try EngineUpdateChecker.parseRelease(data: data)
            // ETag 和版本号只在解析成功之后才落盘。先存 ETag 再去解析的话，
            // 一次坏的响应会把缓存绑到一份永远解析不出来的正文上。
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                UserDefaults.standard.set(etag, forKey: EngineUpdateChecker.etagKey)
            } else {
                UserDefaults.standard.removeObject(forKey: EngineUpdateChecker.etagKey)
            }
            UserDefaults.standard.set(info.version, forKey: EngineUpdateChecker.lastVersionKey)
            return Version.isNewer(info.version, than: current)
                ? .success(.available(info))
                : .success(.upToDate(current: current))
        } catch {
            return .failure(error)
        }
    }

    private static func parseRelease(data: Data) throws -> EngineReleaseInfo {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EngineUpdateError.network("无法解析 GitHub 的返回内容。")
        }
        guard let tag = root["tag_name"] as? String, !tag.isEmpty else {
            throw EngineUpdateError.noMatchingAsset
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = (root["assets"] as? [[String: Any]]) ?? []

        func url(ofAssetNamed name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }

        let wanted = "scrcpy-macos-\(assetArchSuffix)-v\(version).tar.gz"
        guard let assetURL = url(ofAssetNamed: wanted) else {
            throw EngineUpdateError.noMatchingAsset
        }

        // SHA256SUMS.txt 优先用资产列表里那一条的真地址；
        // 万一官方改了命名，就按同目录反推一个，别因此断定「没有可用包」。
        let sumsURL = url(ofAssetNamed: "SHA256SUMS.txt")
            ?? assetURL.deletingLastPathComponent().appendingPathComponent("SHA256SUMS.txt")

        return EngineReleaseInfo(version: version,
                                 tag: tag,
                                 assetName: wanted,
                                 assetURL: assetURL,
                                 sumsURL: sumsURL,
                                 notes: root["body"] as? String)
    }

    // MARK: - 下载

    /// 下载 → 校验 SHA256 → 解压 → 清隔离属性 → 冒烟，返回可直接交给
    /// `EngineStore.install(from:)` 的暂存目录（顶层就是引擎文件本身）。
    ///
    /// 返回的目录不会被自动清理，调用方装完之后自行删掉。
    func download(_ info: EngineReleaseInfo,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<URL, Error>) -> Void) {

        var request = URLRequest(url: info.assetURL)
        request.setValue(EngineUpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        // 引擎包三十多 MB，慢网络下按默认的请求超时会在下载中途被掐断。
        request.timeoutInterval = 60

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let downloader = UpdateDownloader(progress: { value in
            // 契约要求进度回主线程；UI 那边还会再包一层，多这一次 dispatch 无副作用。
            DispatchQueue.main.async { progress(value) }
        }, completion: { [weak self] result in
            guard let self else { return }
            // 校验、解压、冒烟都是阻塞操作，放到后台去做，别占着 delegate 队列。
            DispatchQueue.global(qos: .userInitiated).async {
                let final: Result<URL, Error>
                switch result {
                case .success(let file):
                    do {
                        final = .success(try self.prepareStaging(from: file, info: info))
                    } catch {
                        final = .failure(error)
                    }
                case .failure(let error):
                    final = .failure(error)
                }
                self.lock.lock()
                self.currentDownload = nil
                self.lock.unlock()
                DispatchQueue.main.async { completion(final) }
            }
        })

        lock.lock()
        currentDownload = downloader
        lock.unlock()

        downloader.start(request: request, configuration: config)
    }

    func cancel() {
        lock.lock()
        let downloader = currentDownload
        lock.unlock()
        downloader?.cancel()
    }

    /// 把下载下来的压缩包变成一份可用的引擎目录。
    private func prepareStaging(from archive: URL, info: EngineReleaseInfo) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }

        // 1. 校验。用 CryptoKit 流式算，不 shell 出去跑 shasum ——
        //    少一个外部依赖，也不用处理引号和 PATH。
        let expected = try fetchExpectedChecksum(info: info)
        let actual = try FileDigest.sha256(of: archive)
        guard expected == actual else {
            throw EngineUpdateError.checksumMismatch(expected: expected, actual: actual)
        }

        // 2. 解压
        let workDir = fm.temporaryDirectory.appendingPathComponent("scrcpy-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let tar = Shell.run(URL(fileURLWithPath: "/usr/bin/tar"),
                            ["-xzf", archive.path, "-C", workDir.path],
                            timeout: 180)
        guard tar.ok else {
            throw EngineUpdateError.extractFailed(tar.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 3. 归一化目录名。tarball 顶层是单个 `scrcpy-macos-<arch>-v<ver>/`，
        //    必须把它抹掉 —— 否则 EngineStore 会把这一层目录名一起装进 engine/，
        //    而我们所有路径都按「engine/ 下直接放着 scrcpy」来拼。
        let entries = try fm.contentsOfDirectory(at: workDir,
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [])
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard directories.count == 1 else {
            throw EngineUpdateError.extractFailed("压缩包结构不符合预期（顶层有 \(directories.count) 个目录）。")
        }

        let stagingParent = fm.temporaryDirectory.appendingPathComponent("scrcpy-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingParent, withIntermediateDirectories: true)
        let staging = stagingParent.appendingPathComponent("staging", isDirectory: true)
        try fm.moveItem(at: directories[0], to: staging)

        // 4. 清隔离属性。不清的话 Gatekeeper 会对嵌套的 scrcpy/adb 单独评估，
        //    用户看到的是「无法验证开发者」。
        Xattr.strip(staging)
        for name in ["scrcpy", "adb"] {
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: staging.appendingPathComponent(name).path)
        }

        // 5. 冒烟。装进 App 之前先确认这份引擎真的跑得起来 ——
        //    装完才发现是坏的，就得靠回滚，而回滚不如不装。
        guard EngineStore.smokeTest(scrcpyAt: staging.appendingPathComponent("scrcpy")) != nil else {
            let probe = Shell.run(staging.appendingPathComponent("scrcpy"), ["--version"], timeout: 15)
            let detail = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineUpdateError.smokeTestFailed(detail.isEmpty
                                                    ? "下载的引擎执行 --version 失败（退出码 \(probe.status)）。"
                                                    : "下载的引擎执行 --version 失败：\(detail)")
        }

        return staging
    }

    private func fetchExpectedChecksum(info: EngineReleaseInfo) throws -> String {
        guard let sumsURL = info.sumsURL else { throw EngineUpdateError.noMatchingAsset }

        var request = URLRequest(url: sumsURL)
        request.timeoutInterval = 15
        request.setValue(EngineUpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")

        // 这里同步等一次：整个 prepareStaging 已经在后台线程上跑了，
        // 而 SHA256SUMS.txt 只有几百字节。
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            payload = data
            failure = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)

        if let failure { throw EngineUpdateError.network(failure.localizedDescription) }
        guard let payload, let text = String(data: payload, encoding: .utf8) else {
            throw EngineUpdateError.network("无法读取 SHA256SUMS.txt。")
        }

        for line in text.split(separator: "\n") {
            // 格式精确为「<64位小写hex><两个空格><文件名>」。
            // 按空白切分后拿第二列做**全等**比较：用 contains 或 hasSuffix 的话，
            // scrcpy-macos-aarch64-v5.0.1.tar.gz 会匹到 v5.0.10.tar.gz 那一行上去。
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, String(fields[1]) == info.assetName else { continue }
            let hex = String(fields[0]).lowercased()
            guard FileDigest.isHex64(hex) else { continue }
            return hex
        }
        throw EngineUpdateError.noMatchingAsset
    }

    /// 官方 release 的资产名里用的架构写法。
    static var assetArchSuffix: String {
        #if arch(arm64)
        return "aarch64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        // 既不是 arm64 也不是 x86_64。工程只构建这两个 slice，
        // 走不到这里，但留个运行期判断好过猜一个然后下错架构的包。
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.hasPrefix("arm") ? "aarch64" : "x86_64"
        #endif
    }
}
