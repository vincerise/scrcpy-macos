//  AppInstaller.swift
//  ScrcpyMac
//

import AppKit
import Darwin
import Foundation

enum AppInstallError: LocalizedError {
    case precondition(String)
    case copyFailed(String)
    case atomicSwapUnsupported(String)
    case permissionDenied(String)
    case swapFailed(String)
    case missingHelper
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .precondition(let reason):
            return reason
        case .copyFailed(let detail):
            return detail.isEmpty ? "无法准备新版本。" : "无法准备新版本：\(detail)"
        case .atomicSwapUnsupported(let detail):
            return "当前文件系统不支持原子替换（\(detail)）。请手动下载新版本替换。"
        case .permissionDenied(let detail):
            return detail
        case .swapFailed(let detail):
            return detail.isEmpty ? "替换 App 失败。" : detail
        case .missingHelper:
            return "App 内缺少更新助手脚本，无法完成自更新。"
        case .helperFailed(let detail):
            return detail.isEmpty ? "无法启动更新助手。" : "无法启动更新助手：\(detail)"
        }
    }
}

/// 一次更新启动后的结果，交给 AppModel 显示。
enum AppLaunchResult {
    case updated(String)
    case failed(String)
}

/// 原地替换 App 本体。
///
/// 设计上刻意把「换 bundle」留在**当前进程**里做：macOS 13+ 的 App Management
/// 对「另一个进程修改 App bundle」更敏感，而 App 修改自己通常不需要授权。
/// 换完之后才启动 helper，它只负责等本进程退出、重新打开、失败时回滚。
enum AppInstaller {

    private static let pendingFile = AppPaths.updateDir.appendingPathComponent("pending.json")
    private static let ackFile = AppPaths.updateDir.appendingPathComponent("ack")
    private static let resultFile = AppPaths.updateDir.appendingPathComponent("result")

