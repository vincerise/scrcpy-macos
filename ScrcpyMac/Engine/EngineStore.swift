//  EngineStore.swift
//  Scrcpy
//

import Foundation

struct EngineInfo: Equatable {
    /// 引擎是从哪来的。UI 用它区分「已安装」和「内置种子」。
    enum Origin: Equatable {
        case managed
        case seed
    }

    let dir: URL
    let version: String
    let origin: Origin
}

enum EngineError: LocalizedError {
    case seedMissing
    case noEngine
    case smokeTestFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .seedMissing:
            return "App 内没有内置引擎种子，需要联网下载一份。"
        case .noEngine:
            return "没有可用的 scrcpy 引擎。"
        case .smokeTestFailed(let detail):
            return detail.isEmpty ? "引擎无法执行，跑 `scrcpy --version` 没有得到版本号。" : detail
        case .installFailed(let detail):
            return detail.isEmpty ? "安装引擎失败。" : detail
        }
    }
}

/// 引擎文件的位置与生命周期。
///
/// 引擎**不放进 App bundle**：一是里面有 30MB 的二进制、二是 scrcpy 是 GPLv3，
/// 我们不重分发它。bundle 里的 `Contents/Resources/engine-seed/` 只是只读种子，
/// 首次运行拷进 Application Support，之后的更新都发生在那里 ——
/// App 被替换（比如从下载的 dmg 里拖一份新的）不该把引擎一起丢掉。
/// `@unchecked Sendable` 的依据：唯一的可变状态是那个解析结果缓存，
/// 而它的每一次读写都在 `lock` 里（见 `current()` / `invalidateCache()`）。
/// 其余字段都是 `let`。所以跨线程共享是安全的，编译器只是看不出来。
final class EngineStore: @unchecked Sendable {

    static let shared = EngineStore()

    /// `~/Library/Application Support/ScrcpyMac`
    let supportDir: URL
    /// `supportDir/engine`
    let engineDir: URL

    /// 进得去 engine 目录的三个文件。scrcpy 客户端与 scrcpy-server 版本必须严格一致，
    /// 少一个都会在运行时被拒绝，所以判定「引擎完整」时一个都不能缺。
    private static let requiredFiles = ["scrcpy", "adb", "scrcpy-server"]
    /// 有就一起装、没有也不影响运行的东西（图标、man page、许可证）。
    private static let optionalFiles = ["scrcpy.png", "disconnected.png", "scrcpy.1", "LICENSE"]

    private let lock = NSLock()
    /// `prepareMirrorApp` 专用的锁。与 `lock` 分开：那个锁保护的是解析结果缓存，
    /// 而这里要覆盖的是「判断 → 删 → 链接」这段落盘过程，两者的临界区互不相干。
    private static let mirrorLock = NSLock()
    /// `current()` 会 fork 进程跑 `scrcpy --version`。UI 在 SwiftUI 的 body 里调用它，
    /// 一次刷新就能触发成百上千次进程创建，所以把成功结果记下来。
    private var cached: EngineInfo?

    init(supportDir: URL? = nil) {
        let base = supportDir
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.supportDir = base.appendingPathComponent("ScrcpyMac", isDirectory: true)
        self.engineDir = self.supportDir.appendingPathComponent("engine", isDirectory: true)
    }

    // MARK: - 路径

