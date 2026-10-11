//  MainWindowController.swift
//  Scrcpy
//

import AppKit
import SwiftUI

/// 主窗口。内容全部是 SwiftUI，这里只负责把窗口本身配好。
@MainActor
final class MainWindowController: NSWindowController {

    convenience init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScrcpyMac"
        window.minSize = NSSize(width: 560, height: 620)
        // 标题只出现一次。默认的标题栏会在顶部居中再写一遍应用名，
        // 而页面里已经有一个 18pt 的标题了 —— 同一个名字上下各一遍，纯属噪音。
        // 做法是让内容铺到标题栏底下、把标题栏文字藏掉：
        // 红黄绿灯浮在内容左上角，标题就只剩页面里那一个。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // 纯代码建窗必踩的坑：不设这个，关窗之后窗口就被释放了，
        // 再 `showWindow` 就是对野指针发消息。
        window.isReleasedWhenClosed = false
        // 记住用户拉过的位置与大小。首次启动没有存档，退回居中。
        if !window.setFrameUsingName("ScrcpyMacMainWindow") {
            window.center()
        }
        _ = window.setFrameAutosaveName("ScrcpyMacMainWindow")

        self.init(window: window)
        window.contentView = NSHostingView(rootView: MainView(model: model))
    }
}