    /// 当前环境能不能自更新。nil 表示可以；否则是给用户看的原因。
    static func installBlocker() -> String? {
        let target = AppInfo.bundleURL
        guard target.pathExtension == "app" else {
            return "当前不是从 .app 启动，无法自更新。"
        }
        if target.path.contains("/AppTranslocation/") {
            return "App 正在临时只读位置运行。先把 ScrcpyMac.app 拖进「应用程序」再更新。"
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "找不到当前 App 的位置，无法自更新。"
        }

        if let values = try? target.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey]) {
            if values.volumeIsReadOnly == true {
                return "App 所在磁盘是只读的，无法原地更新。"
            }
            if values.volumeIsLocal == false {
                return "App 在非本地磁盘上，无法安全更新。"
            }
        }

        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            return "没有写入 \(parent.path) 的权限。把 App 放进「应用程序」后再试。"
        }

        // 两个实例同时更新会互相换掉对方，直接拒绝。
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            return "另一个 ScrcpyMac 正在运行，先退出它再更新。"
        }
        return nil
    }

    /// 把暂存的 App 换到当前 bundle 的位置，并启动等待重启的 helper。
    ///
    /// 返回时本进程仍然运行在旧 inode 上；调用方随后应调用 `NSApp.terminate`。
    static func install(stagedApp: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        let target = AppInfo.bundleURL

        if let blocker = installBlocker() {
            throw AppInstallError.precondition(blocker)
        }
        guard fm.fileExists(atPath: stagedApp.path) else {
            throw AppInstallError.copyFailed("暂存的新版本不见了，请重新下载。")
        }

        // helper 必须在交换**之前**从当前 bundle 复制出来：交换之后
        // `Bundle.main` 的路径已经指向新 App，而新版本（尤其是刚引入这套机制的
        // 旧版本）不一定带这个资源。
        let helper = try prepareHelper()

        let prepared = target.deletingLastPathComponent()
            .appendingPathComponent(".scrcpymac-update-\(UUID().uuidString)")
        var swapped = false
        var spawned = false

        do {
            try? fm.removeItem(at: prepared)
            // 同一卷上的副本才能参与 rename 交换。ditto 保留签名和扩展属性。
            let copy = Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                 [stagedApp.path, prepared.path],
                                 timeout: 120)
            guard copy.ok, fm.fileExists(atPath: prepared.path) else {
                throw AppInstallError.copyFailed(copy.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            try AppUpdateChecker.verifyBundle(at: prepared, expectedVersion: expectedVersion)
            try swap(target, prepared)
            swapped = true

            // 交换后直接从 Info.plist 读版本，不用 Bundle(url:)：
            // Foundation 可能按路径缓存旧的 Bundle 对象，读出来会是交换前的版本。
            guard readVersion(at: target) == expectedVersion else {
                throw AppInstallError.swapFailed("替换后目标路径上的版本号不正确。")
            }

            let process = try runHelper(helper,
                                        target: target,
                                        displaced: prepared,
                                        version: expectedVersion)
            spawned = true
            writePending(PendingUpdate(target: target.path,
                                       displaced: prepared.path,
                                       version: expectedVersion,
                                       helperPID: process.processIdentifier))
        } catch {
            if !spawned {
                if swapped { try? swap(target, prepared) }
                try? fm.removeItem(at: prepared)
            }
            throw error
        }
    }

    // MARK: - 启动时的收尾

    /// 新版本启动时调用一次：给 helper 发成功信号，或读出上次失败的原因。
    static func acknowledgeLaunchIfNeeded() -> AppLaunchResult? {
        let fm = FileManager.default
        var result: AppLaunchResult?

        if let data = try? Data(contentsOf: resultFile),
           let text = String(data: data, encoding: .utf8) {
            try? fm.removeItem(at: resultFile)
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { result = .failed(message) }
        }

        if let data = try? Data(contentsOf: pendingFile),
           let pending = try? JSONDecoder().decode(PendingUpdate.self, from: data) {
            if pending.version == AppInfo.version, pending.target == AppInfo.bundleURL.path {
                // 这一次启动的就是新版本：写 ack，helper 看到后清理旧包。
                try? Data(pending.version.utf8).write(to: ackFile, options: .atomic)
                // helper 还活着时不要替它删：它可能刚好走到「确认超时 → 回滚」
                // 的分支，旧包突然消失会让它把刚起来的新版本也挪走。
                if !processAlive(pending.helperPID) {
                    try? fm.removeItem(at: URL(fileURLWithPath: pending.displaced))
                }
                try? fm.removeItem(at: pendingFile)
                if result == nil { result = .updated(pending.version) }
            } else if !processAlive(pending.helperPID) {
                // 不是预期的版本（回滚后旧版本启动）：清掉换下来的新包。
                // helper 还活着时不能动——它可能正要拿这份做回滚。
                try? fm.removeItem(at: URL(fileURLWithPath: pending.displaced))
                try? fm.removeItem(at: pendingFile)
            }
        }

        cleanupStaleFiles()
        return result
    }

    // MARK: - 交换

    /// `sys/stdio.h`: #define RENAME_SWAP 0x00000002
    private static let renameSwapFlag: UInt32 = 0x2

    /// 原子交换两个路径。交换后 `a` 上是 `b` 原来的内容，反之亦然。
    ///
    /// 不用「先挪开再挪进来」：两次 rename 之间崩溃会在目标路径上留下空档，
    /// 而 App 的启动路径不能有空档。非 APFS 等不支持交换的文件系统直接报错，
    /// 让用户手动替换，比冒这个险好。
    private static func swap(_ a: URL, _ b: URL) throws {
        let ok = a.withUnsafeFileSystemRepresentation { rawA -> Bool in
            b.withUnsafeFileSystemRepresentation { rawB -> Bool in
                guard let rawA, let rawB else { return false }
                return renamex_np(rawA, rawB, renameSwapFlag) == 0
            }
        }
        guard ok else {
            let code = errno
            let reason = String(cString: strerror(code))
            if code == EPERM || code == EACCES {
                throw AppInstallError.permissionDenied(
                    "macOS 拒绝了替换 App 的请求（\(reason)）。请到「系统设置 → 隐私与安全性 → App 管理」允许 ScrcpyMac 后重试。"
                )
            }
            if code == ENOTSUP || code == EINVAL {
                throw AppInstallError.atomicSwapUnsupported(reason)
            }
            throw AppInstallError.swapFailed("替换 App 失败：\(reason)。")
        }
    }

    private static func readVersion(at app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    // MARK: - Helper

    private static func prepareHelper() throws -> URL {
        guard let resource = Bundle.main.url(forResource: "app-update-helper", withExtension: "sh") else {
            throw AppInstallError.missingHelper
        }
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.updateDir, withIntermediateDirectories: true)
        let helper = AppPaths.updateDir.appendingPathComponent("helper-\(UUID().uuidString).sh")
        try? fm.removeItem(at: helper)
        do {
            try fm.copyItem(at: resource, to: helper)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        } catch {
            throw AppInstallError.helperFailed(error.localizedDescription)
        }
        return helper
    }

    private static func runHelper(_ helper: URL,
                                  target: URL,
                                  displaced: URL,
                                  version: String) throws -> Process {
        try? FileManager.default.removeItem(at: ackFile)
        try? FileManager.default.removeItem(at: resultFile)

        let log = AppPaths.updateDir.appendingPathComponent("update.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [
            "/bin/bash", helper.path,
            target.path, displaced.path,
            String(getpid()), version,
            ackFile.path, resultFile.path, log.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppInstallError.helperFailed(error.localizedDescription)
        }
        return process
    }

    // MARK: - 状态文件

    private struct PendingUpdate: Codable {
        let target: String
        let displaced: String
        let version: String
        let helperPID: Int32
    }

    /// 写不进去也不算失败：helper 不依赖这个文件，它只用于下一次启动时
    /// 写 ack 和清理旧包；helper 自己的进程检测会兜住重启。
    private static func writePending(_ pending: PendingUpdate) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: pendingFile, options: .atomic)
    }

    private static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM 说明进程存在，只是我们没权限给它发信号。
        return errno == EPERM
    }

    private static func cleanupStaleFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)

        if let entries = try? fm.contentsOfDirectory(at: AppPaths.updateDir,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: []) {
            for url in entries where url.lastPathComponent.hasPrefix("helper-") {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                try? fm.removeItem(at: url)
            }
        }

        // helper 在写 pending 之前就死了的话，换下来的旧包会一直藏在
        // App 旁边。它带固定前缀，一小时前的只可能是残留。
        let parent = AppInfo.bundleURL.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(at: parent,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: []) {
            for url in entries where url.lastPathComponent.hasPrefix(".scrcpymac-update-") {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                try? fm.removeItem(at: url)
            }
        }
    }
}
