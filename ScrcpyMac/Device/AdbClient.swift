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

    /// 连接方式，只用来显示。
    ///
    /// 不能只按 `isWireless` 二分成「USB / Wi-Fi」：模拟器的 serial 是 `emulator-5554`，
    /// 既没有 `:` 也不是真机序列号，会被标成「USB」。
    enum ConnectionKind: String {
        case usb = "USB"
        case wireless = "Wi-Fi"
        case emulator = "模拟器"
    }

    var connectionKind: ConnectionKind {
        if serial.hasPrefix("emulator-") { return .emulator }
        return isWireless ? .wireless : .usb
    }

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
