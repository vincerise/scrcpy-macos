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
    ///
    /// 镜像窗口在**别的应用**（`Mirror.app`）名下，所以程序坞右键那份系统窗口列表里
    /// 永远不会有它们；点图标走这条回调是唯一的系统级入口，必须把窗口真的带上来。
    /// 具体怎么绕过 macOS 14 的协作式激活见 `MirrorWindows`。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController?.showWindow(nil)
        MirrorWindows.reveal(pids: model?.childPIDs ?? [])
        return true
    }

    /// 程序坞右键菜单。
    ///
    /// 系统默认那份「显示所有窗口」列的是**本 App 自己**的窗口，而镜像窗口属于
    /// `Mirror.app`，永远不会出现在里面 —— 用户右键找不到投屏窗口，不是设置问题，
    /// 是那份列表的定义如此。既然系统不会列，就自己列。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let mirrors = model?.runningMirrors ?? []
        guard !mirrors.isEmpty else { return nil }

        let menu = NSMenu()
        for mirror in mirrors {
            let item = NSMenuItem(title: "显示 \(mirror.name) 的投屏窗口",
                                  action: #selector(showMirrorFromDock(_:)),
                                  keyEquivalent: "")
            item.target = self
            // 用 serial 而不是下标：菜单弹出到用户点中之间，设备可能已经掉了。
            item.representedObject = mirror.serial
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "全部停止投屏", action: #selector(stopAllFromDock), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        return menu
    }

    @objc private func showMirrorFromDock(_ sender: NSMenuItem) {
        guard let serial = sender.representedObject as? String else { return }
        model?.bringMirrorToFront(serial: serial)
    }

    @objc private func stopAllFromDock() {
        model?.stopAll()
    }

    /// 退出前必须等 scrcpy 收 SIGTERM 自己退 —— 它要删掉设备上的
    /// `scrcpy-server.jar`、恢复息屏与保持唤醒状态。直接退出会把这些留在手机上。
    /// 多设备时每一路都要等，且是并行等（超时兜底在 `stopForTermination` 里）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.anySessionActive else {
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
        // 菜单入口同时查 App 本体和引擎；两行各自报告结果。
        model?.checkAllUpdates()
    }
}
