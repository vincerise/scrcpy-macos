//  Preferences.swift
//  Scrcpy
//

import Foundation

/// 一台设备的投屏参数。
///
/// 收成一个 struct 而不是给每项单开一组 (serial, 值) 的 key：卡片要读「这台的全部参数」、
/// 要能整份替换 ——「应用到所有设备」「恢复默认」「新设备继承默认」这三件事在 struct 上
/// 各自就是一行，散成十个 key 就得各写十遍。
///
/// 三项**不在这里**，它们是全机一份：`cascadeWindows`（它描述的是「整组窗口」这件事，
/// 不属于任何一台设备）、`recordingPath`（录制目录）、`adbPathOverride`（adb 只有一个）。
struct DeviceSettings: Equatable, Codable {

    var maxSize: Int
    var videoBitRate: String
    var maxFPS: Int
    var audioEnabled: Bool
    var turnScreenOff: Bool
    var stayAwake: Bool

    /// 停止投屏之后把设备屏幕按灭。默认关 —— 有人正是为了看一眼手机才投屏，
    /// 投完顺手替他熄屏会打乱他接下来的操作。
    ///
    /// 和 `turnScreenOff`（投屏期间息屏，scrcpy 的 `--turn-screen-off`）是两件事：
    /// 那个由 scrcpy 自己负责，**退出时它会把屏幕恢复成亮的**；这个是在那之后
    /// 再补一刀，所以必须等进程真的退干净了才发。
    var screenOffOnStop: Bool

    var alwaysOnTop: Bool
    var recordingEnabled: Bool
    var extraArguments: String

    /// 兜底值。**必须与 `Preferences.init` 里那份 `register(defaults:)` 对得上** ——
    /// 那份决定「这台设备第一次读到的值」，这份决定「JSON 里缺这个字段时的值」。
    static let fallback = DeviceSettings(
        maxSize: 0,
        videoBitRate: "auto",
        maxFPS: 0,
        audioEnabled: true,
        turnScreenOff: false,
        stayAwake: false,
        screenOffOnStop: false,
        alwaysOnTop: false,
        recordingEnabled: false,
        extraArguments: ""
    )
}

extension DeviceSettings {

    /// 手写解码。
    ///
    /// 合成的 Codable 遇到「JSON 里没有这个字段」会整份抛错，而所有设备的参数存在
    /// **同一个 key** 里 —— 一次失败就是全部设备的独立参数一起消失，回落到默认值，
    /// 而且界面上不会有任何提示。以后往这个 struct 里加字段时，老 JSON 必然缺那个键，
    /// 所以这里逐个 `decodeIfPresent` 兜底：加字段从此不需要迁移代码。
    ///
    /// 写在 extension 里而不是类型体里：写在体里会把 memberwise init 顶掉，
    /// 上面的 `static let fallback` 就编译不过了。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DeviceSettings.fallback

        maxSize = try container.decodeIfPresent(Int.self, forKey: .maxSize) ?? fallback.maxSize
        videoBitRate = try container.decodeIfPresent(String.self, forKey: .videoBitRate)
            ?? fallback.videoBitRate
        maxFPS = try container.decodeIfPresent(Int.self, forKey: .maxFPS) ?? fallback.maxFPS
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled)
            ?? fallback.audioEnabled
        turnScreenOff = try container.decodeIfPresent(Bool.self, forKey: .turnScreenOff)
            ?? fallback.turnScreenOff
        stayAwake = try container.decodeIfPresent(Bool.self, forKey: .stayAwake) ?? fallback.stayAwake
        screenOffOnStop = try container.decodeIfPresent(Bool.self, forKey: .screenOffOnStop)
            ?? fallback.screenOffOnStop
        alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop)
            ?? fallback.alwaysOnTop
        recordingEnabled = try container.decodeIfPresent(Bool.self, forKey: .recordingEnabled)
            ?? fallback.recordingEnabled
        extraArguments = try container.decodeIfPresent(String.self, forKey: .extraArguments)
            ?? fallback.extraArguments
    }
}

