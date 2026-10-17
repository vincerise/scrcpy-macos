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
    @Published private(set) var isRefreshingDevices = false

    /// 每台设备当前那一路会话的状态。没有条目 = 这台设备没有会话。
    @Published private(set) var sessionStates: [String: ScrcpySession.State] = [:]

    /// 设备名缓存。设备掉线之后 adb 列表里就没有它了，但那一行还得留着
    /// （见 `rows`），总得有个名字可显示。
    private var lastKnownName: [String: String] = [:]

    // MARK: - 会话

    /// 一行日志。`id` 单调递增且永不重用 —— 按数组下标当 id 的话，
    /// 一旦超出上限开始裁掉头部，所有行的 id 都会漂移，`LazyVStack` 会把
    /// 可见的几十行全部重建一次，而裁剪在长日志下是每次刷新都会发生的。
    ///
    /// `source` 标出这行是哪台设备吐的，nil = App 自己的输出（引擎、更新、错误）。
    /// **id 必须由 AppModel 里那一个全局计数器发**：多设备最容易顺手写成
    /// 「每台一个桶、各自从 0 编号再合并」，那样 id 会重复，而 `ForEach` 拿 id 当身份，
    /// 后果是日志串台、滚动跳位，且很难往编号上联想。
    struct LogLine: Identifiable, Equatable {
        let id: Int
        let text: String
        var source: LogSource?
    }

    struct LogSource: Equatable, Identifiable {
        let serial: String
        let name: String
        var id: String { serial }
    }

    @Published private(set) var logLines: [LogLine] = []
    /// 日志区只看哪台设备。nil = 全部（App 自己的行只在「全部」里出现）。
    @Published var logSource: String?

    /// 设备列表里的一行。
    ///
    /// 不直接复用 `AdbDevice`：设备投屏中被拔掉时 adb 列表里就没有它了，
    /// 可这一行必须继续存在并保留「停止」按钮，否则用户会遇到一个停不掉的会话。
    /// `device` 为 nil 就是这种「只剩会话」的行。
    /// 也不给 `AdbDevice` 编一个 adb 不会产出的假状态 —— `isReady` / `statusText`
    /// 都是按真实 adb 状态设计的，喂假状态会把英文原文透到中文界面里。
    struct DeviceRow: Identifiable {
        let serial: String
        /// nil = 已经不在 adb 的设备列表里了。
        let device: AdbDevice?
        let name: String
        /// nil = 这台设备没有会话。
        let state: ScrcpySession.State?

        var id: String { serial }
        var isReady: Bool { device?.isReady == true }
        var isBusy: Bool { state != nil && state != .idle }
    }

    /// 设备列表 = adb 当前列表 ∪ 还有会话的 serial（按 serial 排序，顺序才稳定）。
    var rows: [DeviceRow] {
        var result: [DeviceRow] = []
        var seen = Set<String>()

        for device in devices {
            seen.insert(device.serial)
            lastKnownName[device.serial] = device.displayName
            result.append(DeviceRow(serial: device.serial,
                                    device: device,
                                    name: device.displayName,
                                    state: sessionStates[device.serial]))
        }

        let orphaned = sessionStates.keys
            .filter { !seen.contains($0) }
            .sorted()
            .map { serial in
                DeviceRow(serial: serial,
                          device: nil,
                          name: lastKnownName[serial] ?? serial,
                          state: sessionStates[serial])
            }
        return result + orphaned
    }

    /// 就绪、且还没有会话的设备。底部栏的「全部投屏 / 投屏另外 n 台」按它算。
    var startableSerials: [String] {
        rows.filter { $0.isReady && $0.state == nil }.map(\.serial)
    }

    /// 正在跑或正在起的会话数。
    var runningCount: Int {
        sessionStates.values.filter { $0 == .running || $0 == .starting }.count
    }

    var isRunning: Bool { runningCount > 0 }

    /// 有任何一路没回到 idle（含「停止中」）。引擎更新期间必须用它做闸门：
    /// 正在 starting 的那一路马上要按 `SCRCPY_SERVER_PATH` 去推设备侧的 server jar，
    /// 这时候把引擎目录整个换掉是真会出事的。
    var anySessionActive: Bool {
        sessionStates.values.contains { $0 != .idle }
    }

    /// 日志来源选项：按首次出现的顺序给出去重后的设备。
    var logSources: [LogSource] {
        var seen = Set<String>()
        var result: [LogSource] = []
        for line in logLines {
            guard let source = line.source, !seen.contains(source.serial) else { continue }
            seen.insert(source.serial)
            result.append(source)
        }
        return result
    }

    /// 日志区当前该显示的行。过滤在这一层做，视图只管画。
    var visibleLogLines: [LogLine] {
        guard let logSource else { return logLines }
        return logLines.filter { $0.source?.serial == logSource }
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

    /// 把某台 USB 设备切到 TCP/IP，然后用拿到的 IP 连上去。
    func enableWireless(serial: String) {
        guard let device = devices.first(where: { $0.serial == serial }),
              device.isReady, !device.isWireless else { return }
        appendLog("[无线] 正在把 \(serial) 切到 TCP/IP 模式…\n", from: serial)
        let client = adbClient

        DispatchQueue.global(qos: .userInitiated).async {
            let tcpip = client.enableTcpip(serial: serial)
            DispatchQueue.main.async { self.appendLog(tcpip.output + "\n", from: serial) }
            guard tcpip.ok, let ip = client.deviceIP(serial: serial) else {
                DispatchQueue.main.async {
                    self.appendLog("[无线] 拿不到设备 IP。请确认手机与电脑在同一个 Wi-Fi 下。\n", from: serial)
                }
                return
            }
            let result = client.connect("\(ip):5555")
            DispatchQueue.main.async {
                self.appendLog(result.output + "\n", from: serial)
                self.refreshDevices()
            }
        }
    }

    // MARK: - 更新

    enum EngineUpdateState: Equatable {
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

    @Published private(set) var engineUpdateState: EngineUpdateState = .idle

    /// App 本体更新。和引擎更新分开：它最终要退出并替换整个 `.app`，
    /// 状态机也因此多出「已下载待重启」这一步。
    enum AppUpdateState: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case downloading(Double)
        /// 下载完成，正在校验/解压。
        case preparing
        /// 已下载并验证，等用户点重启。
        case ready(String)
        case installing
        /// 本次启动就是刚更新后的版本。
        case updated(String)
        case failed(String)
    }

    @Published private(set) var appUpdateState: AppUpdateState = .idle

    var appVersion: String { AppInfo.version }

    // MARK: - 参数（按设备）

    /// 每台设备单独设置过的参数，key 是 serial。
    ///
    /// 和 `sessions` 的关键区别：**它不随会话的生命周期变化** —— 设备拔了、会话结束了
    /// 它都还在，这正是「下次插回来还是这套参数」的落点。
    @Published private(set) var deviceSettings: [String: DeviceSettings] = [:]

    /// 全局默认值。新插入的设备按它初始化，没单独设置过的设备一直用它。
    @Published private(set) var defaultSettings: DeviceSettings = .fallback

    /// 参数卡片正在编辑哪台设备。nil = 一台设备都没有，这时编辑的是默认值。
    ///
    /// **不持久化。** 上一版删掉 `lastDeviceSerial` 的理由是「每 3 秒重选一次会让停止按钮
    /// 的目标在用户手底下移动」—— 那是**动作路由**的问题；这里选中项只决定**参数卡片
    /// 编辑谁**，所有动作按钮各自按 `row.serial` 路由，那条理由不成立。
    /// 不持久化是另一条理由：启动瞬间 adb 还没扫完，把上次那台恢复出来会先显示一段
    /// 「正在编辑一台列表里还没有的设备」，等扫完再自己跳一次。
    @Published private(set) var selectedSerial: String?

    // MARK: - 设置（全局，写回 Preferences）

    @Published var cascadeWindows: Bool { didSet { preferences.cascadeWindows = cascadeWindows } }
    @Published var recordingDirectory: String { didSet { preferences.recordingPath = recordingDirectory } }
    @Published var adbPathOverride: String { didSet { preferences.adbPathOverride = adbPathOverride.isEmpty ? nil : adbPathOverride } }

    // MARK: - 依赖

    private let preferences = Preferences.shared
    private let engineStore = EngineStore.shared
    private let engineUpdater = EngineUpdateChecker()
    private let appUpdater = AppUpdateChecker()

    /// 每台设备一路会话，key 是 serial。
    ///
    /// **每次启动都新建实例，绝不复用**：`ScrcpySession.stop()` 会把当时那个 pid
    /// 交给 3 秒后的强制终止，而复用同一个实例做「停掉再开」时，那个迟到的定时器
    /// 只会看到「闸门是开的」就动手 —— 它会拿旧 pid 去 kill，并把活着的新会话判死。
    /// 每台设备的一个会话对象只服务一次启动，这条路径就不存在了。
    private var sessions: [String: ScrcpySession] = [:]

    /// 每台设备视频编码器自报的码率上限（bits/s），只读一次。只有「自动」档位用得上。
    @Published private(set) var bitrateCeilings: [String: Int] = [:]
    /// 已经问过上限的 serial。读不出来的那些也要记进来，否则每 3 秒的轮询会一直重问。
    private var checkedBitrateCeilings: Set<String> = []

    private var pollTimer: Timer?
    private var flushTimer: Timer?
    private var pendingEngineUpdate: EngineReleaseInfo?
    private var pendingAppRelease: AppReleaseInfo?
    private var stagedAppURL: URL?

    /// 退出流程的计数与完成回调，见 `stopForTermination`。
    private var terminationRemaining = 0
    private var terminationCompletion: (() -> Void)?
    private var terminationTimer: Timer?

    /// 还没凑成整行的日志尾巴，**按来源各留一份**。scrcpy 一次 write 不一定正好是一行，
    /// 不留尾巴的话半行会被当成完整行渲染出来；多设备共用一份尾巴则会把两台设备的
    /// 半行拼到一起。key 用 serial，App 自己的输出用空串。
    private var partialLines: [String: String] = [:]
    /// 待刷新的日志块。带上来源，刷新时才分得清是谁吐的。
    private var pendingChunks: [(text: String, from: String?)] = []
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
        defaultSettings = preferences.defaultSettings
        deviceSettings = preferences.deviceOverrides
        cascadeWindows = preferences.cascadeWindows
        recordingDirectory = preferences.recordingPath
        adbPathOverride = preferences.adbPathOverride ?? ""
    }

    /// 启动后调用一次：收尾上次更新、清理孤儿进程、准备引擎、开日志刷新。
    func start() {
        startFlushTimer()

        // 必须在静默检查之前：新版本启动时要给 helper 发成功信号；
        // 回滚后的旧版本要读出失败原因，而不是被一次「已是最新」覆盖掉。
        if let result = AppInstaller.acknowledgeLaunchIfNeeded() {
            switch result {
            case .updated(let version):
                appUpdateState = .updated(version)
                appendLog("[应用更新] 已更新到 \(version)。\n")
            case .failed(let message):
                appUpdateState = .failed(message)
                appendLog("[应用更新] 上次更新失败：\(message)\n")
            }
        }
        appUpdater.cleanupStaleStaging()

        prepareEngine()
        checkAppUpdate(silent: true)
    }

    func shutdown() {
        pollTimer?.invalidate()
        flushTimer?.invalidate()
        terminationTimer?.invalidate()
        engineUpdater.cancel()
        appUpdater.cancel()
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

        engineUpdater.check(current: "0") { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.available(let info)):
                    self.pendingEngineUpdate = info
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
                // 内容没变就不赋值。设备行变多之后，每 3 秒一次无意义的
                // `@Published` 会把整页卡片全部重算一遍。
                if found != self.devices { self.devices = found }
                for device in found { self.lastKnownName[device.serial] = device.displayName }
                // 设备增删之后，参数卡片的编辑对象可能得顺位（插上第一台、拔掉选中的那台）。
                self.reconcileEditingSelection()
                for device in found { self.readBitrateCeiling(for: device) }
            }
        }
    }

    /// 读一次这台设备编码器自报的码率上限，读到了就记住。
    ///
    /// 每台设备只读一次：它只随设备变，不随连接方式变，而每 3 秒一次的轮询里
    /// 多跑一条 `adb shell` 是白花的。读不到（老机型没有那份 XML）就记成「问过了、
    /// 没有」—— 否则每次轮询都会再问一遍，而这正是它读不出来的情况。
    private func readBitrateCeiling(for device: AdbDevice) {
        guard !checkedBitrateCeilings.contains(device.serial) else { return }
        checkedBitrateCeilings.insert(device.serial)

        let client = adbClient
        let serial = device.serial
        DispatchQueue.global(qos: .utility).async {
            let ceiling = client.encoderBitrateCeiling(serial: serial)
            guard let ceiling else { return }
            DispatchQueue.main.async { self.bitrateCeilings[serial] = ceiling }
        }
    }

    /// 这台设备的编码器码率上限（bits/s）。nil = 问不出来或还没问到。
    func bitrateCeiling(for serial: String?) -> Int? {
        guard let serial else { return nil }
        return bitrateCeilings[serial]
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

    /// 这台设备能不能现在开一路。
    func canStart(serial: String) -> Bool {
        engine != nil && updateBlocker == nil && startableSerials.contains(serial)
    }

    var canStartAny: Bool {
        engine != nil && updateBlocker == nil && !startableSerials.isEmpty
    }

    // MARK: - 参数（按设备）

    /// 这台设备当前生效的参数。没有独立条目就跟随默认值。
    func settings(for serial: String) -> DeviceSettings {
        deviceSettings[serial] ?? defaultSettings
    }

    /// 这台设备有没有单独设置过 —— 也就是有没有独立条目。
    func isCustomized(_ serial: String) -> Bool {
        deviceSettings[serial] != nil
    }

    var selectedRow: DeviceRow? {
        rows.first { $0.serial == selectedSerial }
    }

    func select(serial: String) {
        guard selectedSerial != serial else { return }
        selectedSerial = serial
    }

    /// 参数卡片正在展示的那一份（没有选中设备时就是默认值本身）。
    var editedSettings: DeviceSettings {
        guard let selectedSerial else { return defaultSettings }
        return settings(for: selectedSerial)
    }

    /// 参数卡片用的绑定。
    ///
    /// 不用 `$model.editing[\.maxSize]` 那种写法：`$` 投影只对**存储属性**有效，要拿到
    /// `Binding<DeviceSettings>` 就得把「当前那一份」做成存起来的镜像、再靠 `didSet` 回写，
    /// 于是多出「选中项 / 镜像 / 字典」三者之间一条必须永远成立的不变量（切换设备时那次
    /// 回写还得额外拿一个标志挡住，否则光是点一下别的设备，就会给一台从没配过的设备凭空
    /// 建出条目）。这里按选中项查字典算出来，本来就没有可投影的东西。
    ///
    /// 闭包在主 actor 里构造：`Binding.init` 的 get/set 是 `@_inheritActorContext` 的，
    /// 在闭包里读写主 actor 状态合法。**不要**给闭包显式标 `@MainActor`，类型会对不上。
    func binding<T>(_ keyPath: WritableKeyPath<DeviceSettings, T>) -> Binding<T> {
        Binding(
            get: { self.editedSettings[keyPath: keyPath] },
            set: { newValue in self.updateEditedSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// 改「当前编辑对象」的某一项。
    ///
    /// 有选中设备时**只改那台**，而且第一次改就给它建一份独立条目 —— 这就是
    /// 「新设备跟着默认值走，一旦动过它就脱离默认」的落点。
    private func updateEditedSettings(_ mutate: (inout DeviceSettings) -> Void) {
        if let selectedSerial {
            var next = settings(for: selectedSerial)
            mutate(&next)
            store(next, for: selectedSerial)
            return
        }
        var next = defaultSettings
        mutate(&next)
        guard next != defaultSettings else { return }
        defaultSettings = next
        preferences.defaultSettings = next
    }

    /// 与默认值完全相同的条目直接删掉。
    ///
    /// 这样「有没有条目」严格等价于「有没有单独设置过」。否则把开关来回拨一遍就会留下
    /// 一条和默认值一模一样的记录，作用域条上的「单独设置」就开始说谎了。
    private func store(_ settings: DeviceSettings, for serial: String) {
        if settings == defaultSettings {
            deviceSettings[serial] = nil
        } else {
            deviceSettings[serial] = settings
        }
        preferences.deviceOverrides = deviceSettings
    }

    /// 把这台改回跟随默认值。
    func resetToDefault(_ serial: String) {
        guard deviceSettings[serial] != nil else { return }
        deviceSettings[serial] = nil
        preferences.deviceOverrides = deviceSettings
        appendLog("[参数] \(lastKnownName[serial] ?? serial) 已恢复为跟随默认值。\n")
    }

    /// 把这台的参数设成新设备的默认值。
    ///
    /// 动手之前要先把「正在跟随默认值」的那些设备按**旧**默认值固定下来：不然这一步会把
    /// 它们一起改掉，而这个动作在界面上写的是「其他设备不动」—— 说了不动就得真的不动。
    /// 已经单独设置过的设备本来就不受影响。
    func setSelectedAsDefault() {
        guard let serial = selectedSerial, let mine = deviceSettings[serial] else { return }
        let previous = defaultSettings
        for row in rows where deviceSettings[row.serial] == nil {
            deviceSettings[row.serial] = previous
        }
        defaultSettings = mine
        preferences.defaultSettings = mine
        preferences.deviceOverrides = deviceSettings
        appendLog("[参数] 已把 \(lastKnownName[serial] ?? serial) 的这套设为新设备的默认值。\n")
    }

    /// 把这一套应用到所有设备（含以后插入的）。
    ///
    /// 做法是「写进默认值 + 清空全部独立条目」，而不是逐台拷一份相同的值：两者当前结果
    /// 完全一样，区别在以后 —— 跟随默认值的会跟着默认值一起动，拷贝出去的不会。用户点的
    /// 既然是「应用到所有设备」，往后新插的设备自然也该用这一套。
    ///
    /// 这是整个界面里唯一会丢掉别的设备改动的动作，所以它不裸放在卡片上，收在作用域菜单里。
    func applySelectedToAllDevices() {
        guard let serial = selectedSerial else { return }
        let settings = self.settings(for: serial)
        let count = rows.count
        defaultSettings = settings
        deviceSettings.removeAll()
        preferences.defaultSettings = settings
        preferences.deviceOverrides = [:]
        appendLog("[参数] 已把 \(lastKnownName[serial] ?? serial) 的这套应用到全部 \(count) 台设备。\n")
    }

    /// 选中项不在列表里了就顺位到第一行 —— **只要还有设备，参数卡片就总有一台可指**。
    ///
    /// 「有设备、却一台都没选中」那种半截状态必须避免：那时卡片编辑的是默认值，用户改了
    /// 参数却发现设备没变，是最难自己想明白的一类问题。
    ///
    /// 只有当原来那台真的消失了才会顺位（拔线、拔线后会话退出），所以不会出现
    /// 「用户选着 A，界面自己跳到 B」那种情况。
    private func reconcileEditingSelection() {
        let serials = rows.map(\.serial)
        if let selectedSerial, serials.contains(selectedSerial) { return }
        selectedSerial = serials.first
    }

    /// 给某台设备建一路会话，并把回调接上。
    ///
    /// 每个回调都要**先验身份再改状态**：`ScrcpySession` 的回调走 `onMain`，
    /// 而它在主线程上是同步内联执行的（强行终止的兜底就是从主队列调过去的）。
    /// 一旦「回调到了就把 sessions[serial] 清掉」，同一台设备「停掉再立刻重开」时，
    /// 旧会话的迟到回调会删掉新会话 —— 表现是进程还活着、pid 文件还在、
    /// 界面却显示空闲，用户再点一次就是同一台设备上第二个 scrcpy。
    private func makeSession(for serial: String) -> ScrcpySession {
        let session = ScrcpySession(serial: serial)

        session.onLog = { [weak self] text in
            self?.appendLog(text, from: serial)
        }
        session.onStateChange = { [weak self] state in
            guard let self, self.sessions[serial] === session else { return }
            self.sessionStates[serial] = state
        }
        session.onExit = { [weak self] status in
            guard let self else { return }
            // 补一个换行，把可能残留的半行冲出来 —— 否则崩溃日志的最后一行会被吞掉。
            self.appendLog("\n[scrcpy 已退出，status=\(status)]\n", from: serial)
            guard self.sessions[serial] === session else { return }
            self.sessions[serial] = nil
            self.sessionStates[serial] = nil
            // 设备已经被拔掉的那条「只剩会话」的行到这一刻才消失，选中项可能得顺位。
            self.reconcileEditingSelection()
            self.sleepDeviceIfNeeded(serial: serial)
        }
        return session
    }

    /// 投屏结束后把手机屏幕按灭（「行为」里的可选项，**按设备**）。
    ///
    /// 必须等 scrcpy **真的退干净**才发这个 keyevent：开了「投屏时关闭手机屏幕」的话，
    /// scrcpy 退出时会先把屏幕恢复成亮的，抢在它前面发等于白发。
    /// 这里由 `onExit` 触发（进程已经没了），再留一点余量给设备侧的清理。
    ///
    /// 读的是**停止这一刻**那台设备的设置，不是启动时的快照：这一项根本不进 scrcpy 的
    /// 命令行，它是 App 在进程退出后自己补的一刀，「现在要不要按灭」当然以现在为准。
    ///
    /// 值必须在跳队列之前读完：`settings(for:)` 是主 actor 上的方法，而 `asyncAfter` 的
    /// 闭包是 `@Sendable` 的。好在值不在 `sessions[serial]` 里，清空会话不会弄丢它。
    private func sleepDeviceIfNeeded(serial: String) {
        guard settings(for: serial).screenOffOnStop else { return }
        let client = adbClient
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
            client.sleepScreen(serial: serial)
        }
    }

    func startSession(serial: String) {
        guard sessions[serial] == nil else { return }
        guard let engine else {
            appendLog("[错误] 引擎还没准备好。\n", from: serial)
            return
        }
        guard let device = devices.first(where: { $0.serial == serial }), device.isReady else {
            appendLog("[错误] \(lastKnownName[serial] ?? serial) 当前不可用。\n", from: serial)
            return
        }
        // 更新期间不允许投屏：替换引擎目录时如果有 scrcpy 正在跑（尤其是刚起、
        // 还没把 server jar 推到设备上的那种），会把正在用的文件换掉。
        if let blocker = updateBlocker {
            appendLog("[错误] \(blocker)\n", from: serial)
            return
        }

        // **按 serial 取参数，不是按选中项**：`startAll()` 一次起多台，每一路都必须拿自己
        // 那份。「选中 A 时点 B 的投屏」如果取了当前编辑的那一份，就是把 A 的参数发给了 B。
        let settings = self.settings(for: serial)
        let context = Preferences.ArgumentContext(
            settings: settings,
            device: device,
            recordingFileName: recordingFileName(for: device, settings: settings),
            windowTitle: windowTitle(for: device),
            windowSlot: nextWindowSlot(),
            bitrateCeiling: bitrateCeiling(for: serial)
        )
        let args = preferences.buildArguments(context)

        let session = makeSession(for: serial)
        // 先登记再启动：启动过程中状态回调是**同步**来的，晚一步登记就会被身份校验丢掉。
        // 反过来，万一进程秒退，onExit 也会同步跑完并把这一条清掉，不会留个死条目挡着重试。
        sessions[serial] = session
        sessionStates[serial] = .starting

        appendLog("[启动] \(device.displayName)：scrcpy \(args.joined(separator: " "))\n\n", from: serial)
        do {
            try session.start(engine: engine, arguments: args, supportDir: engineStore.supportDir)
        } catch {
            if sessions[serial] === session {
                sessions[serial] = nil
                sessionStates[serial] = nil
            }
            appendLog("[错误] \(error.localizedDescription)\n", from: serial)
            return
        }
        if sessions[serial] === session {
            sessionStates[serial] = session.state
        }
    }

    /// 这台设备是多设备里的一员时，标题带上序列号尾号 ——
    /// 两台同型号手机并排投屏时，光看型号分不清哪个窗口是哪个。
    private func windowTitle(for device: AdbDevice) -> String? {
        guard devices.count > 1 else { return nil }
        let tail = device.serial.suffix(4)
        return "\(device.displayName) · \(tail)"
    }

    /// 窗口错开用的序号：已经有几路在跑，就往后排几个。
    ///
    /// 只有一台设备时返回 nil —— scrcpy 默认会把窗口摆在舒服的位置，
    /// 单台场景没理由改变它。错开是「多个窗口会精确重叠」这个问题的对策，
    /// 只有一个窗口时那个问题不存在。
    private func nextWindowSlot() -> Int? {
        guard cascadeWindows, devices.count > 1 else { return nil }
        return sessionStates.values.filter { $0 != .idle }.count
    }

    private var updateBlocker: String? {
        switch engineUpdateState {
        case .downloading: "正在下载引擎更新，稍后再试。"
        case .checking: "正在检查更新，稍后再试。"
        default: nil
        }
    }

    /// 起所有「就绪且还没有会话」的设备。
    func startAll() {
        for serial in startableSerials { startSession(serial: serial) }
    }

    func stopSession(serial: String) {
        guard let session = sessions[serial] else { return }
        session.stop { [weak self] in
            self?.appendLog("\n[已停止]\n", from: serial)
        }
    }

    /// 停掉所有会话。先取快照再遍历 —— 回调可能是同步内联的，
    /// 边遍历字典边在里面改它会当场撞上 Swift 的独占性检查。
    func stopAll() {
        for session in Array(sessions.values) { session.stop {} }
    }

    /// 正在跑的 scrcpy 子进程 pid。点程序坞图标时用它把镜像窗口拉到前台
    /// —— 那是另一个进程的窗口，我们只能通过 `NSRunningApplication` 激活它。
    var childPIDs: [pid_t] {
        sessions.values.compactMap(\.childPID)
    }

    /// 正在投屏的设备（按界面顺序）。程序坞右键菜单要照着它列。
    var runningMirrors: [(serial: String, name: String)] {
        rows.filter { $0.state == .running }.map { ($0.serial, $0.name) }
    }

    /// 把某台设备的投屏窗口提到最前，必要时把控制面板挪开。
    /// 没在投屏时是空操作（没有子进程可激活）。
    func bringMirrorToFront(serial: String) {
        guard let pid = sessions[serial]?.childPID else { return }
        MirrorWindows.reveal(pids: [pid])
    }

    /// 退出流程专用：停干净了才回调，供 `applicationShouldTerminate` 回 `.terminateLater`。
    /// 和 `stopSession()` 的区别是它必须给出一个确定的完成信号。
    ///
    /// 两个约束：一是**并行**停（串行的话 N 台设备最坏就是 N×5 秒，
    /// 系统会以为这个 App 卡死了）；二是给一个总时限，个别会话卡在僵死的 adb 连接上时
    /// 不能把退出流程一起拖住 —— 没退干净的留给下次启动的 `reapOrphans`，
    /// 那正是 pid 文件存在的理由。
    ///
    /// 计数与完成回调存在属性上而不是局部变量里：超时兜底是另一个闭包，
    /// 把局部 `var` 捕获进 `asyncAfter` 那种 `@Sendable` 闭包会引入数据竞争警告。
    func stopForTermination(completion: @escaping () -> Void) {
        let snapshot = Array(sessions.values)
        guard !snapshot.isEmpty else {
            completion()
            return
        }

        terminationCompletion = completion
        terminationRemaining = snapshot.count

        for session in snapshot {
            // 回调里不直接改状态：这里可能正走在 `stop()` 的循环里，
            // 隔一拍回主队列更稳，也顺便让下面那行计时器先挂上。
            session.stop { [weak self] in
                Task { @MainActor in self?.terminationArrived() }
            }
        }
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishTermination() }
        }
    }

    private func terminationArrived() {
        guard terminationCompletion != nil else { return }
        terminationRemaining -= 1
        if terminationRemaining <= 0 { finishTermination() }
    }

    private func finishTermination() {
        guard let completion = terminationCompletion else { return }
        terminationCompletion = nil
        terminationTimer?.invalidate()
        terminationTimer = nil
        completion()
    }

    /// 录制文件名：带设备名 + 时间戳。
    /// 时间戳是为了第二次录制不覆盖第一次；设备名是为了**两台设备同一秒开始录**时
    /// 不会在同一个目录里撞出同一个文件名。
    ///
    /// 开关取的是传进来的那份设置 —— 目录是全局的，只有开关按设备分。
    private func recordingFileName(for device: AdbDevice, settings: DeviceSettings) -> String? {
        guard settings.recordingEnabled else { return nil }
        let formatter = DateFormatter()
        // 固定 en_US_POSIX：`Preferences` 里那份时间戳一直是这么写的，
        // 不写的话非公历区域会得到一个完全意想不到的文件名。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = device.displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "scrcpy-\(name)-\(formatter.string(from: Date())).mp4"
    }

    // MARK: - 日志

    /// 记一行日志。`from` 是来源设备的 serial，nil = App 自己的输出。
    private func appendLog(_ text: String, from serial: String? = nil) {
        pendingChunks.append((text: text, from: serial))
    }

    /// 来源显示名。设备掉线后 `devices` 里没有了，退回缓存的名字。
    private func sourceName(for serial: String) -> String {
        devices.first { $0.serial == serial }?.displayName
            ?? lastKnownName[serial]
            ?? serial
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
        let chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: true)

        var lines = logLines
        for chunk in chunks {
            // 半行尾巴按来源各留一份，否则两台设备的半行会拼成同一行。
            let key = chunk.from ?? ""
            var pieces = ((partialLines[key] ?? "") + chunk.text).components(separatedBy: "\n")
            // 最后一段没有换行收尾，说明这行还没写完，留着跟下一批拼。
            partialLines[key] = pieces.removeLast()
            guard !pieces.isEmpty else { continue }

            let source = chunk.from.map { LogSource(serial: $0, name: sourceName(for: $0)) }
            for text in pieces {
                lines.append(LogLine(id: nextLogID, text: text, source: source))
                nextLogID += 1
            }
        }
        guard lines.count != logLines.count else { return }
        if lines.count > logLineLimit {
            lines.removeFirst(lines.count - logLineLimit)
        }
        logLines = lines
    }

    func clearLog() {
        pendingChunks.removeAll()
        partialLines.removeAll()
        logLines.removeAll()
        // 选中的来源已经没日志了，留着会显示一个空白的日志区。
        logSource = nil
    }

    // MARK: - 更新

    /// 检查引擎更新。
    ///
    /// `silent` 是启动时那次后台检查用的：**只在发现新版时才动界面**。
    /// 「已是最新」「没网」「被 GitHub 限流」这些都不该在启动时弹给用户看 ——
    /// 他什么都没点，凭什么要读一条错误。
    func checkForUpdates(silent: Bool = false) {
        // 判据是 anySessionActive 而不是 isRunning：「停止中」的那几秒里进程还活着，
        // 而替换引擎目录是整目录改名，不能和任何一个还没退干净的会话重叠。
        guard !anySessionActive else {
            if !silent { engineUpdateState = .failed("请先停止投屏再检查更新。") }
            return
        }
        let current = engine?.version ?? "0"
        if !silent {
            engineUpdateState = .checking
            appendLog("[更新] 正在检查（当前 \(current)）…\n")
        }

        engineUpdater.check(current: current) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.upToDate(let version)), .success(.notModified(let version)):
                    guard !silent else { return }
                    self.engineUpdateState = .upToDate(version)
                    self.appendLog("[更新] 已是最新版 \(version)。\n")
                case .success(.available(let info)):
                    self.pendingEngineUpdate = info
                    self.engineUpdateState = .available(info.version)
                    self.appendLog("[更新] 发现新版本 scrcpy \(info.version)。\n")
                case .failure(let error):
                    guard !silent else { return }
                    self.engineUpdateState = .failed(error.localizedDescription)
                    self.appendLog("[更新] 检查失败：\(error.localizedDescription)\n")
                }
            }
        }
    }

    func downloadPendingUpdate() {
        guard let info = pendingEngineUpdate else { return }
        guard !anySessionActive else {
            engineUpdateState = .failed("请先停止投屏再更新。")
            return
        }
        install(info, isFirstRun: false)
    }

    /// 下载并安装。首次自动装与用户手动点「更新到 x.y.z」走的是同一条路，
    /// 只有收尾时给出的反馈不同。
    private func install(_ info: EngineReleaseInfo, isFirstRun: Bool) {
        // 入口守卫之外再自检一次：真正动引擎目录的是下面那个下载完成回调，
        // 而首次自动安装那条路径根本没有入口守卫。多设备之后「现在有几路在跑」
        // 是个随时会变的值，只靠调用方在几秒前问过一次是不够的。
        guard !anySessionActive else {
            engineUpdateState = .failed("请先停止投屏再更新。")
            return
        }
        engineUpdateState = .downloading(0)
        appendLog("[更新] 开始下载 scrcpy \(info.version)（\(info.assetName)）…\n")

        engineUpdater.download(info, progress: { [weak self] value in
            DispatchQueue.main.async { self?.engineUpdateState = .downloading(value) }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let staging):
                    guard !self.anySessionActive else {
                        self.engineUpdateState = .failed("投屏已经开始了，先停止再更新。")
                        return
                    }
                    // 安装本身要挪到后台：里面有一次最长 15 秒的同步冒烟测试，
                    // 而主队列同时是各会话「正在停止」的强制终止计时器所在的队列，
                    // 堵在这里会把好几路会话的收尾一起冻住。
                    self.installInBackground(staging, isFirstRun: isFirstRun)
                case .failure(let error):
                    self.failEngineSetup(error.localizedDescription)
                    self.engineUpdateState = .failed(error.localizedDescription)
                    self.appendLog("[更新] 下载失败：\(error.localizedDescription)\n")
                }
            }
        })
    }

    /// 落盘那一段放到后台队列，回到主队列再更新界面。
    private func installInBackground(_ staging: URL, isFirstRun: Bool) {
        let store = engineStore
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // acceptEngine 而不是只赋值 `engine`：它顺带把 isPreparingEngine
                // 收掉、清掉 engineMessage，并热一次 adb、刷一次设备列表 ——
                // 首次自动装完这一串都必须做，否则界面会停在「正在准备引擎」。
                let installed = try store.install(from: staging)
                DispatchQueue.main.async {
                    self.acceptEngine(installed, note: "[更新] 引擎已就绪：scrcpy \(installed.version)。\n")
                    self.engineUpdateState = isFirstRun ? .engineReady(installed.version) : .installed(installed.version)
                }
            } catch {
                DispatchQueue.main.async {
                    self.failEngineSetup(error.localizedDescription)
                    self.engineUpdateState = .failed(error.localizedDescription)
                    self.appendLog("[更新] 安装失败：\(error.localizedDescription)\n")
                }
            }
        }
    }

    func dismissEngineUpdateState() {
        engineUpdateState = .idle
        pendingEngineUpdate = nil
    }

    // MARK: - App 本体更新

    /// 菜单里的「检查更新…」：两个都查，各自独立报告。
    func checkAllUpdates() {
        checkAppUpdate()
        checkForUpdates()
    }

    /// 检查 App 本体。投屏期间也允许——这一步不碰任何正在运行的进程。
    func checkAppUpdate(silent: Bool = false) {
        switch appUpdateState {
        case .checking, .downloading, .preparing, .ready, .installing:
            return
        default:
            break
        }

        if !silent {
            appUpdateState = .checking
            appendLog("[应用更新] 正在检查（当前 \(AppInfo.version)）…\n")
        }

        appUpdater.check(current: AppInfo.version) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.upToDate(let version)), .success(.notModified(let version)):
                    guard !silent else { return }
                    self.appUpdateState = .upToDate(version)
                    self.appendLog("[应用更新] 已是最新版 \(version)。\n")
                case .success(.available(let info)):
                    self.pendingAppRelease = info
                    self.appUpdateState = .available(info.version)
                    self.appendLog("[应用更新] 发现新版本 \(info.version)。\n")
                case .failure(let error):
                    guard !silent else { return }
                    self.appUpdateState = .failed(error.localizedDescription)
                    self.appendLog("[应用更新] 检查失败：\(error.localizedDescription)\n")
                }
            }
        }
    }

    /// 下载并校验。投屏期间也能做，真正会打断投屏的是后面的重启。
    func downloadAppUpdate() {
        guard let info = pendingAppRelease else { return }
        switch appUpdateState {
        case .downloading, .preparing, .ready, .installing:
            return
        default:
            break
        }

        appUpdateState = .downloading(0)
        appendLog("[应用更新] 开始下载 \(info.version)（\(info.assetName)）…\n")

        appUpdater.download(info, progress: { [weak self] value in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appUpdateState = value >= 1.0 ? .preparing : .downloading(value)
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let app):
                    self.stagedAppURL = app
                    self.appUpdateState = .ready(info.version)
                    self.appendLog("[应用更新] \(info.version) 已下载并通过校验。\n")
                case .failure(let error):
                    self.appUpdateState = .failed(error.localizedDescription)
                    self.appendLog("[应用更新] 下载失败：\(error.localizedDescription)\n")
                }
            }
        })
    }

    /// 重启更新之前的所有阻碍。nil = 可以开始。
    var appInstallBlocker: String? {
        if anySessionActive { return "先停止投屏，再重启更新。" }
        if isPreparingEngine { return "引擎还在准备中，稍后再更新 App。" }
        if case .downloading = engineUpdateState { return "引擎正在更新，稍后再更新 App。" }
        return AppInstaller.installBlocker()
    }

    /// 是否还有一份下载好、等着安装的 App（失败后可以直接重试安装）。
    var hasStagedAppUpdate: Bool { stagedAppURL != nil }

    func installAppUpdate() {
        // 不要求当前状态一定是 `.ready`：安装失败后 stagedAppURL 还在，
        // 用户点「重试安装」应当复用同一份包，而不是重新下载。
        guard let staged = stagedAppURL, let version = pendingAppRelease?.version else { return }
        if case .installing = appUpdateState { return }
        if let blocker = appInstallBlocker {
            appUpdateState = .failed(blocker)
            appendLog("[应用更新] \(blocker)\n")
            return
        }

        appUpdateState = .installing
        appendLog("[应用更新] 正在替换 App 并准备重启…\n")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppInstaller.install(stagedApp: staged, expectedVersion: version)
                DispatchQueue.main.async {
                    self.stagedAppURL = nil
                    // helper 已经在等本进程退出；留一小段时间让界面把
                    // 「正在退出」刷出来，也确保 Process 已经完成 spawn。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.appUpdateState = .failed(error.localizedDescription)
                    self.appendLog("[应用更新] 安装失败：\(error.localizedDescription)\n")
                }
            }
        }
    }

    func discardAppUpdate() {
        if let staged = stagedAppURL { appUpdater.discard(staged) }
        stagedAppURL = nil
        pendingAppRelease = nil
        appUpdateState = .idle
    }

    func dismissAppUpdateState() {
        appUpdateState = .idle
    }
}
