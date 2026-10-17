//  AppUpdateChecker.swift
//  ScrcpyMac
//

import Foundation

struct AppReleaseInfo {
    /// 去掉 `v` 前缀的版本号，例如 `0.2.0`。
    let version: String
    /// release 的 tag，例如 `v0.2.0`。
    let tag: String
    let assetName: String
    let assetURL: URL
    /// GitHub release asset 自带的 `sha256:<hex>`；老资产可能没有。
    let digest: String?
    /// 同 release 的 SHA256SUMS.txt；没有也不影响（有 digest 就够了）。
    let sumsURL: URL?
    let notes: String?
}

enum AppUpdateError: LocalizedError {
    case network(String)
    case rateLimited
    case noMatchingAsset
    case checksumMissing
    case checksumMismatch(expected: String, actual: String)
    case checksumConflict(expected: String, actual: String)
    case extractFailed(String)
    case invalidBundle(String)
    case codeSignature(String)
    case unsupportedSystem(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .rateLimited:
            return "GitHub 的匿名访问额度用完了（每小时 60 次），过一会儿再试。"
        case .noMatchingAsset:
            return "这个 release 里没有找到 ScrcpyMac 的 macOS 通用包。"
        case .checksumMissing:
            return "release 里没有可用的 SHA256 校验信息，已拒绝安装。"
        case .checksumMismatch(let expected, let actual):
            return "下载的文件校验不通过（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        case .checksumConflict(let expected, let actual):
            return "release 里的两份 SHA256 不一致（API \(expected.prefix(12))…，SHA256SUMS.txt \(actual.prefix(12))…），已拒绝安装。"
        case .extractFailed(let detail):
            return detail.isEmpty ? "解压失败。" : "解压失败：\(detail)"
        case .invalidBundle(let detail):
            return detail.isEmpty ? "下载的 App 结构不正确。" : "下载的 App 结构不正确：\(detail)"
        case .codeSignature(let detail):
            return detail.isEmpty ? "下载的 App 签名校验失败。" : "下载的 App 签名校验失败：\(detail)"
        case .unsupportedSystem(let requirement):
            return "新版本需要 macOS \(requirement) 或更高版本，当前系统版本不够。"
        }
    }
}

/// 从 `vincerise/scrcpy-macos` 检查并下载 App 本体更新。
///
/// 和引擎更新器的区别：这里的产物是一个完整的 `.app`，下载之后还要交给
/// `AppInstaller` 做原子替换。校验因此更严——签名、bundle id、版本号、
/// 架构、最低系统版本缺一不可。
final class AppUpdateChecker {

    enum CheckResult {
        case upToDate(current: String)
        case available(AppReleaseInfo)
        case notModified(current: String)
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/vincerise/scrcpy-macos/releases/latest")!
    private static let etagKey = "app.update.etag"
    private static let lastVersionKey = "app.update.last-version"

    private static var userAgent: String { "ScrcpyMac/\(AppInfo.version)" }

    private let lock = NSLock()
    private var currentDownload: UpdateDownloader?

    // MARK: - 检查

    func check(current: String, completion: @escaping (Result<CheckResult, Error>) -> Void) {
        check(current: current, allowRetry: true, completion: completion)
    }

    private func check(current: String,
                       allowRetry: Bool,
                       completion: @escaping (Result<CheckResult, Error>) -> Void) {
        var request = URLRequest(url: AppUpdateChecker.apiURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppUpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // 重试那一次必须不带条件头，否则服务端仍然回 304，拿不到正文。
        if allowRetry,
           let etag = UserDefaults.standard.string(forKey: AppUpdateChecker.etagKey), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(AppUpdateError.network("更新器已释放。")))
                }
                return
            }
            let result = self.evaluate(data: data, response: response, error: error, current: current)