    /// bundle 里的只读种子目录，不存在则为 nil。
    var seedDir: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("engine-seed", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    /// 当前**实际生效**的引擎目录：可能是 Application Support 里那份，也可能是内置种子。
    ///
    /// 运行时的三个路径都必须从这里派生，不能直接拼 `engineDir` ——
    /// 出厂的 App 只有种子、没有 Application Support 那份，直接拼会指向一个
    /// 不存在的文件，`adb` 起不来，界面表现为「永远检测不到设备」。
    var activeDir: URL { current()?.dir ?? engineDir }

    var scrcpyURL: URL { activeDir.appendingPathComponent("scrcpy") }
    var adbURL: URL { activeDir.appendingPathComponent("adb") }
    var serverURL: URL { activeDir.appendingPathComponent("scrcpy-server") }
    /// scrcpy 只认图标所在的**目录**（它自己去里面找 scrcpy.png / disconnected.png）。
    var iconDir: URL { activeDir }

    /// 被更新替换的那一份，永远在 Application Support，与「当前生效」无关。
    /// `resolve()` 与 `install()` 必须用这个 —— 它们要探的正是待安装/待判定的那一份，
    /// 用 `scrcpyURL` 会顺着 `current()` 绕回缓存里的旧引擎。
    private var managedScrcpyURL: URL { engineDir.appendingPathComponent("scrcpy") }

    // MARK: - 当前引擎

    /// 当前可用引擎：Application Support 的能用就用；不能用（缺失或 `--version`
    /// 冒烟失败）则回落到内置种子；都没有则 nil。
    func current() -> EngineInfo? {
        lock.lock()
        let hit = cached
        lock.unlock()
        if let hit { return hit }

        guard let resolved = resolve() else { return nil }

        // 只缓存成功结果。失败要每次重算 —— 用户可能刚把引擎补上，
        // 缓存住失败结果会逼他重启 App 才能恢复。
        lock.lock()
        cached = resolved
        lock.unlock()
        return resolved
    }

    /// 引擎被换过之后必须调用，否则 UI 会一直显示旧版本号，
    /// 而且新起的会话还会指向已经被挪走的旧目录。
    func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private func resolve() -> EngineInfo? {
        if isComplete(engineDir), let version = EngineStore.smokeTest(scrcpyAt: managedScrcpyURL) {
            return EngineInfo(dir: engineDir, version: version, origin: .managed)
        }
        if let seed = seedDir, isComplete(seed),
           let version = EngineStore.smokeTest(scrcpyAt: seed.appendingPathComponent("scrcpy")) {
            return EngineInfo(dir: seed, version: version, origin: .seed)
        }
        return nil
    }

    /// 首次运行引导：把种子拷到 Application Support。已有可用引擎直接返回。
    func bootstrap() throws -> EngineInfo {
        if let existing = current() { return existing }

        guard let seed = seedDir, isComplete(seed) else { throw EngineError.seedMissing }

        // 先整份拷进暂存目录再原子换入。直接往 engine/ 里拷到一半失败，
        // 会留下一个「目录存在但缺文件」的引擎 —— 那个状态比「什么都没有」更难排查，
        // 因为它会一路走到运行时才报错。
        let staging = supportDir.appendingPathComponent("engine.staging.\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in EngineStore.requiredFiles + EngineStore.optionalFiles {
                let source = seed.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw EngineError.installFailed("从内置种子复制引擎失败：\(error.localizedDescription)")
        }

        Xattr.strip(staging)
        makeExecutable(staging)
        return try install(from: staging)
    }

    /// 用 `stagingDir`（内含完整引擎文件）原子替换当前引擎。
    ///
    /// 顺序是 `engine` → `engine.old.<uuid>`，`staging` → `engine`，再删旧的。
    /// 用 `moveItem` 而不是 `replaceItemAt`：后者在目标不存在、或者卷特性不匹配时会
    /// 走进奇怪的路径，而我们要的语义就是「两次改名」这么简单。
    func install(from stagingDir: URL) throws -> EngineInfo {
        let fm = FileManager.default

        guard isComplete(stagingDir) else {
            throw EngineError.installFailed("暂存目录里缺少 scrcpy / adb / scrcpy-server：\(stagingDir.path)")
        }

        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        } catch {
            throw EngineError.installFailed("无法创建 \(supportDir.path)：\(error.localizedDescription)")
        }

        let staged = try stageForInstall(stagingDir)

        // 冒烟失败要能退回旧引擎：不回滚的话用户会卡在「一个字节都没有」的状态，
        // 那个状态只能靠重新联网下载才能恢复。回滚只是再一次改名，成本几乎为零。
        let backup = supportDir.appendingPathComponent("engine.old.\(UUID().uuidString)", isDirectory: true)
        let hadEngine = fm.fileExists(atPath: engineDir.path)
        if hadEngine {
            do {
                try fm.moveItem(at: engineDir, to: backup)
            } catch {
                try? fm.removeItem(at: staged)
                throw EngineError.installFailed("无法移开旧引擎：\(error.localizedDescription)")
            }
        }

        do {
            try fm.moveItem(at: staged, to: engineDir)
        } catch {
            if hadEngine { try? fm.moveItem(at: backup, to: engineDir) }
            try? fm.removeItem(at: staged)
            throw EngineError.installFailed("替换引擎目录失败：\(error.localizedDescription)")
        }

        guard let version = EngineStore.smokeTest(scrcpyAt: managedScrcpyURL) else {
            // 把冒烟失败的原因一并报出来，否则用户只看到「失败了」，
            // 既不知道新引擎坏在哪，也不知道旧的还在不在。
            let probe = Shell.run(managedScrcpyURL, ["--version"], timeout: 15)
            var reason = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.isEmpty { reason = "退出码 \(probe.status)，没有输出" }
            if probe.timedOut { reason = "执行超时" }

            try? fm.removeItem(at: engineDir)
            if hadEngine { try? fm.moveItem(at: backup, to: engineDir) }
            invalidateCache()
            throw EngineError.smokeTestFailed("新引擎跑不起来：\(reason)。已回退到上一个可用的引擎。")
        }

        if hadEngine { try? fm.removeItem(at: backup) }
        cleanUpLeftovers()
        invalidateCache()
        return EngineInfo(dir: engineDir, version: version, origin: .managed)
    }