/// 用户偏好，全部落在 `UserDefaults` 里。
///
/// 刻意不做 `ObservableObject`：SwiftUI 的 `@Published` 需要一层镜像属性，
/// UI 那边已经各自持有一份（见 `AppModel`），这里就只负责存取和拼参数。
final class Preferences {

    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        // 前十个是「默认值」那一份。老用户升级之后它们原地变成默认值，
        // 所以 raw string 一个字都不能改。
        static let maxSize = "scrcpy.maxSize"
        static let videoBitRate = "scrcpy.videoBitRate"
        static let maxFPS = "scrcpy.maxFPS"
        static let audioEnabled = "scrcpy.audioEnabled"
        static let turnScreenOff = "scrcpy.turnScreenOff"
        static let stayAwake = "scrcpy.stayAwake"
        static let alwaysOnTop = "scrcpy.alwaysOnTop"
        static let recordingEnabled = "scrcpy.recordingEnabled"
        static let extraArguments = "scrcpy.extraArguments"
        static let screenOffOnStop = "scrcpy.screenOffOnStop"

        // 下面三个不按设备分。
        static let recordingPath = "scrcpy.recordingPath"
        static let cascadeWindows = "scrcpy.cascadeWindows"
        static let adbPathOverride = "scrcpy.adbPathOverride"

