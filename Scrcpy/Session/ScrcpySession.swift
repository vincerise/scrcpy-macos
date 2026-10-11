//  ScrcpySession.swift
//  Scrcpy
//

import Darwin
import Foundation

enum SessionError: LocalizedError {
    case alreadyRunning
    case spawnFailed(String)
    case noEngine

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "已经在投屏了。"
        case .spawnFailed(let detail):
            return detail.isEmpty ? "无法启动 scrcpy。" : "无法启动 scrcpy：\(detail)"
        case .noEngine:
            return "引擎文件不完整，找不到 scrcpy / adb / scrcpy-server。"
        }
    }
}

/// 一次 scrcpy 投屏会话：拉起子进程、把它的输出转成日志、结束时收干净。
///
/// 这个类里几乎每一条「为什么这么写」都是踩出来的，改之前先看注释。
final class ScrcpySession {

    enum State: Equatable {
        case idle
        case starting
        case running
        case stopping
    }

    /// 全部回调都在**主线程**触发。UI 侧是在 `@MainActor` 上赋值的，
    /// 后台线程直接调会撞上 SwiftUI 的状态更新检查。
    var onLog: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let engineStore = EngineStore.shared

    private let lock = NSLock()
    private var _state: State = .idle
    private var _childPID: pid_t?
    private var process: Process?
    private var pipe: Pipe?
    /// 还没凑成整行的尾巴。
    private var lineBuffer = Data()
    /// 退出只处理一次。`terminationHandler` 与强杀之后的兜底计时器会竞争同一个退出，
    /// 这个标记就是它们之间的闸门。
    private var exitHandled = false
    private var pidFileURL: URL?
    private var pendingStopCompletions: [() -> Void] = []
    private var stopTimer: DispatchWorkItem?

    /// 收到 SIGTERM 后还等多久才强杀。
    private let stopGrace: TimeInterval = 3

