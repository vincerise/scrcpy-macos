//  Theme.swift
//  Scrcpy
//

import AppKit
import SwiftUI

/// 视觉令牌：所有颜色 / 字号 / 圆角 / 尺寸都从这里取，视图里不散落数字。
enum Theme {

    // MARK: - 颜色

    enum Palette {

        /// 窗口背景。`Color/Panel/Background`
        static let panelBackground = Theme.dynamic(light: 0xFFFFFF, dark: 0x191919)

        /// 瓷片：卡片内的输入区块、分段底槽、悬停前的静止底。
        static let tile = Theme.dynamic(light: 0xF4F4F4, dark: 0x292929)

        /// 浮起来的卡面（弹层、输入框白底）。浅色纯白、深色比瓷片再亮一档。
        static let cardSurface = Theme.dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)

        /// 悬停时瓷片加深一档。
        static let tileHover = Theme.dynamic(light: 0xEBEBEB, dark: 0x333335)

        /// 分隔线。
        static let divider = Theme.dynamic(light: 0xE5E5E7, dark: 0x3A3A3C)

        /// 第三级文字（占位、补位信息）。
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)

        /// 内容区底（设置窗口）。
        static let settingsContent = Theme.dynamic(light: 0xF7F7F7, dark: 0x191919)

        /// 设置卡片填充。白卡浮在 #F7F7F7 上，不再同色描边。
        static let settingsCard = Theme.dynamic(light: 0xFFFFFF, dark: 0x292929)

        /// 设置卡片描边。
        static let settingsCardBorder = Theme.dynamic(light: 0xE5E5E7, dark: 0x3A3A3C)

        /// 连接正常 / 更新完成。
        static let success = Color(nsColor: .systemGreen)

        /// 危险操作（断开、删除）。
        static let danger = Theme.dynamic(light: 0xD92B2B, dark: 0xFF6B6B)

        /// 未授权 / 需要用户去手机上确认。
        static let warning = Theme.dynamic(light: 0xC77700, dark: 0xFFB340)

        /// 日志区的等宽正文底。
        static let consoleBackground = Theme.dynamic(light: 0xF4F4F4, dark: 0x1F1F1F)

    }

    // MARK: - 强调色

    /// 品牌强调色。取自应用图标渐变里最深的那一端（青绿 #3C9990），
    /// 提了一档饱和度让它当控件底时不发灰。深色模式提亮，否则压在深底上糊成一团。
    enum Accent {
        static let brand = Theme.dynamic(light: 0x1E9C8F, dark: 0x2FB3A4)

        /// 强调色的淡底（选中态、胶囊）。15% 是设计规范里定的那一档。
        static let tintOpacity: Double = 0.15
    }

    // MARK: - 动态取色

    /// 按外观动态取色。用 `NSColor(name:dynamicProvider:)` 而不是两个 `Color`
    /// 手动切换：这样 `NSApp.appearance` 一变，AppKit 自己重解析，
    /// 视图不需要订阅任何东西。
    ///
    /// 放在 `Theme` 这一层而不是 `Palette` 里 —— 强调色也要用，而嵌在 `Palette`
    /// 里的私有方法 `Accent` 取不到。
    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let color = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
        return Color(nsColor: color)
    }

    // MARK: - 字重

    /// 只允许三档。`bold` 只给最大的那个标题；其余标题 `medium`，正文一律 `regular`。
    /// 到处 semibold 是「字好粗、廉价」的来源。
    enum Weight {
        static let regular: Font.Weight = .regular
        static let medium: Font.Weight = .medium
        static let bold: Font.Weight = .bold
    }

    // MARK: - 字号

    enum FontSize {
        /// 设置页 / 面板标题。
        static let settingsTitle: CGFloat = 18
        /// 正文、设备名。
        static let body: CGFloat = 14
        /// 设置行标签。
        static let settingsRow: CGFloat = 13.5
        /// 卡片里的条目标题。
        static let itemTitle: CGFloat = 13
        /// 说明文字、芯片。
        static let caption: CGFloat = 12
        /// 时间、次要信息。
        static let small: CGFloat = 11.5
        /// 列表名、角标文字。
        static let footnote: CGFloat = 11
        /// 日志正文。等宽，比正文小一号但不能再小，否则中文糊。
        static let log: CGFloat = 11.5
    }

    // MARK: - 圆角

    /// **按元素尺寸分档，外大内小**，全项目只有这 6 个值，全部 continuous。
    /// 圆形（状态点、开关）不在此列。
    enum Radius {
        /// 顶级容器：窗口内容卡、盖屏浮层。
        static let panel: CGFloat = 14
        /// 卡片 / 分组 / 弹出菜单。
        static let card: CGFloat = 12
        /// 28–40pt：胶囊控件、行悬停底、主按钮。
        static let tile: CGFloat = 8
        /// 20–28pt：小按钮、菜单行高亮、分段选中项。
        static let control: CGFloat = 6
        /// ≤ 20pt：复选框、小徽标、小图标按钮悬停底。
        static let xs: CGFloat = 4
        /// 色条、光标、状态竖条。
        static let bar: CGFloat = 2
    }

    // MARK: - 尺寸

    enum Metric {
        /// 窗口内容四周内边距。
        static let panelPadding: CGFloat = 12
        /// 设置卡片行高。
        static let settingsRowHeight: CGFloat = 42
        /// 页面内容区四周留白。
        static let pageInset: CGFloat = 20
        /// 卡片之间的间距。
        static let cardSpacing: CGFloat = 12
        /// 日志区高度。
        static let consoleHeight: CGFloat = 190
        /// 状态圆点直径。
        static let dot: CGFloat = 7
    }
}

private extension NSColor {

    /// 由 `0xRRGGBB` 构造不透明颜色。只在本文件用 —— 令牌以外的地方不该出现十六进制。
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