        /// 每台设备单独设置过的参数。值是 JSON 字符串，见 `deviceOverrides`。
        static let deviceOverrides = "scrcpy.deviceSettings"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 注册默认值而不是在每个 getter 里写兜底：`integer(forKey:)` 对不存在的键
        // 返回 0，而 0 在我们的语义里是「原始分辨率」这个合法取值，两者分不开。
        //
        // `adbPathOverride` **故意不在表里**：它的 nil 是「用内置 adb」这个有意义的取值，
        // 注册成空串会让 `string(forKey:)` 从 nil 变成 ""，`EngineStore.adbURL(override:)`
        // 就得额外判空。
        defaults.register(defaults: [
            Key.maxSize: 0,
            Key.videoBitRate: "auto",
            Key.maxFPS: 0,
            Key.audioEnabled: true,
            Key.turnScreenOff: false,
            Key.stayAwake: false,
            Key.alwaysOnTop: false,
            Key.recordingEnabled: false,
            Key.recordingPath: "~/Movies",
            Key.extraArguments: "",
            Key.cascadeWindows: true,
            Key.screenOffOnStop: false,
        ])
    }

    // MARK: - 默认值

    /// 全局默认值：新插入的设备按它初始化，没单独设置过的设备也一直用它。
    ///
    /// 复用的就是老的 `scrcpy.maxSize` 那十个 key —— 所以**老用户升级之后，原来那份设置
    /// 天然就是默认值，一行迁移代码都不需要**。
    var defaultSettings: DeviceSettings {
        get {
            DeviceSettings(
                maxSize: defaults.integer(forKey: Key.maxSize),
                videoBitRate: defaults.string(forKey: Key.videoBitRate)
                    ?? DeviceSettings.fallback.videoBitRate,
                maxFPS: defaults.integer(forKey: Key.maxFPS),
                audioEnabled: defaults.bool(forKey: Key.audioEnabled),
                turnScreenOff: defaults.bool(forKey: Key.turnScreenOff),
                stayAwake: defaults.bool(forKey: Key.stayAwake),
                screenOffOnStop: defaults.bool(forKey: Key.screenOffOnStop),
                alwaysOnTop: defaults.bool(forKey: Key.alwaysOnTop),
                recordingEnabled: defaults.bool(forKey: Key.recordingEnabled),
                extraArguments: defaults.string(forKey: Key.extraArguments) ?? ""
            )
        }
        set {
            defaults.set(newValue.maxSize, forKey: Key.maxSize)
            defaults.set(newValue.videoBitRate, forKey: Key.videoBitRate)
            defaults.set(newValue.maxFPS, forKey: Key.maxFPS)
            defaults.set(newValue.audioEnabled, forKey: Key.audioEnabled)
            defaults.set(newValue.turnScreenOff, forKey: Key.turnScreenOff)
            defaults.set(newValue.stayAwake, forKey: Key.stayAwake)
            defaults.set(newValue.screenOffOnStop, forKey: Key.screenOffOnStop)
            defaults.set(newValue.alwaysOnTop, forKey: Key.alwaysOnTop)
            defaults.set(newValue.recordingEnabled, forKey: Key.recordingEnabled)
            defaults.set(newValue.extraArguments, forKey: Key.extraArguments)
        }
    }

    // MARK: - 每台设备

    /// 每台设备单独设置过的参数，key 是 adb 的 serial。没有条目 = 跟随默认值。
    ///
    /// 存成一整块 JSON **字符串**（不是 Data、也不是每台一组 key）：
    /// - 内存里的模型就是 `[String: DeviceSettings]`，一次编解码直接对上；
    /// - `defaults read com.vincerise.scrcpymac scrcpy.deviceSettings` 直接是能读的 JSON，
    ///   以后让用户把这一行贴出来排查问题时不用先解 base64（`defaults read` 对带点号的 key
    ///   是先按字面查的，这一行确实读得出来）；
    /// - 「有没有条目」就是字典里有没有这个键，不必去数十个 key 里有没有一个存在。
    ///
    /// 代价是解码失败会一次丢掉**全部**设备的独立参数 —— 那只会在用户手改过 plist 之后
    /// 发生，而且回落到默认值仍然可用，不值得为它引入一套版本化的存储层。
    ///
    /// serial 直接当 key 是安全的：plist 的 key 允许任意字符串，`:` `.` `-` 都不引发解析问题。
    /// **不要**照抄 `ScrcpySession.pidFileName(for:)` 那套净化 —— 那是给**文件名**用的，
    /// 这里加一层反而是无谓的耦合。
    var deviceOverrides: [String: DeviceSettings] {
        get {
            guard let raw = defaults.string(forKey: Key.deviceOverrides),
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: DeviceSettings].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            // 空字典就把 key 删掉，不留一个 "{}" —— 排查时「这个 key 在不在」比它的内容
            // 更快说明问题。
            guard !newValue.isEmpty else {
                defaults.removeObject(forKey: Key.deviceOverrides)
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8) else { return }
            defaults.set(raw, forKey: Key.deviceOverrides)
        }
    }

    // MARK: - 全局项

    /// 多台同时投屏时把窗口阶梯错开。默认开 —— scrcpy 自己的窗口位置是「auto」，
    /// 几个窗口会精确重叠在一起，用户第一眼看到的是一个窗口而不是三个。
    var cascadeWindows: Bool {
        get { defaults.bool(forKey: Key.cascadeWindows) }
        set { defaults.set(newValue, forKey: Key.cascadeWindows) }
    }

    /// 存的是原始串（可能是 `~/Movies`），展开推迟到拼参数时做 ——
    /// 提前展开会把用户的家目录写进 UserDefaults，换用户或迁移备份后就是错的。
    var recordingPath: String {
        get { defaults.string(forKey: Key.recordingPath) ?? "~/Movies" }
        set { defaults.set(newValue, forKey: Key.recordingPath) }
    }

    /// 命令行 adb 覆盖路径。nil / 空 = 用内置 adb。
    var adbPathOverride: String? {
        get { defaults.string(forKey: Key.adbPathOverride) }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                defaults.set(newValue, forKey: Key.adbPathOverride)
            } else {
                defaults.removeObject(forKey: Key.adbPathOverride)
            }
        }
    }

    // MARK: - 拼参数

    /// 一次启动要用到的、偏好之外的信息。
    ///
    /// 收成一个结构而不是继续往 `buildArguments` 上加参数：设置、设备、录制文件名、
    /// 窗口标题、窗口序号这五样会一起长，散成五个形参以后每加一项都要改所有调用点。
    struct ArgumentContext {
        /// 这台设备的参数。**在 start 那一刻取好**，之后用户再改设置也不影响这一路 ——
        /// 参数是拼进命令行的，本来就只有「下次投屏生效」这一种可能。
        var settings: DeviceSettings
        var device: AdbDevice?
        var recordingFileName: String?
        /// 多台同时投屏时给窗口一个能区分的标题。
        var windowTitle: String?
        /// 第几个窗口（从 0 数）。给了就按它阶梯错开，nil = 不干预位置。
        var windowSlot: Int?
        /// 这台设备的视频编码器自报的码率上限。只有「自动」档位用得上，nil = 没读到。
        var bitrateCeiling: Int?
    }

    /// 码率的「自动」档位落到哪个值。
    ///
    /// 问得到上限就按设备来：**上限在手机那颗编码器上，不在线上** —— USB2 的 adb 通道
    /// 也有 200 Mbps 量级，插着线的时候瓶颈从来不是线。问不出来（老机型没有那份 XML）
    /// 就用 20M：1080p60 下这是肉眼无损的量级，也远在任何手机的编码能力之内。
    ///
    /// Wi-Fi 反过来刻意留余量：无线的实际吞吐随距离、干扰、同频设备浮动，
    /// 码率贴着上限给的结果是卡，不是更清晰。
    static func resolvedVideoBitRate(_ stored: String, device: AdbDevice?, ceiling: Int?) -> String {
        guard stored == autoBitRate else { return stored }
        let bits = autoBitRateBits(device: device, ceiling: ceiling)
        // scrcpy 的 -b 直接收 bits/s，不加后缀就是原值。
        return "\(bits)"
    }

    /// 「自动」档位在界面上被选中时用的那个标记值。
    static let autoBitRate = "auto"
    /// 「自动」在 USB 上问不出编码器上限时的兜底：一个不会出错、也够用的常规值。
    static let fallbackBitRateBits = 20_000_000
    /// 「自动」在 Wi-Fi 上的取值。无线链路留给它 8 Mbps 的余量。
    static let wirelessBitRateBits = 8_000_000

    static func autoBitRateBits(device: AdbDevice?, ceiling: Int?) -> Int {
        // 设备未知（比如无线地址还没连上）时按 Wi-Fi 那一档算：宁可小，不可卡。
        guard let device, !device.isWireless else { return wirelessBitRateBits }
        return ceiling ?? fallbackBitRateBits
    }

    /// 把 bits/s 写成界面上看的「60 Mbps」。
    static func bitRateLabel(bits: Int) -> String {
        let mbps = Double(bits) / 1_000_000
        return mbps == mbps.rounded()
            ? "\(Int(mbps)) Mbps"
            : String(format: "%.1f Mbps", mbps)
    }

    /// 组装 scrcpy 的命令行参数（不含可执行文件路径）。
    ///
    /// 顺序：设备 → 视频 → 音频 → 行为 → 窗口 → 录制 → 额外 → 固定项。
    /// 额外参数里出现的同名选项以用户的为准，我们算出来的那一份直接丢掉。
    func buildArguments(_ context: ArgumentContext) -> [String] {
        let settings = context.settings
        var generated: [String] = []

        // 设备。多设备连着的时候必须显式指定，否则 scrcpy 会直接报错退出。
        if let serial = context.device?.serial, !serial.isEmpty {
            generated.append("--serial=\(serial)")
        }

        // 视频
        if settings.maxSize > 0 {
            generated.append("--max-size=\(settings.maxSize)")
        }
        if !settings.videoBitRate.isEmpty {
            // 用 --video-bit-rate：--bit-rate 是废弃别名，5.0 的 --help 里已经只剩前者。
            let bitRate = Preferences.resolvedVideoBitRate(settings.videoBitRate,
                                                           device: context.device,
                                                           ceiling: context.bitrateCeiling)
            generated.append("--video-bit-rate=\(bitRate)")
        }
        if settings.maxFPS > 0 {
            generated.append("--max-fps=\(settings.maxFPS)")
        }

        // 音频。默认就是开的，所以只有关的时候需要显式说一句 ——
        // scrcpy 没有独立的 --audio 选项，开了反而会报未知参数。
        if !settings.audioEnabled {
            generated.append("--no-audio")
        }

        // 行为
        if settings.turnScreenOff {
            generated.append("--turn-screen-off")
        }
        if settings.stayAwake {
            generated.append("--stay-awake")
        }
        if settings.alwaysOnTop {
            generated.append("--always-on-top")
        }

        // 窗口
        if let slot = context.windowSlot {
            // scrcpy 的 --window-x/--window-y 默认是 `auto`，也就是几个窗口精确重叠。
            // 多台一起投时按 36pt 阶梯错开，至少让用户看得见「还有别的窗口」。
            let offset = 40 + slot * 36
            generated.append("--window-x=\(offset)")
            generated.append("--window-y=\(offset)")
        }
        if let title = context.windowTitle, !title.isEmpty {
            generated.append("--window-title=\(title)")
        }

        // 录制。目录是**全局**的（所有设备录到同一处，文件名里已经带设备名），
        // 只有开关是按设备的。
        if settings.recordingEnabled {
            generated.append("--record=\(recordingURL(named: context.recordingFileName).path)")
        }

        // 固定项。这两条不是偏好，是「让 scrcpy 在 App 里能正常跑」的必要条件：
        // 前者杜绝退出时等 stdin 卡死，后者不让它去改终端标题（我们没有终端）。
        let pinned = ["--pause-on-exit=false", "--no-terminal-title"]

        let extra = Preferences.splitArguments(settings.extraArguments)

        // 用户参数优先。同一个选项出现两次时 scrcpy 的 getopt 取最后一个，
        // 结果是「实际生效的是哪个」变得取决于我们的拼接顺序 —— 那太脆了，
        // 不如在这里就保证不重复。
        var overridden = Set<String>()
        for token in extra where token.hasPrefix("--") {
            overridden.insert(Preferences.optionName(of: token))
        }

        let configurable = generated.filter { !overridden.contains(Preferences.optionName(of: $0)) }
        let forced = pinned.filter { !overridden.contains(Preferences.optionName(of: $0)) }

        return configurable + extra + forced
    }

    /// 取 `--xxx=yyy` 里的 `--xxx`。短选项（`-m`）不参与去重 ——
    /// 我们生成的默认值全是长选项形态，用户写短选项时本就是有意绕开。
    private static func optionName(of token: String) -> String {
        String(token.prefix { $0 != "=" })
    }

    /// 录制文件的绝对路径。目录用的是全局的 `recordingPath`，不是某台设备的。
    private func recordingURL(named name: String?) -> URL {
        // 已经是绝对路径就原样用（调用方可能想让文件落在别处）。
        if let name, name.hasPrefix("/") { return URL(fileURLWithPath: name) }

        var directory = (recordingPath as NSString).expandingTildeInPath
        // --record 给相对路径的话，文件会落到 scrcpy 的工作目录（也就是引擎目录）里。
        // 用户手输了一个不以 / 开头的目录时，宁可用默认的影片目录。
        if !directory.hasPrefix("/") {
            directory = ("~/Movies" as NSString).expandingTildeInPath
        }

        let file: String
        if let name, !name.isEmpty {
            file = name
        } else {
            // 开关开着却没给名字：给一个带时间戳的默认名，
            // 总好过「用户按了录制，结果什么都没录」。
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            file = "scrcpy-\(formatter.string(from: Date())).mp4"
        }

        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(file)
    }

    /// 按空格切分额外参数，支持用引号把带空格的一段括起来。
    /// 空串不产生任何 token。
    static func splitArguments(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for character in raw {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