            // 和引擎更新器同一个理由：304 只说明资源没变，不代表调用方的版本
            // 一定已经是最新的。缓存里的版本更新时，去掉条件头再取一次正文。
            if case .success(.notModified(let version)) = result,
               allowRetry,
               let last = UserDefaults.standard.string(forKey: AppUpdateChecker.lastVersionKey),
               Version.isNewer(last, than: version) {
                self.check(current: current, allowRetry: false, completion: completion)
                return
            }

            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func evaluate(data: Data?, response: URLResponse?, error: Error?, current: String) -> Result<CheckResult, Error> {
        if let error {
            return .failure(AppUpdateError.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(AppUpdateError.network("服务器没有返回可识别的响应。"))
        }

        switch http.statusCode {
        case 304:
            return .success(.notModified(current: current))
        case 200:
            break
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                return .failure(AppUpdateError.rateLimited)
            }
            return .failure(AppUpdateError.network("GitHub 拒绝了请求（HTTP \(http.statusCode)）。"))
        default:
            return .failure(AppUpdateError.network("GitHub 返回了 HTTP \(http.statusCode)。"))
        }

        guard let data else {
            return .failure(AppUpdateError.network("响应内容为空。"))
        }

        do {
            let info = try AppUpdateChecker.parseRelease(data: data)
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                UserDefaults.standard.set(etag, forKey: AppUpdateChecker.etagKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppUpdateChecker.etagKey)
            }
            UserDefaults.standard.set(info.version, forKey: AppUpdateChecker.lastVersionKey)
            return Version.isNewer(info.version, than: current)
                ? .success(.available(info))
                : .success(.upToDate(current: current))
        } catch {
            return .failure(error)
        }
    }

    private static func parseRelease(data: Data) throws -> AppReleaseInfo {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppUpdateError.network("无法解析 GitHub 的返回内容。")
        }
        guard let tag = root["tag_name"] as? String, !tag.isEmpty else {
            throw AppUpdateError.noMatchingAsset
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Version.isReleaseVersion(version) else {
            throw AppUpdateError.noMatchingAsset
        }

        let assets = (root["assets"] as? [[String: Any]]) ?? []
        func findAsset(named name: String) -> [String: Any]? {
            assets.first { ($0["name"] as? String) == name }
        }

        let wanted = "ScrcpyMac-v\(version)-macos-universal.zip"
        guard let assetInfo = findAsset(named: wanted),
              let urlText = assetInfo["browser_download_url"] as? String,
              let assetURL = URL(string: urlText) else {
            throw AppUpdateError.noMatchingAsset
        }

        // API 的 digest 可能是 null（老资产、或用其他方式上传的资产），
        // 也可能哪天换成别的算法。只认 sha256:<64hex>，其余一律当没有。
        var digest: String?
        if let raw = assetInfo["digest"] as? String {
            let lower = raw.lowercased()
            let prefix = "sha256:"
            if lower.hasPrefix(prefix) {
                let hex = String(lower.dropFirst(prefix.count))
                if FileDigest.isHex64(hex) { digest = hex }
            }
        }

        let sumsURL = findAsset(named: "SHA256SUMS.txt")
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))

        return AppReleaseInfo(version: version,
                              tag: tag,
                              assetName: wanted,
                              assetURL: assetURL,
                              digest: digest,
                              sumsURL: sumsURL,
                              notes: root["body"] as? String)
    }

    // MARK: - 下载与校验

    /// 下载 → 校验 → 解压 → 验证 bundle，返回暂存区里的 `.app`。
    ///
    /// 暂存区留在 `AppPaths.updateDir` 下，直到安装完成或用户放弃更新。
    func download(_ info: AppReleaseInfo,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<URL, Error>) -> Void) {

        var request = URLRequest(url: info.assetURL)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppUpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let downloader = UpdateDownloader(progress: { value in
            DispatchQueue.main.async { progress(value) }
        }, completion: { [weak self] result in
            guard let self else { return }
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

    /// 丢掉一份已经下载但还没安装的暂存 App。
    ///
    /// 路径是 `<updateDir>/stage-<uuid>/extract/ScrcpyMac.app`，
    /// 往上两级才是整个 stage 目录。
    func discard(_ stagedApp: URL) {
        let stage = stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: stage)
    }

    /// 启动时清掉上次中断留下的暂存目录。
    ///
    /// 只删一小时前的：同一个 App 的另一个实例可能正在下载或已经下好等着安装，
    /// 无差别删除会把它的进度或「重启并更新」弄坏。真正等待安装的那份在本进程
    /// 的生命周期内，退出后重来一次也只是重新下载 1.4MB。
    func cleanupStaleStaging() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        guard let entries = try? fm.contentsOfDirectory(at: AppPaths.updateDir,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: []) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("stage-") {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private func prepareStaging(from archive: URL, info: AppReleaseInfo) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }

        try fm.createDirectory(at: AppPaths.updateDir, withIntermediateDirectories: true)
        let stage = AppPaths.updateDir.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        let extract = stage.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)

        do {
            let expected = try expectedDigest(for: info)
            let actual = try FileDigest.sha256(of: archive)
            guard expected == actual else {
                throw AppUpdateError.checksumMismatch(expected: expected, actual: actual)
            }

            let ditto = Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                  ["-x", "-k", archive.path, extract.path],
                                  timeout: 180)
            guard ditto.ok else {
                throw AppUpdateError.extractFailed(ditto.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let app = try singleApp(in: extract)
            // 只清 quarantine/provenance，逐项 removexattr，不动签名 seal 里的资源叉。
            Xattr.strip(app)
            try AppUpdateChecker.verifyBundle(at: app, expectedVersion: info.version)
            return app
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    /// 压缩包解压后顶层应当恰好有一个 `.app`。
    ///
    /// `ditto -c -k --sequesterRsrc` 打出来的包会带一个 `__MACOSX` 目录，
    /// 那是资源叉的存放处，不是第二个 App。
    private func singleApp(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: directory,
                                                 includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                 options: [])
        let apps = entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".app"), name != "__MACOSX" else { return false }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard apps.count == 1 else {
            throw AppUpdateError.extractFailed("压缩包里应当恰好有一个 .app（实际 \(apps.count) 个）。")
        }
        return apps[0]
    }

    /// 优先用 API 的 digest，其次用同 release 的 SHA256SUMS.txt。
    /// 两者都有时必须一致——不一致说明 release 本身有问题，不猜哪个是对的。
    private func expectedDigest(for info: AppReleaseInfo) throws -> String {
        var sumsDigest: String?
        if let sumsURL = info.sumsURL {
            // 取不到 sums 不算致命：digest 在的话已经够了。
            sumsDigest = try? fetchChecksum(from: sumsURL, assetName: info.assetName)
        }

        if let digest = info.digest {
            if let sumsDigest, sumsDigest != digest {
                throw AppUpdateError.checksumConflict(expected: digest, actual: sumsDigest)
            }
            return digest
        }
        if let sumsDigest { return sumsDigest }
        throw AppUpdateError.checksumMissing
    }

    private func fetchChecksum(from url: URL, assetName: String) throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppUpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")

        // 调用方已经在后台线程上，这里同步等一次；这个文件只有几百字节。
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            payload = data
            failure = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)

        if let failure { throw AppUpdateError.network(failure.localizedDescription) }
        guard let payload, let text = String(data: payload, encoding: .utf8) else {
            throw AppUpdateError.network("无法读取 SHA256SUMS.txt。")
        }

        for line in text.split(separator: "\n") {
            // 与引擎更新器相同的严格匹配：第二列必须与资产名全等。
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, String(fields[1]) == assetName else { continue }
            let hex = String(fields[0]).lowercased()
            guard FileDigest.isHex64(hex) else { continue }
            return hex
        }
        throw AppUpdateError.checksumMissing
    }

    // MARK: - Bundle 校验

    /// 验证一份下载/复制出来的 App 是否就是我们要安装的那一份。
    ///
    /// `codesign` 只能证明 bundle 完整、没有被改坏；ad-hoc 签名没有身份，
    /// 任何人都能重新签一份。真正的信任锚是 HTTPS 下载下来的 release
    /// 资产和它的 SHA256。这里做的是「别把损坏的、装错的、架构不对的包
    /// 换上去」这道关。
    static func verifyBundle(at app: URL, expectedVersion: String) throws {
        let fm = FileManager.default

        let signature = Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                  ["--verify", "--strict", "--verbose=2", app.path],
                                  timeout: 30)
        guard signature.ok else {
            throw AppUpdateError.codeSignature(signature.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let bundle = Bundle(url: app) else {
            throw AppUpdateError.invalidBundle("无法读取 Info.plist。")
        }
        guard bundle.bundleIdentifier == AppInfo.bundleID else {
            throw AppUpdateError.invalidBundle("bundle id 是 \(bundle.bundleIdentifier ?? "nil")，应为 \(AppInfo.bundleID)。")
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
            throw AppUpdateError.invalidBundle("CFBundlePackageType 不是 APPL。")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard version == expectedVersion else {
            throw AppUpdateError.invalidBundle("版本号 \(version) 与 release 的 \(expectedVersion) 不一致。")
        }

        let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        guard !executableName.isEmpty, !executableName.contains("/") else {
            throw AppUpdateError.invalidBundle("CFBundleExecutable 不合法。")
        }
        let executable = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AppUpdateError.invalidBundle("主可执行文件不存在。")
        }
        // 符号链接会让「bundle 里这个文件」和「实际执行的文件」脱节，
        // 而替换流程之后要信任的就是这个路径。
        if let values = try? executable.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw AppUpdateError.invalidBundle("主可执行文件是符号链接。")
        }
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.invalidBundle("主可执行文件没有执行权限。")
        }

        let minimumSystem = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
        guard Version.isAtLeastOS(minimumSystem) else {
            throw AppUpdateError.unsupportedSystem(minimumSystem ?? "")
        }

        let lipo = Shell.run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", executable.path], timeout: 15)
        guard lipo.ok else {
            throw AppUpdateError.invalidBundle("无法读取可执行文件的架构。")
        }
        let archs = lipo.output.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard archs.contains(runningArch) else {
            throw AppUpdateError.invalidBundle("包里没有本机架构（\(runningArch)），只有 \(archs.joined(separator: " "))。")
        }
    }

    /// 当前进程真正跑的 slice。在 Rosetta 下 `arch(x86_64)` 成立，
    /// 所以这里不能直接看 `uname -m`。
    private static var runningArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "arm64"
        #endif
    }
}
