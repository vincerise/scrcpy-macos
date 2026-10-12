//  AdbClient.swift
//  Scrcpy
//

import Foundation

struct AdbDevice: Identifiable, Equatable {
    let serial: String
    /// adb 报的原始状态：device / unauthorized / offline / bootloader …
    let state: String
    /// 已把下划线换成空格。adb 用下划线编码名字里的空格，直接显示会看到 `moto_g_play`。
    let model: String?
    let product: String?

    var id: String { serial }

    var isReady: Bool { state == "device" }
    /// TCP/IP 连上的设备 serial 形如 `192.168.1.5:5555`，USB 的是一串序列号。
    var isWireless: Bool { serial.contains(":") }

    /// 连接方式，只用来显示。TCP/IP 连上的设备 serial 形如 `192.168.1.5:5555`，
    /// USB 的是一串序列号。
    var connectionLabel: String { isWireless ? "Wi-Fi" : "USB" }

    var displayName: String {
        if let model, !model.isEmpty { return model }
        return serial
    }

    var statusText: String {
        switch state {
        case "device":
            return "已连接"
        case "unauthorized":
            // 这个状态最常见的成因是手机上那个「允许 USB 调试」的弹窗没点。
            // 直接写出来，比只显示一个 unauthorized 有用得多。
            return "未授权（请在手机上允许 USB 调试）"
        case "offline":
            return "离线（请重新插拔）"
        default:
            return state
        }
    }
}

enum AdbParse {
    /// 解析 `adb devices -l` 的输出。
    static func devices(from output: String) -> [AdbDevice] {
        var result: [AdbDevice] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 首行固定是 "List of devices attached"。
            if line.hasPrefix("List of devices") { continue }

            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // 只认「至少两列」的行。adb 偶尔会把 `* daemon not running; starting now at tcp:5037`
            // 这类提示混在同一个输出流里，它们的第一列以 `*` 开头且没有第二列状态。
            guard tokens.count >= 2 else { continue }

            // 模拟器不列进来：它本来就跑在这台电脑上，再开一路 scrcpy 只是把眼前的画面
            // 又投一遍。留着它还会占掉「全部投屏」的一个名额。判据是 adb 给模拟器的
            // serial 固定以 `emulator-` 开头。
            if tokens[0].hasPrefix("emulator-") { continue }

            var model: String?
            var product: String?
            for token in tokens.dropFirst(2) {
                guard let colon = token.firstIndex(of: ":") else { continue }
                let key = String(token[token.startIndex..<colon])
                let value = String(token[token.index(after: colon)...])
                switch key {
                case "model": model = value.replacingOccurrences(of: "_", with: " ")
                case "product": product = value.replacingOccurrences(of: "_", with: " ")
                default: break
                }
            }

            result.append(AdbDevice(serial: tokens[0],
                                    state: tokens[1],
                                    model: model,
                                    product: product))
        }
        return result
    }
}

/// 从 `media_codecs*.xml` 里挑出视频编码器自报的码率上限。
///
/// 单独拆出来是因为这里有**挑选**，而挑选错了不会报错、只会给出一个达不到的数：
/// 同一个 mime 在文件里往往有好几个条目。这台 moto 上 `c2.qti.avc.encoder`（Android 14
/// 真正会用的那个）写 60 Mbps，而它的遗留别名 `OMX.qcom.video.encoder.avc` 写 100 ——
/// 后者是按老 OMX 接口报的，Codec2 实现并不兑现。所以规则跟 Android 自己一致：
/// 有 `c2.` 条目就只在 `c2.` 里挑，软编（`android` / `google` / `slow-cpu`）、
/// `secure`、`.cq` 三种变体不算 —— 它们要么性能差一个量级，要么尺寸受限，
/// 都不是 scrcpy 会拿到的那一个。
enum MediaCodecXML {

    /// - Parameter codec: scrcpy 的 `--video-codec` 取值里的编码器名（默认 `avc`）。
    static func bitrateCeiling(inXML text: String, codec: String = "avc") -> Int? {
        let wanted = "video/\(codec)"
        var hardware: [Int] = []
        var other: [Int] = []

        for block in blocks(in: text) {
            guard block.type == wanted else { continue }
            guard let ceiling = bitrateCeiling(inBlock: block.body) else { continue }
            let name = block.name
            let isFallback = ["android", "google", "slow-cpu", "secure", ".cq"].contains {
                name.contains($0)
            }
            guard !isFallback else { continue }
            if name.hasPrefix("c2.") { hardware.append(ceiling) } else { other.append(ceiling) }
        }

        // 硬件实现存在时以它为准；只有遗留条目时才退回它们中间最大的那个。
        return hardware.max() ?? other.max()
    }

    private struct Block {
        let name: String
        let type: String
        let body: String
    }

    /// 按 `<MediaCodec name="…" type="…">` … `</MediaCodec>` 切块。
    /// 不用 `XMLParser`：这些是厂商拼出来的文件，未必严格合法，而这里只要两三个字段。
    private static func blocks(in text: String) -> [Block] {
        var result: [Block] = []
        var rest = Substring(text)

        while let open = rest.range(of: "<MediaCodec ") {
            guard let close = rest.range(of: "</MediaCodec>", range: open.upperBound..<rest.endIndex)
            else { break }
            let header = rest[open.upperBound..<close.lowerBound]
            let body = String(header)
            if let name = attribute("name", in: header), let type = attribute("type", in: header) {
                result.append(Block(name: name, type: type, body: body))
            }
            rest = rest[close.upperBound...]
        }
        return result
    }

