//  main.swift
//  Scrcpy
//

import AppKit

// 用显式的 AppKit 启动流程而不是 SwiftUI 的 `App` 协议：
// 我们要在 `run()` 之前就把 delegate 和菜单装好，而且需要在
// `applicationShouldTerminate` 里拦下退出、先给 scrcpy 发 SIGTERM 让它
// 清理设备上的 scrcpy-server。SwiftUI 的 App 生命周期把这一步藏得太深。
//
// 注意：本文件存在时，模块内**不能**再有任何 `@main`。

/// `NSApplication.delegate` 是 **weak** 的，必须有别的东西强引用住它。
///
/// 声明成全局变量而不是闭包里的局部变量：局部变量在最后一次使用之后就可能被
/// ARC 回收，`run()` 刚跑起来 delegate 就变 nil 了，菜单和生命周期回调全部失灵。
///
/// `AppDelegate` 是 `@MainActor` 的，而 main.swift 的顶层代码是 nonisolated，
/// 所以赋值只能在下面的 `assumeIsolated` 里做 —— 顶层代码本来就跑在主线程上，
/// 这个假设是成立的。
var appDelegate: AppDelegate?

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    appDelegate = delegate

    let app = NSApplication.shared
    app.delegate = delegate
    // 显式设成 .regular：不在 bundle 里跑（比如直接 `swift run`）时，
    // 默认策略会让 App 没有 Dock 图标、也不进启动台。
    app.setActivationPolicy(.regular)
    app.run()
}
