//  UpdateChecker.swift
//  Scrcpy
//

import CryptoKit
import Foundation

struct ReleaseInfo {
    /// 去掉 `v` 前缀的版本号，例如 `5.0.2`。
    let version: String
    /// release 的 tag，例如 `v5.0.2`。
    let tag: String
    let assetName: String
    let assetURL: URL
    let sumsURL: URL?
    let notes: String?
}

enum UpdateError: LocalizedError {
    case network(String)
    case rateLimited
    case noMatchingAsset
    case checksumMismatch(expected: String, actual: String)
    case extractFailed(String)
    case smokeTestFailed(String)
    case cancelled

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
        case .cancelled:
            return "已取消。"
        }
    }
}

/// 从官方 release 检查并下载新引擎。
final class UpdateChecker {

    enum CheckResult {
        case upToDate(current: String)
        case available(ReleaseInfo)
        case notModified(current: String)
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/Genymobile/scrcpy/releases/latest")!
    private static let etagKey = "update.etag"
    /// 带在请求上的 UA。GitHub 的 API 对**没有** User-Agent 的请求直接返 403，
    /// 不设这个头就永远走不到 200/304 分支上去。
    private static let userAgent = "Scrcpy-macOS"

    private let lock = NSLock()
    private var currentDownload: DownloadDelegate?

    // MARK: - 检查

