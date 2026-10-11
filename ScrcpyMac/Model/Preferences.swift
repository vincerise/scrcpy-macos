//  Preferences.swift
//  Scrcpy
//

import Foundation

/// 用户偏好，全部落在 `UserDefaults` 里。
///
/// 刻意不做 `ObservableObject`：SwiftUI 的 `@Published` 需要一层镜像属性，
/// UI 那边已经各自持有一份（见 `AppModel`），这里就只负责存取和拼参数。
final class Preferences {

    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let maxSize = "scrcpy.maxSize"
        static let videoBitRate = "scrcpy.videoBitRate"
        static let maxFPS = "scrcpy.maxFPS"
        static let audioEnabled = "scrcpy.audioEnabled"
        static let turnScreenOff = "scrcpy.turnScreenOff"
        static let stayAwake = "scrcpy.stayAwake"
        static let alwaysOnTop = "scrcpy.alwaysOnTop"
        static let recordingEnabled = "scrcpy.recordingEnabled"
        static let recordingPath = "scrcpy.recordingPath"
        static let extraArguments = "scrcpy.extraArguments"
        static let lastDeviceSerial = "scrcpy.lastDeviceSerial"
        static let adbPathOverride = "scrcpy.adbPathOverride"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 注册默认值而不是在每个 getter 里写兜底：`integer(forKey:)` 对不存在的键
        // 返回 0，而 0 在我们的语义里是「原始分辨率」这个合法取值，两者分不开。
        defaults.register(defaults: [
            Key.maxSize: 0,
            Key.videoBitRate: "8M",
            Key.maxFPS: 0,
            Key.audioEnabled: true,
            Key.turnScreenOff: false,
            Key.stayAwake: false,
            Key.alwaysOnTop: false,
            Key.recordingEnabled: false,
            Key.recordingPath: "~/Movies",
            Key.extraArguments: "",
        ])
    }

    // MARK: - 视频

    /// 0 = 原始分辨率。
    var maxSize: Int {
        get { defaults.integer(forKey: Key.maxSize) }
        set { defaults.set(newValue, forKey: Key.maxSize) }
    }

    var videoBitRate: String {
        get { defaults.string(forKey: Key.videoBitRate) ?? "8M" }
        set { defaults.set(newValue, forKey: Key.videoBitRate) }
    }

    /// 0 = 不限制。
    var maxFPS: Int {
        get { defaults.integer(forKey: Key.maxFPS) }
        set { defaults.set(newValue, forKey: Key.maxFPS) }
    }

    // MARK: - 行为

    var audioEnabled: Bool {
        get { defaults.bool(forKey: Key.audioEnabled) }
        set { defaults.set(newValue, forKey: Key.audioEnabled) }
    }

    var turnScreenOff: Bool {
        get { defaults.bool(forKey: Key.turnScreenOff) }
        set { defaults.set(newValue, forKey: Key.turnScreenOff) }
    }

    var stayAwake: Bool {
        get { defaults.bool(forKey: Key.stayAwake) }
        set { defaults.set(newValue, forKey: Key.stayAwake) }
    }

    var alwaysOnTop: Bool {
        get { defaults.bool(forKey: Key.alwaysOnTop) }
        set { defaults.set(newValue, forKey: Key.alwaysOnTop) }
    }

    // MARK: - 录制

    var recordingEnabled: Bool {
        get { defaults.bool(forKey: Key.recordingEnabled) }
        set { defaults.set(newValue, forKey: Key.recordingEnabled) }
    }

    /// 存的是原始串（可能是 `~/Movies`），展开推迟到拼参数时做 ——
    /// 提前展开会把用户的家目录写进 UserDefaults，换用户或迁移备份后就是错的。
    var recordingPath: String {
        get { defaults.string(forKey: Key.recordingPath) ?? "~/Movies" }
        set { defaults.set(newValue, forKey: Key.recordingPath) }
    }

    // MARK: - 其它

    var extraArguments: String {
        get { defaults.string(forKey: Key.extraArguments) ?? "" }
        set { defaults.set(newValue, forKey: Key.extraArguments) }
    }

    /// 上次选中的设备。没选过是 nil，不要写成空串 ——
    /// 空串会变成一个合法的「serial」，启动时拿去找设备只会扑空。
    var lastDeviceSerial: String? {
        get { defaults.string(forKey: Key.lastDeviceSerial) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.lastDeviceSerial)
            } else {
                defaults.removeObject(forKey: Key.lastDeviceSerial)
            }
        }
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

    /// 组装 scrcpy 的命令行参数（不含可执行文件路径）。
    ///
    /// 顺序：设备 → 视频 → 音频 → 行为 → 录制 → 额外 → 固定项。
    /// 额外参数里出现的同名选项以用户的为准，我们算出来的那一份直接丢掉。
    func buildArguments(device: AdbDevice?, recordingFileName: String?) -> [String] {
        var defaults: [String] = []

        // 设备。多设备连着的时候必须显式指定，否则 scrcpy 会直接报错退出。
        if let serial = device?.serial, !serial.isEmpty {
            defaults.append("--serial=\(serial)")
        }

        // 视频
        if maxSize > 0 {
            defaults.append("--max-size=\(maxSize)")
        }
        if !videoBitRate.isEmpty {
            // 用 --video-bit-rate：--bit-rate 是废弃别名，5.0 的 --help 里已经只剩前者。
            defaults.append("--video-bit-rate=\(videoBitRate)")
        }
        if maxFPS > 0 {
            defaults.append("--max-fps=\(maxFPS)")
        }

        // 音频。默认就是开的，所以只有关的时候需要显式说一句 ——
        // scrcpy 没有独立的 --audio 选项，开了反而会报未知参数。
        if !audioEnabled {
            defaults.append("--no-audio")
        }

        // 行为
        if turnScreenOff {
            defaults.append("--turn-screen-off")
        }
        if stayAwake {
            defaults.append("--stay-awake")
        }
        if alwaysOnTop {
            defaults.append("--always-on-top")
        }

        // 录制
        if recordingEnabled {
            defaults.append("--record=\(recordingURL(named: recordingFileName).path)")
        }

        // 固定项。这两条不是偏好，是「让 scrcpy 在 App 里能正常跑」的必要条件：
        // 前者杜绝退出时等 stdin 卡死，后者不让它去改终端标题（我们没有终端）。
        let pinned = ["--pause-on-exit=false", "--no-terminal-title"]

        let extra = Preferences.splitArguments(extraArguments)

        // 用户参数优先。同一个选项出现两次时 scrcpy 的 getopt 取最后一个，
        // 结果是「实际生效的是哪个」变得取决于我们的拼接顺序 —— 那太脆了，
        // 不如在这里就保证不重复。
        var overridden = Set<String>()
        for token in extra where token.hasPrefix("--") {
            overridden.insert(Preferences.optionName(of: token))
        }

        let configurable = defaults.filter { !overridden.contains(Preferences.optionName(of: $0)) }
        let forced = pinned.filter { !overridden.contains(Preferences.optionName(of: $0)) }

        return configurable + extra + forced
    }

    /// 取 `--xxx=yyy` 里的 `--xxx`。短选项（`-m`）不参与去重 ——
    /// 我们生成的默认值全是长选项形态，用户写短选项时本就是有意绕开。
    private static func optionName(of token: String) -> String {
        String(token.prefix { $0 != "=" })
    }

    /// 录制文件的绝对路径。
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
