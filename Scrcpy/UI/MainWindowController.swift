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
        window.title = "Scrcpy"
        window.minSize = NSSize(width: 560, height: 620)
        // 纯代码建窗必踩的坑：不设这个，关窗之后窗口就被释放了，
        // 再 `showWindow` 就是对野指针发消息。
        window.isReleasedWhenClosed = false
        // 记住用户拉过的位置与大小。首次启动没有存档，退回居中。
        if !window.setFrameUsingName("ScrcpyMainWindow") {
            window.center()
        }
        _ = window.setFrameAutosaveName("ScrcpyMainWindow")

        self.init(window: window)
        window.contentView = NSHostingView(rootView: MainView(model: model))
    }
}
