//  AppDelegate.swift
//  Scrcpy
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel?
    private var mainWindowController: MainWindowController?

    // MARK: - 启动与退出

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let model = AppModel()
        self.model = model

        let controller = MainWindowController(model: model)
        mainWindowController = controller
        controller.showWindow(nil)

        model.start()
        NSApp.activate()
    }

    /// 关掉最后一个窗口就退出 App。镜像窗口是**另一个进程**的窗口，
    /// 关它不影响我们；关掉这个控制面板才是「我不用了」。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 不实现这个方法的话，macOS 14 起每次启动都会打一条警告。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 点程序坞图标时：把控制面板拉回来，顺手把正在跑的镜像窗口也拉到前台
    /// —— 它们是两个进程、两个 Dock 图标，用户分不清哪个是哪个。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController?.showWindow(nil)
        if let pid = model?.childPID, let child = NSRunningApplication(processIdentifier: pid) {
            child.activate()
        }
        return true
    }

    /// 退出前必须等 scrcpy 收 SIGTERM 自己退 —— 它要删掉设备上的
    /// `scrcpy-server.jar`、恢复息屏与保持唤醒状态。直接退出会把这些留在手机上。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRunning else {
            model?.shutdown()
            return .terminateNow
        }
        model.stopForTermination {
            model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - 菜单动作

    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let engine = model?.engine.map { "scrcpy \($0.version)" } ?? "引擎未安装"

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ScrcpyMac",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: """
                非官方封装。\(engine)

                镜像引擎 scrcpy 由 rom1v 开发，以 GPLv3 授权，
                由本 App 在运行时从官方 releases 下载，不随本 App 分发。
                """,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ])
        NSApp.activate()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        model?.checkForUpdates()
    }
}