    /// 命令行 adb 覆盖路径。用户填的路径打错或者不可执行时静默回落到内置 adb ——
    /// 一个手滑的输入不应该让整个 App 用不了。
    func adbURL(override: String?) -> URL {
        guard let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return adbURL
        }
        let path = (raw as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { return adbURL }
        return URL(fileURLWithPath: path)
    }

    // MARK: - 投屏窗口的宿主 bundle

    /// 装着 scrcpy 的迷你 .app。
    ///
    /// 子进程必须待在一个带 `LSUIElement` 的 bundle 里，才拿得到 accessory
    /// （`UIElement`）激活策略：没有程序坞图标、不占菜单栏，但窗口照常能激活、
    /// 能收键盘和鼠标。进程的默认策略取决于它是不是待在一个 bundle 里：
    /// 裸二进制跑出来是 prohibited —— 一样没有图标，可窗口也起不来了（拉不起渲染），
    /// 所以「把引擎直接 exec 掉」这条捷径是走不通的。
    ///
    /// 放在 Application Support 而不是 App bundle 里，是因为它必须可写，
    /// 而且随时会被重建 —— 见 `prepareMirrorApp`。
    var mirrorAppURL: URL { supportDir.appendingPathComponent("Mirror.app", isDirectory: true) }
    var mirrorExecutableURL: URL { mirrorAppURL.appendingPathComponent("Contents/MacOS/scrcpy") }
    /// 子进程真正的可执行文件所在目录。
    ///
    /// 孤儿回收要拿它一起比对 —— 起了这个 bundle 之后，子进程的可执行路径
    /// 已经不在引擎目录底下了，只按引擎目录比会永远回收不掉残留进程。
    var mirrorExeDir: URL { mirrorExecutableURL.deletingLastPathComponent() }

    /// 把 `info` 那份引擎的 scrcpy 放进迷你 .app，返回它的可执行文件路径。
    ///
    /// 每次启动都调，但只有内容对不上时才真的落盘：引擎更新换的是整个目录
    /// （新的 inode），这里跟着重新链一次就行。
    ///
    /// 整个过程在 `mirrorLock` 里。之前它靠「调用方都在主线程」隐式串行，
    /// 而多设备之后「同时点两台设备的投屏」正是要做的事：两个线程一起走到
    /// 「判断 → removeItem → link」之间，后一个的 link 会拿到 EEXIST，
    /// 落到拷贝分支又因为目标已存在而失败 —— 用户看到的是一句和真实原因
    /// 毫无关系的「无法把 scrcpy 放进 …」。加锁之后这不再可能，
    /// 下面再补一道 inode 核对，防止将来有人绕过这把锁。
    func prepareMirrorApp(for info: EngineInfo) throws -> URL {
        EngineStore.mirrorLock.lock()
        defer { EngineStore.mirrorLock.unlock() }

        let fm = FileManager.default
        let source = info.dir.appendingPathComponent("scrcpy")
        let dest = mirrorExecutableURL

        do {
            try fm.createDirectory(at: mirrorExeDir, withIntermediateDirectories: true)
        } catch {
            throw EngineError.installFailed("无法创建 \(mirrorExeDir.path)：\(error.localizedDescription)")
        }

        try writeMirrorInfoPlist()

        if !isUpToDate(dest, against: source) {
            // 先硬链接：引擎和支持目录通常在一个卷上，这样不用白占 10MB。
            // 跨卷（App 装在别的盘上）才退化成拷贝。
            try? fm.removeItem(at: dest)
            if link(source.path, dest.path) != 0 {
                // 目标是别人刚建好的同一份，那就当成功。EEXIST 不是错误。
                if !isUpToDate(dest, against: source) {
                    do {
                        try fm.copyItem(at: source, to: dest)
                        // 拷贝出来的 mtime 是「现在」，下次比对上会永远不相等，
                        // 于是每次启动都重拷一份。对齐成源文件的，让两种情况共用同一套判断。
                        if let mtime = try? source.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate {
                            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dest.path)
                        }
                    } catch {
                        throw EngineError.installFailed("无法把 scrcpy 放进 \(dest.path)：\(error.localizedDescription)")
                    }
                }
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }

        return dest
    }