    /// 查询最新 release。带 ETag 缓存：命中时 GitHub 返 304 且不计入配额。
    func check(current: String, completion: @escaping (Result<CheckResult, Error>) -> Void) {
        var request = URLRequest(url: UpdateChecker.apiURL)
        request.timeoutInterval = 15
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag = UserDefaults.standard.string(forKey: UpdateChecker.etagKey), !etag.isEmpty {
            // 原样带上，不要剥掉 `W/` 前缀：GitHub 返回的是弱 ETag，
            // 去掉前缀服务端就不认了，每次都变成全量请求，白白吃配额。
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<CheckResult, Error>
            if let self {
                result = self.evaluate(data: data, response: response, error: error, current: current)
            } else {
                result = .failure(UpdateError.network("更新器已释放。"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func evaluate(data: Data?, response: URLResponse?, error: Error?, current: String) -> Result<CheckResult, Error> {
        if let error {
            return .failure(UpdateError.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(UpdateError.network("服务器没有返回可识别的响应。"))
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
                return .failure(UpdateError.rateLimited)
            }
            return .failure(UpdateError.network("GitHub 拒绝了请求（HTTP \(http.statusCode)）。"))

        default:
            return .failure(UpdateError.network("GitHub 返回了 HTTP \(http.statusCode)。"))
        }

        guard let data else {
            return .failure(UpdateError.network("响应内容为空。"))
        }
        // 200 的 ETag 才是这次内容对应的，存下来供下次 If-None-Match。
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            UserDefaults.standard.set(etag, forKey: UpdateChecker.etagKey)
        }

        do {
            let info = try UpdateChecker.parseRelease(data: data)
            return UpdateChecker.isNewer(info.version, than: current)
                ? .success(.available(info))
                : .success(.upToDate(current: current))
        } catch {
            return .failure(error)
        }
    }

    private static func parseRelease(data: Data) throws -> ReleaseInfo {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UpdateError.network("无法解析 GitHub 的返回内容。")
        }
        guard let tag = root["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateError.noMatchingAsset
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
            throw UpdateError.noMatchingAsset
        }

        // SHA256SUMS.txt 优先用资产列表里那一条的真地址；
        // 万一官方改了命名，就按同目录反推一个，别因此断定「没有可用包」。
        let sumsURL = url(ofAssetNamed: "SHA256SUMS.txt")
            ?? assetURL.deletingLastPathComponent().appendingPathComponent("SHA256SUMS.txt")

        return ReleaseInfo(version: version,
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
    func download(_ info: ReleaseInfo,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<URL, Error>) -> Void) {

        var request = URLRequest(url: info.assetURL)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        // 引擎包三十多 MB，慢网络下按默认的请求超时会在下载中途被掐断。
        request.timeoutInterval = 60

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300

        let delegate = DownloadDelegate(progress: { value in
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
        currentDownload = delegate
        lock.unlock()

        delegate.start(request: request, configuration: config)
    }

    func cancel() {
        lock.lock()
        let delegate = currentDownload
        lock.unlock()
        delegate?.cancel()
    }

    /// 把下载下来的压缩包变成一份可用的引擎目录。
    private func prepareStaging(from archive: URL, info: ReleaseInfo) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }

        // 1. 校验。用 CryptoKit 流式算，不 shell 出去跑 shasum ——
        //    少一个外部依赖，也不用处理引号和 PATH。
        let expected = try fetchExpectedChecksum(info: info)
        let actual = try sha256(of: archive)
        guard expected == actual else {
            throw UpdateError.checksumMismatch(expected: expected, actual: actual)
        }

        // 2. 解压
        let workDir = fm.temporaryDirectory.appendingPathComponent("scrcpy-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let tar = Shell.run(URL(fileURLWithPath: "/usr/bin/tar"),
                            ["-xzf", archive.path, "-C", workDir.path],
                            timeout: 180)
        guard tar.ok else {
            throw UpdateError.extractFailed(tar.output.trimmingCharacters(in: .whitespacesAndNewlines))
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
            throw UpdateError.extractFailed("压缩包结构不符合预期（顶层有 \(directories.count) 个目录）。")
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
            throw UpdateError.smokeTestFailed(detail.isEmpty
                                              ? "下载的引擎执行 --version 失败（退出码 \(probe.status)）。"
                                              : "下载的引擎执行 --version 失败：\(detail)")
        }

        return staging
    }

    private func fetchExpectedChecksum(info: ReleaseInfo) throws -> String {
        guard let sumsURL = info.sumsURL else { throw UpdateError.noMatchingAsset }

        var request = URLRequest(url: sumsURL)
        request.timeoutInterval = 15
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")

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

        if let failure { throw UpdateError.network(failure.localizedDescription) }
        guard let payload, let text = String(data: payload, encoding: .utf8) else {
            throw UpdateError.network("无法读取 SHA256SUMS.txt。")
        }

        for line in text.split(separator: "\n") {
            // 格式精确为「<64位小写hex><两个空格><文件名>」。
            // 按空白切分后拿第二列做**全等**比较：用 contains 或 hasSuffix 的话，
            // scrcpy-macos-aarch64-v5.0.1.tar.gz 会匹到 v5.0.10.tar.gz 那一行上去。
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, String(fields[1]) == info.assetName else { continue }
            let hex = String(fields[0]).lowercased()
            guard hex.count == 64 else { continue }
            return hex
        }
        throw UpdateError.noMatchingAsset
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        // 分块读，不把三十多 MB 一次性读进内存。这只在更新时跑一次，
        // 但没有理由让它成为整个 App 的峰值内存。
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 版本比较

    /// 语义化比较，逐段按整数比。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = numericSegments(a)
        let rhs = numericSegments(b)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func numericSegments(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // 必须逐段转整数再比。按字符串比的话 "5.0.10" < "5.0.9"，
        // 而 scrcpy 确实走到过 5.0.10 这种段号。
        return text.split(separator: ".").map { field in
            // 段里可能混着预发布后缀（"5.1.0-rc1"），取数字前缀；取不到当 0。
            Int(field.prefix { $0.isNumber }) ?? 0
        }
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

/// 下载任务的委托。单独一个对象是为了避开 `URLSession` 强引用 delegate、
/// delegate 又持有 session 造成的循环引用。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    private let onProgress: (Double) -> Void
    private let onFinish: (Result<URL, Error>) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    /// `didCompleteWithError` 保证会被调用，而 `didFinishDownloadingTo` 不一定。
    /// 用它做唯一出口，保证回调只发一次。
    private var finished = false
    private var downloaded: URL?
    private var failure: Error?

    private var lastReported = 0.0

    init(progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = progress
        self.onFinish = completion
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // 按 1% 粒度节流。每来一块数据就回一次主线程，会把主线程淹掉，
        // 而进度条根本分辨不出这 0.1% 的差别。
        guard value - lastReported >= 0.01 || value >= 1.0 else { return }
        lastReported = value
        onProgress(value)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 这个方法一返回，系统就把 location 上的临时文件删了，所以必须在这里搬走。
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrcpy-download-\(UUID().uuidString)")
            .appendingPathComponent(downloadTask.response?.suggestedFilename ?? "engine.tar.gz")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            downloaded = destination
        } catch {
            failure = UpdateError.network("保存下载文件失败：\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        session.finishTasksAndInvalidate()

        let result: Result<URL, Error>
        if let error {
            let code = (error as NSError).code
            // 用户主动取消不是故障，单独一个 case，免得弹一条吓人的错误。
            result = .failure(code == NSURLErrorCancelled ? UpdateError.cancelled : UpdateError.network(error.localizedDescription))
        } else if let failure {
            result = .failure(failure)
        } else if let downloaded {
            result = .success(downloaded)
        } else {
            result = .failure(UpdateError.network("下载结束但没有拿到文件。"))
        }
        onFinish(result)
    }
}
