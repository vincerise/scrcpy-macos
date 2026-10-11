//  AppAccent.swift
//  Scrcpy
//

import SwiftUI

/// 全 App 的强调色。
///
/// **为什么不直接用 `Color.accentColor`**：那个符号读的是**系统**强调色
/// （系统设置 → 外观 → 颜色），不由 App 决定。我们要的是品牌青绿，
/// 写 `Color.accentColor` 的话用户换个系统色，整个 App 的调性就跟着跑偏。
///
/// **为什么不用 `.tint(_:)` 一把梭**：`.tint` 只影响**控件**（按钮、开关）的着色，
/// 而我们对强调色的用法有一半是**自己画的图形** —— 状态点、选中描边、连接指示。
/// 那些读的是环境值，`.tint` 管不到。所以两件事都要做。
private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = Theme.Accent.brand
}

extension EnvironmentValues {

    /// 当前强调色。视图请用 `@Environment(\.appAccent)` 读它。
    var appAccent: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}

extension View {

    /// 一次性把强调色铺到整棵视图树：控件走 `.tint`，自绘走环境值。
    /// 每个根视图都要调一次，否则新加的根视图会漏掉其中一个。
    func appTheme() -> some View {
        self
            .tint(Theme.Accent.brand)
            .environment(\.appAccent, Theme.Accent.brand)
    }
}