    private func writeMirrorInfoPlist() throws {
        let contents = mirrorAppURL.appendingPathComponent("Contents", isDirectory: true)
        let plist = contents.appendingPathComponent("Info.plist")
        // 每次覆盖写一份，成本可以忽略，也省掉「改了内容却没生效」这类问题。
        let body: [String: Any] = [
            "CFBundleExecutable": "scrcpy",
            "CFBundleIdentifier": "com.vincerise.scrcpymac.mirror",
            "CFBundleName": "ScrcpyMac",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            // 这一个键就是整件事的关键：它让 AppKit 把进程的默认激活策略
            // 定成 accessory，而不是普通应用的 regular。
            "LSUIElement": true,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
        } catch {
            throw EngineError.installFailed("无法写入 \(plist.path)：\(error.localizedDescription)")
        }
    }

    /// `dest` 是不是已经就是 `source` 那一份。
    ///
    /// 硬链接时两者的 fileResourceIdentifier（dev + inode）相同；退化到拷贝时，
    /// 拿大小和修改时间比 —— 后者已经在上面的拷贝分支里对齐过了。
    private func isUpToDate(_ dest: URL, against source: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        guard let d = try? dest.resourceValues(forKeys: keys),
              let s = try? source.resourceValues(forKeys: keys) else { return false }

        if let di = d.fileResourceIdentifier, let si = s.fileResourceIdentifier,
           (di as AnyObject).isEqual(si) {
            return true
        }
        guard let ds = d.fileSize, let ss = s.fileSize, ds == ss,
              let dm = d.contentModificationDate, let sm = s.contentModificationDate else { return false }
        return abs(dm.timeIntervalSince(sm)) < 1
    }

    // MARK: - 版本

    /// 从 `scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>` 里取出 `5.0.1`。
    static func parseVersion(_ output: String) -> String? {
        // 只看第一行。实测 `--version` 的首行之后还跟着空行和一份
        // `Dependencies (compiled / linked):` 清单，整段做正则会匹到 SDL、libavcodec 的版本号。
        let firstLine = output.prefix { $0 != "\n" }
        let tokens = firstLine.split(separator: " ", omittingEmptySubsequences: true)

        if tokens.count >= 2, tokens[0].lowercased() == "scrcpy" {
            return String(tokens[1])
        }

        // 兜底：万一以后输出格式变了，找第一个形如 x.y 或 x.y.z 的 token。
        // 判不出来才返回 nil —— 这里返回 nil 的后果是「引擎被判定为坏掉」，
        // 不该因为格式微调就把用户的引擎废掉。
        for token in tokens {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()"))
            let fields = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count >= 2,
                  fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { continue }
            return candidate
        }
        return nil
    }

    /// 跑 `scrcpy --version` 拿版本号，失败返回 nil。
    static func smokeTest(scrcpyAt url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let result = Shell.run(url, ["--version"], timeout: 15)
        guard result.ok else { return nil }
        return parseVersion(result.output)
    }

    // MARK: - 内部

    /// 三个必需文件齐不齐。`scrcpy-server` 是数据文件（官方压缩包里是 644），
    /// 不能对它要求可执行位，否则一份完好的引擎会被判成残缺。
    private func isComplete(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("scrcpy-server").path) else { return false }
        for name in ["scrcpy", "adb"] where !fm.isExecutableFile(atPath: dir.appendingPathComponent(name).path) {
            return false
        }
        return true
    }

    /// 保证两个二进制可执行。压缩包里的权限位通常是对的，但解压工具不受我们控制 ——
    /// 一个没有执行位的 `scrcpy` 会以「无法执行」的形式失败，那个报错很难联想到权限。
    private func makeExecutable(_ dir: URL) {
        for name in ["scrcpy", "adb"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.appendingPathComponent(name).path)
        }
    }

    /// `moveItem` 跨卷时会退化成「拷贝 + 删源」，既慢又不再原子。
    /// 引擎目录一旦换到一半失败，App 就彻底没得用了，所以先确保待换入的内容
    /// 和 `engine/` 在同一个卷上。
    private func stageForInstall(_ source: URL) throws -> URL {
        guard !isSameVolume(source, supportDir) else { return source }

        let dest = supportDir.appendingPathComponent("engine.staging.\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw EngineError.installFailed("跨卷拷贝引擎失败：\(error.localizedDescription)")
        }
        return dest
    }

    private func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> Any? {
            try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        // 取不到卷标识（比如路径还不存在）时按「同卷」处理，走快路径。
        guard let va = volume(a), let vb = volume(b) else { return true }
        return (va as AnyObject).isEqual(vb)
    }

    /// 清掉上次中断留下的残骸（旧引擎备份、半份暂存）。
    private func cleanUpLeftovers() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: supportDir,
                                                        includingPropertiesForKeys: nil,
                                                        options: []) else { return }
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("engine.old.") || name.hasPrefix("engine.staging.") else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
