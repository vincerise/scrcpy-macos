//  MainMenu.swift
//  Scrcpy
//

import AppKit

/// 手工搭主菜单。
///
/// 纯代码建窗**必须**自己建 `NSApp.mainMenu` —— 没有 XIB 就没有菜单，
/// 连 ⌘Q 都不会有。第一项必须是 App 菜单，标题用 `CFBundleName`，
/// 否则 macOS 会拿进程名当标题（显示成 `Scrcpy` 还算对，但不该赌）。
enum MainMenu {

    static func build() -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Scrcpy"
        let main = NSMenu()
        main.addItem(appMenuItem(appName: appName))
        main.addItem(editMenuItem())
        main.addItem(windowMenuItem())
        return main
    }

    // MARK: - App 菜单

    private static func appMenuItem(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)
        item.submenu = menu

        menu.addItem(withTitle: "关于 \(appName)",
                     action: #selector(AppDelegate.showAbout(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let checkItem = menu.addItem(withTitle: "检查更新…",
                                     action: #selector(AppDelegate.checkForUpdates(_:)),
                                     keyEquivalent: "u")
        checkItem.target = nil   // 走响应链，最终落到 AppDelegate

        menu.addItem(.separator())
        menu.addItem(withTitle: "隐藏 \(appName)",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")

        let hideOthers = menu.addItem(withTitle: "隐藏其他",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "显示全部",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "退出 \(appName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return item
    }

    // MARK: - 编辑菜单

    /// 日志区开了 `.textSelection(.enabled)`，没有编辑菜单就按不出 ⌘C。
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        item.submenu = menu

        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return item
    }

    // MARK: - 窗口菜单

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        item.submenu = menu

        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 交给 AppKit 维护「窗口列表」那一段，多窗口时才不会缺东西。
        NSApp.windowsMenu = menu
        return item
    }
}
