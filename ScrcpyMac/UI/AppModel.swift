//  AppModel.swift
//  Scrcpy
//

import AppKit
import Combine
import SwiftUI

/// 界面状态的中枢：把引擎 / adb / 会话 / 更新四块逻辑粘到 SwiftUI 上。
///
/// 两件事值得先说明：
///
/// 1. **设置项在这里各存一份 `@Published` 镜像再写回 `Preferences`**，而不是直接绑
///    `Preferences` 的属性 —— 后者是 UserDefaults 的计算属性，改了不发通知，
///    SwiftUI 收不到更新，开关会「点了不反弹」。
///
/// 2. **所有阻塞调用（adb、scrcpy --version、解压）都走 `DispatchQueue.global`**，
///    再回主队列赋值。`Process` 动辄几百毫秒到几秒，放主线程上界面会明显卡住。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 引擎

    @Published private(set) var engine: EngineInfo?
    @Published private(set) var engineMessage: String?
    @Published private(set) var isPreparingEngine = true

    // MARK: - 设备

    @Published private(set) var devices: [AdbDevice] = []
    @Published private(set) var selectedSerial: String?
    @Published private(set) var isRefreshingDevices = false

    // MARK: - 会话

    /// 一行日志。`id` 单调递增且永不重用 —— 按数组下标当 id 的话，
    /// 一旦超出上限开始裁掉头部，所有行的 id 都会漂移，`LazyVStack` 会把
    /// 可见的几十行全部重建一次，而裁剪在长日志下是每次刷新都会发生的。
    struct LogLine: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    @Published private(set) var sessionState: ScrcpySession.State = .idle
    @Published private(set) var logLines: [LogLine] = []

    // MARK: - 更新

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case downloading(Double)
        /// 用户手动更新完成。
        case installed(String)
        /// 首次运行自动装好。与 `installed` 分开是因为文案不一样 ——
        /// 什么都没更新过却说「已更新到 x.y.z」会让人以为哪里出了错。
        case engineReady(String)
        case failed(String)
    }

    @Published private(set) var updateState: UpdateState = .idle

    // MARK: - 设置（写回 Preferences）

    @Published var maxSize: Int { didSet { preferences.maxSize = maxSize } }
    @Published var videoBitRate: String { didSet { preferences.videoBitRate = videoBitRate } }
    @Published var maxFPS: Int { didSet { preferences.maxFPS = maxFPS } }
    @Published var audioEnabled: Bool { didSet { preferences.audioEnabled = audioEnabled } }
    @Published var turnScreenOff: Bool { didSet { preferences.turnScreenOff = turnScreenOff } }
    @Published var stayAwake: Bool { didSet { preferences.stayAwake = stayAwake } }
    @Published var alwaysOnTop: Bool { didSet { preferences.alwaysOnTop = alwaysOnTop } }
    @Published var recordingEnabled: Bool { didSet { preferences.recordingEnabled = recordingEnabled } }
    @Published var recordingDirectory: String { didSet { preferences.recordingPath = recordingDirectory } }
    @Published var extraArguments: String { didSet { preferences.extraArguments = extraArguments } }
    @Published var adbPathOverride: String { didSet { preferences.adbPathOverride = adbPathOverride.isEmpty ? nil : adbPathOverride } }

    // MARK: - 依赖

    private let preferences = Preferences.shared
    private let engineStore = EngineStore.shared
    private let session = ScrcpySession()
    private let updater = UpdateChecker()

    private var pollTimer: Timer?
    private var flushTimer: Timer?
    private var pendingUpdate: ReleaseInfo?

    /// 还没凑成整行的日志尾巴。scrcpy 一次 write 不一定正好是一行，
    /// 不留这个尾巴的话半行会被当成完整行渲染出来。
    private var partialLine = ""
    private var pendingChunks: [String] = []
    private var nextLogID = 0

    /// 日志上限。再长就该去 Console 看了，留在内存里只会拖慢滚动。
    private let logLineLimit = 4000
    private let logFlushInterval: TimeInterval = 0.12

    /// 当前生效的 adb。用引擎自带的，除非用户在设置里指定了别的。
    private var adbClient: AdbClient {
        AdbClient(adbPath: engineStore.adbURL(override: preferences.adbPathOverride))
    }

    // MARK: - 生命周期

    init() {
        // 初始化期间属性观察器不会触发，所以这一批赋值不会反写 Preferences。
        maxSize = preferences.maxSize
        videoBitRate = preferences.videoBitRate
        maxFPS = preferences.maxFPS
        audioEnabled = preferences.audioEnabled
        turnScreenOff = preferences.turnScreenOff
        stayAwake = preferences.stayAwake
        alwaysOnTop = preferences.alwaysOnTop
        recordingEnabled = preferences.recordingEnabled
        recordingDirectory = preferences.recordingPath
        extraArguments = preferences.extraArguments
        adbPathOverride = preferences.adbPathOverride ?? ""
        selectedSerial = preferences.lastDeviceSerial

        session.onLog = { [weak self] text in self?.appendLog(text) }
        session.onStateChange = { [weak self] state in self?.sessionState = state }
        session.onExit = { [weak self] status in
            // 补一个换行，把可能残留的半行冲出来 —— 否则崩溃日志的最后一行会被吞掉。
            self?.appendLog("\n[scrcpy 已退出，status=\(status)]\n")
        }
    }

    /// 启动后调用一次：清理孤儿进程、准备引擎、开日志刷新。
    func start() {
        startFlushTimer()
        prepareEngine()
    }

    func shutdown() {
        pollTimer?.invalidate()
        flushTimer?.invalidate()
        updater.cancel()
    }

    // MARK: - 引擎

    /// 能用就直接用；只有内置种子就引导到 Application Support；都没有就得联网下。
    func prepareEngine() {
        isPreparingEngine = true
        engineMessage = "正在准备引擎…"

        let store = engineStore
        DispatchQueue.global(qos: .userInitiated).async {
            // 先回收上次被强杀留下的 scrcpy。它占着设备上的 scrcpy-server 不放，
            // 不清理的话接下来这次连接会直接失败，而用户看到的只是一个莫名其妙的报错。
            ScrcpySession.reapOrphans(
                supportDir: store.supportDir,
                engineRoots: [store.engineDir, store.mirrorExeDir] + [store.seedDir].compactMap { $0 }
            )

            // `current()` 会跑一次 `scrcpy --version` 冒烟，属于阻塞调用。
            if let existing = store.current() {
                DispatchQueue.main.async {
                    self.acceptEngine(existing, note: nil)
                    // 有引擎了才值得顺手看一眼有没有新版 —— 而且只在发现新版时才出声。
                    self.checkForUpdates(silent: true)
                }
                return
            }
            do {
                let bootstrapped = try store.bootstrap()
                DispatchQueue.main.async {
                    self.acceptEngine(bootstrapped, note: "[引擎就绪] scrcpy \(bootstrapped.version)（内置种子）\n")
                    self.checkForUpdates(silent: true)
                }
            } catch {
                // 走到这里说明本机**一个能用的引擎都没有**：既没有种子，也没有装过的。
                // 这时候不能只提示一句让用户自己点 —— 没有引擎的 App 什么都做不了，
                // 提示等于把「让它能用」这件事推给用户。直接自己下一份。
                DispatchQueue.main.async { self.autoInstallEngine() }
            }
        }
    }

    /// 首次运行、本机没有任何引擎：自动从官方 Releases 取一份。
    ///
    /// 正式发布的构建**不带**引擎种子（把 scrcpy 的二进制打进安装包就是重分发，
    /// 会触发 GPLv3 的传染性，我们这个项目就不能是 MIT 了），所以对下载安装的用户
    /// 来说这是必经之路 —— 必须自动完成，否则是一个装完不能用的 App。
    private func autoInstallEngine() {
        isPreparingEngine = true
        engineMessage = "首次运行，正在获取 scrcpy 引擎…"
        appendLog("[引擎] 本机没有引擎，自动从官方 Releases 获取一份。\n")

        updater.check(current: "0") { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.available(let info)):
                    self.pendingUpdate = info
                    self.install(info, isFirstRun: true)
                case .success(.upToDate), .success(.notModified):
                    // 当前版本传的是 "0"，不该被判成最新。真发生了说明版本比较坏了。
                    self.failEngineSetup("版本比较异常，请点上面的「检查更新」手动装一次。")
                case .failure(let error):
                    self.failEngineSetup(error.localizedDescription)
                }
            }
        }
    }

    private func failEngineSetup(_ reason: String) {
        isPreparingEngine = false
        engineMessage = "获取引擎失败：\(reason)"
        appendLog("[引擎缺失] \(reason)\n")
    }

    private func acceptEngine(_ info: EngineInfo, note: String?) {
        engine = info
        isPreparingEngine = false
        engineMessage = nil
        if let note { appendLog(note) }
        adbClient.warmUp()
        refreshDevices()
    }

    // MARK: - 设备

    func refreshDevices() {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        let client = adbClient

        DispatchQueue.global(qos: .userInitiated).async {
            let found = client.devices()
            DispatchQueue.main.async {
                self.isRefreshingDevices = false
                self.devices = found
                self.reconcileSelection()
            }
        }
    }

    /// 保持选中设备有效：原来选的还在就留着（哪怕暂时 unauthorized ——
    /// 用户可能正在手机上点授权），不在了就退到第一台可用的。
    private func reconcileSelection() {
        if let current = selectedSerial, devices.contains(where: { $0.serial == current }) {
            preferences.lastDeviceSerial = current
            return
        }
        selectedSerial = devices.first(where: \.isReady)?.serial
        preferences.lastDeviceSerial = selectedSerial
    }

    var selectedDevice: AdbDevice? {
        devices.first { $0.serial == selectedSerial }
    }

    /// 给 SwiftUI 用的选中绑定。`selectedSerial` 是 `private(set)`，视图绑不上，
    /// 走这里统一处理「改选中 + 落盘」，免得两处各写一遍。
    var deviceSelection: Binding<String?> {
        Binding(
            get: { self.selectedSerial },
            set: { self.select(serial: $0) }
        )
    }

    func select(serial: String?) {
        selectedSerial = serial
        preferences.lastDeviceSerial = serial
    }

    var readyDevices: [AdbDevice] { devices.filter(\.isReady) }

    /// 设备区的状态文案与状态点。
    var deviceSummary: (text: String, state: StatusDot.State) {
        if let ready = selectedDevice, ready.isReady {
            return ("已连接：\(ready.displayName)", .connected)
        }
        if let ready = readyDevices.first {
            return ("已连接：\(ready.displayName)", .connected)
        }
        if let pending = devices.first(where: { !$0.isReady }) {
            return (pending.statusText, .warning)
        }
        return ("未检测到设备，请用 USB 连接手机并打开「USB 调试」", .idle)
    }

    func startDevicePolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    func stopDevicePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - 无线连接

    /// 把当前 USB 设备切到 TCP/IP，然后用拿到的 IP 连上去。
    func enableWireless() {
        guard let device = selectedDevice, device.isReady, !device.isWireless else { return }
        appendLog("[无线] 正在把 \(device.serial) 切到 TCP/IP 模式…\n")
        let client = adbClient
        let serial = device.serial

        DispatchQueue.global(qos: .userInitiated).async {
            let tcpip = client.enableTcpip(serial: serial)
            DispatchQueue.main.async { self.appendLog(tcpip.output + "\n") }
            guard tcpip.ok, let ip = client.deviceIP(serial: serial) else {
                DispatchQueue.main.async {
                    self.appendLog("[无线] 拿不到设备 IP。请确认手机与电脑在同一个 Wi-Fi 下。\n")
                }
                return
            }
            let result = client.connect("\(ip):5555")
            DispatchQueue.main.async {
                self.appendLog(result.output + "\n")
                self.refreshDevices()
            }
        }
    }

    func connectWireless(_ hostPort: String) {
        let client = adbClient
        DispatchQueue.global(qos: .userInitiated).async {
            let result = client.connect(hostPort)
            DispatchQueue.main.async {
                self.appendLog(result.output + "\n")
                self.refreshDevices()
            }
        }
    }

    func disconnectWireless(_ hostPort: String) {
        let client = adbClient
        DispatchQueue.global(qos: .userInitiated).async {
            let result = client.disconnect(hostPort)
            DispatchQueue.main.async {
                self.appendLog(result.output + "\n")
                self.refreshDevices()
            }
        }
    }

    // MARK: - 会话

    var isRunning: Bool { sessionState == .running || sessionState == .starting }

    var canStart: Bool {
        engine != nil && selectedDevice?.isReady == true && !isRunning && updateBlocker == nil
    }

    func toggleSession() {
        if isRunning { stopSession() } else { startSession() }
    }

    func startSession() {
        guard let engine else {
            appendLog("[错误] 引擎还没准备好。\n")
            return
        }
        guard selectedDevice?.isReady == true else {
            appendLog("[错误] 没有可用的设备。\n")
            return
        }
        // 更新期间不允许投屏：替换引擎目录时如果有 scrcpy 正在跑，
        // 会把正在执行的二进制换掉。
        if let blocker = updateBlocker {
            appendLog("[错误] \(blocker)\n")
            return
        }
        do {
            let args = preferences.buildArguments(device: selectedDevice, recordingFileName: recordingFileName())
            appendLog("[启动] scrcpy \(args.joined(separator: " "))\n\n")
            try session.start(engine: engine, arguments: args, supportDir: engineStore.supportDir)
        } catch {
            appendLog("[错误] \(error.localizedDescription)\n")
        }
    }

    private var updateBlocker: String? {
        switch updateState {
        case .downloading: "正在下载引擎更新，稍后再试。"
        case .checking: "正在检查更新，稍后再试。"
        default: nil
        }
    }

    func stopSession() {
        session.stop { [weak self] in
            self?.appendLog("\n[已停止]\n")
        }
    }

    /// 正在跑的 scrcpy 子进程 pid。点程序坞图标时用它把镜像窗口也拉到前台
    /// —— 那是另一个进程的窗口，我们只能通过 `NSRunningApplication` 激活它。
    var childPID: pid_t? { session.childPID }

    /// 退出流程专用：停干净了才回调，供 `applicationShouldTerminate` 回 `.terminateLater`。
    /// 和 `stopSession()` 的区别是它必须给出一个确定的完成信号。
    func stopForTermination(completion: @escaping () -> Void) {
        guard isRunning else {
            completion()
            return
        }
        session.stop { completion() }
    }

    /// 录制文件名带时间戳，否则第二次录制会覆盖第一次。
    private func recordingFileName() -> String? {
        guard recordingEnabled else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "scrcpy_\(formatter.string(from: Date())).mp4"
    }

    // MARK: - 日志

    private func appendLog(_ text: String) {
        pendingChunks.append(text)
    }

    /// 批量刷新：scrcpy 每吐一行就重建一次视图会把界面拖垮。
    private func startFlushTimer() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: logFlushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushLog() }
        }
    }

    private func flushLog() {
        guard !pendingChunks.isEmpty else { return }
        let chunk = pendingChunks.joined()
        pendingChunks.removeAll(keepingCapacity: true)

        var pieces = (partialLine + chunk).components(separatedBy: "\n")
        // 最后一段没有换行收尾，说明这行还没写完，留着跟下一批拼。
        partialLine = pieces.removeLast()

        guard !pieces.isEmpty else { return }
        var lines = logLines
        for text in pieces {
            lines.append(LogLine(id: nextLogID, text: text))
            nextLogID += 1
        }
        if lines.count > logLineLimit {
            lines.removeFirst(lines.count - logLineLimit)
        }
        logLines = lines
    }

    func clearLog() {
        pendingChunks.removeAll()
        partialLine = ""
        logLines.removeAll()
    }

    // MARK: - 更新

    /// 检查引擎更新。
    ///
    /// `silent` 是启动时那次后台检查用的：**只在发现新版时才动界面**。
    /// 「已是最新」「没网」「被 GitHub 限流」这些都不该在启动时弹给用户看 ——
    /// 他什么都没点，凭什么要读一条错误。
    func checkForUpdates(silent: Bool = false) {
        guard !isRunning else {
            if !silent { updateState = .failed("请先停止投屏再检查更新。") }
            return
        }
        let current = engine?.version ?? "0"
        if !silent {
            updateState = .checking
            appendLog("[更新] 正在检查（当前 \(current)）…\n")
        }

        updater.check(current: current) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.upToDate(let version)), .success(.notModified(let version)):
                    guard !silent else { return }
                    self.updateState = .upToDate(version)
                    self.appendLog("[更新] 已是最新版 \(version)。\n")
                case .success(.available(let info)):
                    self.pendingUpdate = info
                    self.updateState = .available(info.version)
                    self.appendLog("[更新] 发现新版本 scrcpy \(info.version)。\n")
                case .failure(let error):
                    guard !silent else { return }
                    self.updateState = .failed(error.localizedDescription)
                    self.appendLog("[更新] 检查失败：\(error.localizedDescription)\n")
                }
            }
        }
    }

    func downloadPendingUpdate() {
        guard let info = pendingUpdate else { return }
        guard !isRunning else {
            updateState = .failed("请先停止投屏再更新。")
            return
        }
        install(info, isFirstRun: false)
    }

    /// 下载并安装。首次自动装与用户手动点「更新到 x.y.z」走的是同一条路，
    /// 只有收尾时给出的反馈不同。
    private func install(_ info: ReleaseInfo, isFirstRun: Bool) {
        updateState = .downloading(0)
        appendLog("[更新] 开始下载 scrcpy \(info.version)（\(info.assetName)）…\n")

        updater.download(info, progress: { [weak self] value in
            DispatchQueue.main.async { self?.updateState = .downloading(value) }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let staging):
                    do {
                        // acceptEngine 而不是只赋值 `engine`：它顺带把 isPreparingEngine
                        // 收掉、清掉 engineMessage，并热一次 adb、刷一次设备列表 ——
                        // 首次自动装完这一串都必须做，否则界面会停在「正在准备引擎」。
                        let installed = try self.engineStore.install(from: staging)
                        self.acceptEngine(installed, note: "[更新] 引擎已就绪：scrcpy \(installed.version)。\n")
                        self.updateState = isFirstRun ? .engineReady(installed.version) : .installed(installed.version)
                    } catch {
                        self.failEngineSetup(error.localizedDescription)
                        self.updateState = .failed(error.localizedDescription)
                        self.appendLog("[更新] 安装失败：\(error.localizedDescription)\n")
                    }
                case .failure(let error):
                    self.failEngineSetup(error.localizedDescription)
                    self.updateState = .failed(error.localizedDescription)
                    self.appendLog("[更新] 下载失败：\(error.localizedDescription)\n")
                }
            }
        })
    }

    func dismissUpdateState() {
        updateState = .idle
        pendingUpdate = nil
    }
}