    init() {}

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    var childPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return _childPID
    }

    var isRunning: Bool {
        let current = state
        return current == .starting || current == .running
    }

    // MARK: - 启动

    /// 用 `store` 里当前真正可用的那个引擎（含种子回落）启动。
    func start(engine store: EngineStore, arguments: [String], supportDir: URL) throws {
        guard let info = store.current() else { throw SessionError.noEngine }
        try start(engine: info, arguments: arguments, supportDir: supportDir)
    }

    /// 用指定的引擎目录启动。
    func start(engine info: EngineInfo, arguments: [String], supportDir: URL) throws {
        guard state == .idle else { throw SessionError.alreadyRunning }

        let fm = FileManager.default
        let scrcpy = info.dir.appendingPathComponent("scrcpy")
        let server = info.dir.appendingPathComponent("scrcpy-server")
        let adb = engineStore.adbURL(override: Preferences.shared.adbPathOverride)

        guard fm.isExecutableFile(atPath: scrcpy.path),
              fm.isExecutableFile(atPath: adb.path),
              fm.fileExists(atPath: server.path) else {
            throw SessionError.noEngine
        }

        let process = Process()
        process.executableURL = scrcpy
        process.arguments = arguments
        // 工作目录设成引擎目录：scrcpy 会在 cwd 下找一些相对路径的资源，
        // 而 App 自己的 cwd 是 `/`（从 Finder 启动时）。
        process.currentDirectoryURL = info.dir

        // environment 是**整体替换**语义，所以必须先继承父进程环境再覆盖 ——
        // 直接赋一个新字典会把 HOME、LANG、TMPDIR 之类全部丢掉。
        var environment = ProcessInfo.processInfo.environment
        // HOME 必须是真实 home。adb 靠 `~/.android/adbkey` 认设备，
        // HOME 不对它会重新生成一对密钥，手机上于是又弹一次「允许 USB 调试」，
        // 而且之前授权过的设备会变成新设备。
        environment["HOME"] = fm.homeDirectoryForCurrentUser.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        // 三个绝对路径都要显式给出。scrcpy 默认会去 PATH 里找 adb、
        // 去可执行文件旁边找 scrcpy-server，一旦落空就是启动即失败。
        environment["ADB"] = adb.path
        environment["SCRCPY_SERVER_PATH"] = server.path
        environment["SCRCPY_ICON_DIR"] = info.dir.path
        process.environment = environment

        let pipe = Pipe()
        // stdout 与 stderr 接同一个管道：分成两路会丢掉日志的先后顺序，
        // 而 scrcpy 的报错和它的上下文经常一半在 stdout 一半在 stderr。
        process.standardOutput = pipe
        process.standardError = pipe
        // 配合固定的 `--pause-on-exit=false` 双保险：就算 scrcpy 真去读 stdin，
        // 拿到的也是立刻 EOF，不会卡在那里等一个永远不会来的输入。
        process.standardInput = FileHandle.nullDevice

        lock.lock()
        exitHandled = false
        lineBuffer = Data()
        pendingStopCompletions.removeAll()
        self.process = process
        _state = .starting
        lock.unlock()
        publishState(.starting)

        // readabilityHandler 必须在 run() 之前挂上。晚一步的话，
        // 子进程在那一瞬之间吐出的输出会直接丢掉 —— 而启动失败的原因往往就在那几行里。
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF。**必须**在这里把 handler 置 nil：不置的话 availableData 会
                // 一直返回空 Data，这个 handler 就变成 100% CPU 的死循环。
                handle.readabilityHandler = nil
                self?.flushPartialLine()
                return
            }
            self?.consume(chunk)
        }
        process.terminationHandler = { [weak self] finished in
            // terminationHandler 也在后台线程跑，不能直接碰 UI。
            self?.handleExit(status: finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            exitHandled = true
            self.process = nil
            _childPID = nil
            _state = .idle
            lock.unlock()
            publishState(.idle)
            throw SessionError.spawnFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        let pidFile = supportDir.appendingPathComponent("session.pid")

        lock.lock()
        _childPID = pid
        // 参数错误时进程可能秒退，那会儿 handleExit 已经跑完了（状态收回 .idle）。
        // 这里再无条件置 .running 会把那次退出盖掉，UI 就永远停在「投屏中」。
        let finishedAlready = exitHandled
        if !finishedAlready {
            _state = .running
            pidFileURL = pidFile
        }
        lock.unlock()

        guard !finishedAlready else { return }

        // 记下 pid。下次启动时 reapOrphans 靠它回收上次没退干净的进程。
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? "\(pid)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        publishState(.running)
    }

    // MARK: - 停止

    /// SIGTERM；3 秒后仍活着则 SIGKILL。completion 在主线程、且只会被调用一次。
    func stop(completion: @escaping () -> Void) {
        lock.lock()
        guard let process, !exitHandled else {
            // 已经不在跑了。调用方仍然要收到回调，否则它会一直等下去。
            lock.unlock()
            onMain(completion)
            return
        }
        pendingStopCompletions.append(completion)
        let wasStopping = (_state == .stopping)
        if !wasStopping { _state = .stopping }
        lock.unlock()

        // 重复调用只是把 completion 挂上，真正的终止流程只走一次。
        guard !wasStopping else { return }
        publishState(.stopping)

        // 用 SIGTERM（Process.terminate）而不是直接 SIGKILL：scrcpy 要靠这个信号
        // 去清理设备侧的 scrcpy-server、恢复息屏、删掉推进去的临时文件。
        // 直接 KILL 会把这些全留在手机上，下次连接时 scrcpy 还会抱怨 server 版本不符。
        if process.isRunning { process.terminate() }

        let pid = process.processIdentifier
        let item = DispatchWorkItem { [weak self] in self?.escalate(pid: pid) }
        lock.lock(); stopTimer = item; lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + stopGrace, execute: item)
    }

    private func escalate(pid: pid_t) {
        lock.lock()
        let target = process
        let done = exitHandled
        lock.unlock()
        guard !done, let target else { return }

        // 到点还没退，多半是卡在僵死的 adb 连接上，没有别的办法了。
        if target.isRunning { kill(pid, SIGKILL) }

        // 强杀之后再给一小段；仍然收不到退出回调就自己把状态收回来。
        // 不留这一步的话，界面会永远停在「正在停止」，而唯一的出路是杀掉 App。
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let finished = self.exitHandled
            let still = self.process
            self.lock.unlock()
            guard !finished, let still else { return }
            self.handleExit(status: still.isRunning ? -1 : still.terminationStatus)
        }
        lock.lock(); stopTimer = item; lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    // MARK: - 退出

    private func handleExit(status: Int32) {
        lock.lock()
        // terminationHandler 与强杀兜底计时器会竞争同一次退出，这里是唯一的闸门。
        guard !exitHandled, process != nil else {
            lock.unlock()
            return
        }
        exitHandled = true
        let pid = _childPID
        let file = pidFileURL
        let completions = pendingStopCompletions
        let timer = stopTimer

        self.process = nil
        self.pipe = nil
        _childPID = nil
        pidFileURL = nil
        _state = .idle
        pendingStopCompletions.removeAll()
        stopTimer = nil
        let exitHandler = onExit
        lock.unlock()

        timer?.cancel()
        removePidFile(file, pid: pid)

        publishState(.idle)
        if let exitHandler { onMain { exitHandler(status) } }
        for completion in completions { onMain(completion) }
    }

    /// 删掉 pid 文件，但只在它还是「我们这一场」写的那份时。
    /// 退出回调有可能晚于下一场会话的启动才跑到，无条件删会把新会话的标记抹掉，
    /// 那个进程就再也没法被 reapOrphans 回收了。
    private func removePidFile(_ file: URL?, pid: pid_t?) {
        guard let file else { return }
        if let pid,
           let text = try? String(contentsOf: file, encoding: .utf8),
           let recorded = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           recorded != pid {
            return
        }
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - 输出

    /// 把原始字节攒成整行再投递。
    ///
    /// 不逐块投递的原因：一次 `read` 很可能把一个多字节 UTF-8 字符从中间切开，
    /// 逐块解码就会在日志里留下乱码。按行切分则天然对齐在 ASCII 换行上。
    private func consume(_ chunk: Data) {
        lock.lock()
        lineBuffer.append(chunk)
        var lines: [String] = []
        while let breakIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<breakIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...breakIndex)
            var line = String(decoding: lineData, as: UTF8.self)
            // scrcpy 会用 \r 原地刷新进度行，留着这个字符在界面上会变成奇怪的方块。
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line + "\n")
        }
        let handler = onLog
        lock.unlock()

        guard let handler, !lines.isEmpty else { return }
        // 合并成一次回调：逐行 dispatch 到主线程在日志密集时会把主线程淹掉。
        let text = lines.joined()
        onMain { handler(text) }
    }

    /// 进程退出时要吐出最后那半行 —— 崩溃信息经常就是没有换行结尾的。
    private func flushPartialLine() {
        lock.lock()
        let remainder = lineBuffer
        lineBuffer = Data()
        let handler = onLog
        lock.unlock()

        guard let handler, !remainder.isEmpty else { return }
        let text = String(decoding: remainder, as: UTF8.self) + "\n"
        onMain { handler(text) }
    }

    // MARK: - 回调投递

    private func publishState(_ newState: State) {
        lock.lock()
        let handler = onStateChange
        lock.unlock()
        guard let handler else { return }
        onMain { handler(newState) }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - 孤儿清理

    /// 清理上次残留的孤儿进程。
    ///
    /// App 被强杀（崩溃、强制退出、断电）时来不及发 SIGTERM，scrcpy 会留在后台，
    /// 而且它占着设备上的 scrcpy-server 不放，会让下一次连接失败。
    ///
    /// `engineRoots` 要**把所有可能启动过子进程的引擎目录都列上**：当前生效的可能是
    /// Application Support 那份，也可能是 bundle 里的内置种子；而残留进程来自哪一次
    /// 运行是未知的 —— 只按当前那一个比对，换过引擎之后就再也回收不掉。
    static func reapOrphans(supportDir: URL, engineRoots: [URL]) {
        let file = supportDir.appendingPathComponent("session.pid")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: file) }

        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return }

        // 光凭 pid 还活着就杀是不行的：pid 会被系统回收复用，
        // 隔一段时间之后那个号很可能属于完全不相干的进程。
        // 所以再核对一次它的可执行路径确实落在引擎目录里。
        guard kill(pid, 0) == 0 || errno == EPERM else { return }
        guard let path = executablePath(of: pid) else { return }

        let roots = engineRoots.map { $0.standardizedFileURL.path }
        // 必须按路径分隔符比边界。裸 hasPrefix 会把 `/x/engine-other/scrcpy`
        // 也算成 `/x/engine` 里的进程，那就会杀错人。
        let isOurs = roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        guard isOurs else { return }

        kill(pid, SIGTERM)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
