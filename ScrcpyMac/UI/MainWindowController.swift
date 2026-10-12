//  MainWindowController.swift
//  Scrcpy
//

import AppKit
import SwiftUI

/// 主窗口。内容全部是 SwiftUI，这里只负责把窗口本身配好。
@MainActor
final class MainWindowController: NSWindowController {

    /// 窗口位置与大小的存档名。存在 UserDefaults 的 `NSWindow Frame <这个名字>` 键下。
    private static let frameAutosaveName = "ScrcpyMacMainWindow"

    convenience init(model: AppModel) {
        // 首次启动（还没有存档）时的尺寸。560 是这套卡片布局排得下的下限宽度，
        // 901 是实际用起来顺手的高度。这两个数只影响第一次启动 —— 之后一律
        // 以上次关窗时的大小和位置为准，用户拉过就再也不会回到这里。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 901),
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

        self.init(window: window)

        // 记住用户拉过的位置与大小。
        //
        // 名字必须在 window 和 controller **两边**都设。只设 window 上那一份是没用的：
        // `showWindow` 会把 controller 的 `windowFrameAutosaveName`（默认空串）盖到窗口上，
        // 正好把这里设的名字清掉 —— 于是从来没有存档，`setFrameUsingName` 永远返回 false，
        // 每次启动都退回居中 + 默认尺寸。这个 bug 的表现就是「拉大了下次开又变回去」。
        windowFrameAutosaveName = Self.frameAutosaveName
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)

        window.contentView = NSHostingView(rootView: MainView(model: model))
    }
}
