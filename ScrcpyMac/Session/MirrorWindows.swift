//  MirrorWindows.swift
//  Scrcpy
//

import AppKit

/// 唤起镜像窗口。
///
/// 镜像窗口属于 scrcpy 子进程（`Mirror.app`，一个带 `LSUIElement` 的 UIElement 应用），
/// **不是本 App 的窗口**。这一点带来三个绕不开的后果：
///
/// - 不能用 `makeKeyAndOrderFront` 直接把它拎出来，只能激活那个进程，
///   让系统把它的窗口带到前面；
/// - 它永远不会出现在程序坞右键的那份系统窗口列表里 —— 那份列表只列**当前 App 自己**的窗口。
///   所以「右键找不到镜像窗口」不是 bug，是系统定义；要找只能由 App 自己往程序坞菜单里加
///   （见 `AppDelegate.applicationDockMenu`）；
/// - **它永远抬不到控制面板之上。** 点程序坞图标是「用户要激活这个 App」，
///   系统会把激活权按在我们身上：实测 `yieldActivation(to:)` 与 `deactivate()`
///   都只能维持几百毫秒，之后 `isActive` 又回到 true，面板重新压在最上面。
///   这是协作式激活的既定行为，正面顶不过去。
///
/// 最后一条是「唤起了却看不见」的根因：面板 640 宽、镜像窗口常落在它的右半边，
/// 两者几乎完全重叠。既然抬不过去，就**让面板挪开**。
@MainActor
enum MirrorWindows {

    /// 唤起某几路镜像窗口；必要时把控制面板挪到不挡住它们的位置。
    static func reveal(pids: [pid_t]) {
        guard !pids.isEmpty else { return }
        if NSApp.isActive {
            perform(pids)
        } else {
            // 从程序坞菜单进来时我们未必是活跃 App。`NSApp.activate()` 是异步的，
            // 同一轮里紧接着发激活请求，系统仍认为我们在后台，会被协作式激活挡掉 ——
            // 等下一轮 runloop 再发。
            NSApp.activate()
            Task { @MainActor in perform(pids) }
        }
    }

    private static func perform(_ pids: [pid_t]) {
        let live = pids.filter { NSRunningApplication(processIdentifier: $0) != nil }
        guard !live.isEmpty else { return }

        for app in live.compactMap({ NSRunningApplication(processIdentifier: $0) }) {
            // `.activateAllWindows` 不能省：UIElement 应用没有「主窗口」的概念，
            // 不带它时窗口可能只是所属进程被激活，却没有被带到前面。
            app.activate(from: .current, options: [.activateAllWindows])
        }

        // 只让开最靠前的那一路：多路时它们本来就是阶梯错开的，躲开一个等于全躲开；
        // 真挤在一起也不是靠挪面板能解决的（那是窗口错开该干的事）。
        if let front = live.first(where: hasOnScreenWindow), let mirror = frame(ofPID: front) {
            movePanelAsideIfCovering(mirror)
        }
    }

    // MARK: - 面板让位

    private static func movePanelAsideIfCovering(_ mirror: NSRect) {
        guard let panel = mainWindow, panel.frame.intersects(mirror) else { return }
        let target = NSRect(origin: clearOrigin(of: mirror, for: panel), size: panel.frame.size)
        guard target.origin != panel.frame.origin else { return }
        // 带一点动画：窗口自己跳走会让人以为点错了东西。
        panel.setFrame(target, display: true, animate: true)
    }

    /// 找一个和 `mirror` 不重叠的位置，优先左右、其次上下，最后退回原位。
    private static func clearOrigin(of mirror: NSRect, for panel: NSWindow) -> NSPoint {
        let size = panel.frame.size
        let origin = panel.frame.origin
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? mirror
        let gap: CGFloat = 12

        func y(_ value: CGFloat) -> CGFloat {
            min(max(value, visible.minY), visible.maxY - size.height)
        }

        // 右 → 左 → 下 → 上。面板默认靠右，先试右边能少动一点。
        let candidates = [
            NSPoint(x: mirror.maxX + gap, y: y(origin.y)),
            NSPoint(x: mirror.minX - gap - size.width, y: y(origin.y)),
            NSPoint(x: origin.x, y: y(mirror.minY - gap - size.height)),
            NSPoint(x: origin.x, y: y(mirror.maxY + gap)),
        ]
        for point in candidates {
            let frame = NSRect(origin: point, size: size)
            if visible.contains(frame) && !frame.intersects(mirror) { return point }
        }
        return origin
    }

    // MARK: - 取窗口

    /// 本 App 的控制面板。排除 popover —— 它们是 `NSPanel`，不是主窗口。
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }
    }

    private static func hasOnScreenWindow(pid: pid_t) -> Bool {
        frame(ofPID: pid) != nil
    }

    /// 某个进程最靠前的那个普通窗口的位置。
    ///
    /// 只能用 `CGWindowList`：镜像窗口是别的进程的，`NSWindow` 那套 API 摸不到它。
    /// 返回的是 AppKit 坐标 —— `CGWindowBounds` 原点在主屏左上，两者 Y 轴相反。
    private static func frame(ofPID pid: pid_t) -> NSRect? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let mainHeight = NSScreen.screens.first?.frame.maxY else { return nil }

        for window in info {   // 列表本身从前到后
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
            else { continue }
            return NSRect(x: x, y: mainHeight - (y + height), width: width, height: height)
        }
        return nil
    }
}