    private static func attribute(_ key: String, in header: Substring) -> String? {
        guard let start = header.range(of: "\(key)=\"") else { return nil }
        let value = header[start.upperBound...]
        guard let end = value.firstIndex(of: "\"") else { return nil }
        return String(value[value.startIndex..<end])
    }

    /// `<Limit name="bitrate" range="1-60000000" />` 里那个上限。
    private static func bitrateCeiling(inBlock body: String) -> Int? {
        guard let limit = body.range(of: "name=\"bitrate\"") else { return nil }
        let tail = body[limit.upperBound...]
        guard let range = tail.range(of: "range=\""),
              let dash = tail.range(of: "-", range: range.upperBound..<tail.endIndex),
              let end = tail.range(of: "\"", range: dash.upperBound..<tail.endIndex)
        else { return nil }
        return Int(tail[dash.upperBound..<end.lowerBound])
    }
}

/// `@unchecked Sendable` 的依据：这个类**不是**线程安全的，但它也不被共享 ——
/// 调用方（`AppModel`）每次都新建一个实例丢给一个后台队列用完即弃，
/// 没有两个线程会碰同一个实例。加这个标注只是为了让它能进 `@Sendable` 闭包。
/// 以后若要复用实例，得先把 `adbPath` 的读写保护起来。
final class AdbClient: @unchecked Sendable {

    var adbPath: URL

    init(adbPath: URL) {
        self.adbPath = adbPath
    }

    /// 当前连接的设备列表。adb 跑失败时返回空列表而不是抛错 ——
    /// 调用方（设备轮询）对「一次没查出来」的处理就是等下一次，抛错没有额外信息量。
    func devices(timeout: TimeInterval = 8) -> [AdbDevice] {
        let result = Shell.run(adbPath, ["devices", "-l"], timeout: timeout)
        guard result.ok else { return [] }
        return AdbParse.devices(from: result.output)
    }

    func connect(_ hostPort: String, timeout: TimeInterval = 12) -> ShellResult {
        Shell.run(adbPath, ["connect", hostPort], timeout: timeout)
    }

    func disconnect(_ hostPort: String) -> ShellResult {
        Shell.run(adbPath, ["disconnect", hostPort], timeout: 8)
    }

    /// 让设备上的 adbd 切到 TCP 监听。
    ///
    /// 注意这里**不**传任何 `--kill-adb-on-close`、也从不 `adb kill-server`：
    /// 本机通常还有 Android Studio 的 adb server 在跑，杀掉会连带把它的设备连接打断。
    func enableTcpip(serial: String, port: Int = 5555) -> ShellResult {
        Shell.run(adbPath, ["-s", serial, "tcpip", "\(port)"], timeout: 12)
    }

    /// 从 `adb shell ip route` 里取 `src` 后面的那个 IP，也就是设备在 Wi-Fi 上的地址。
    func deviceIP(serial: String) -> String? {
        let result = Shell.run(adbPath, ["-s", serial, "shell", "ip", "route"], timeout: 8)
        guard result.ok else { return nil }

        for line in result.output.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let index = tokens.firstIndex(of: "src"), index + 1 < tokens.count else { continue }
            let candidate = tokens[index + 1]
            // 只收形似 IPv4 的东西：`ip route` 的某些行（比如默认路由）里
            // src 后面跟的可能是别的字段，收错了会拿去拼一个连不上的地址。
            let fields = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isNumber }) }) else { continue }
            return candidate
        }
        return nil
    }

    /// 把设备屏幕按灭。
    ///
    /// 用 `KEYCODE_SLEEP`(223) 而不是 `KEYCODE_POWER`(26)：后者是**开关**，
    /// 屏幕本来就灭着时再按一下会把它点亮 —— 而这里要的是「结果一定是灭的」。
    func sleepScreen(serial: String, timeout: TimeInterval = 8) {
        _ = Shell.run(adbPath, ["-s", serial, "shell", "input", "keyevent", "223"], timeout: timeout)
    }

    /// 设备上视频编码器自报的码率上限（bits/s）。读不出来返回 nil。
    ///
    /// 只能从 `media_codecs*.xml` 里读：Android 没有能从 adb 直接问的接口
    /// （`dumpsys media.codec` 在 Android 14 上已经没有这个服务）。
    /// `/vendor` 是厂商自己那份（通常更全），`/system` 是 AOSP 的兜底，两个都读、合起来挑。
    ///
    /// 结尾的 `2>/dev/null; true` 不是为了好看：两个通配符里只要有一个不匹配
    /// （很多机型没有 `/system` 那份，这台 moto 就没有），`cat` 会带着非零状态退出，
    /// 于是「读到了一半」和「什么都没读到」就分不开了 —— 而这里要的正是前者。
    func encoderBitrateCeiling(serial: String, codec: String = "avc", timeout: TimeInterval = 8) -> Int? {
        let result = Shell.run(adbPath,
                               ["-s", serial, "shell",
                                "cat /vendor/etc/media_codecs*.xml /system/etc/media_codecs*.xml 2>/dev/null; true"],
                               timeout: timeout)
        // 不看退出码：真失败时输出里不会有 `<MediaCodec`，解析自然给 nil。
        return MediaCodecXML.bitrateCeiling(inXML: result.output, codec: codec)
    }

    /// 预热：后台跑一次 `adb start-server`。
    ///
    /// 目的是把 adb daemon 的启动成本挪到用户看见设备列表之前 ——
    /// 冷启动一次 adb server 要好几秒，直接体现在「点开 App 半天没有设备」上。
    /// 这个命令是幂等的，server 已经在跑时它只是握个手就返回。
    func warmUp() {
        let adb = adbPath
        DispatchQueue.global(qos: .utility).async {
            _ = Shell.run(adb, ["start-server"], timeout: 20)
        }
    }
}
