//  HoverButtonStyle.swift
//  Scrcpy
//

import SwiftUI

/// 图标按钮与胶囊的统一反馈：悬停铺瓷片灰圆角底、图标染强调色；按下再深一档。
///
/// 用 `ButtonStyle` 而不是每个按钮各写 `onHover`：反馈不一致比没有反馈更显廉价。
/// 图标颜色由本样式下发，所以调用方的 label **不要**再自己写 `foregroundStyle`。
struct HoverButtonStyle: ButtonStyle {

    /// 底的圆角。图标按钮 6，胶囊 8。
    var cornerRadius: CGFloat = Theme.Radius.control

    /// 静止态颜色。默认次要色；已激活的按钮（连接中、筛选中）传强调色。
    var idleColor: Color = .secondary

    /// 悬停底色。默认瓷片灰；强调色胶囊传 `accent.opacity(0.1)`。
    var hoverFill: Color? = nil

    /// 悬停时是否把前景染成强调色。图标按钮要；文字已是强调色的胶囊不必。
    var tintsOnHover = true

    @Environment(\.appAccent) private var accent
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isHovering || configuration.isPressed
        configuration.label
            .foregroundStyle(active && tintsOnHover ? accent : idleColor)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill(active: active, pressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func fill(active: Bool, pressed: Bool) -> Color {
        guard active else { return .clear }
        if let hoverFill { return pressed ? hoverFill.opacity(0.8) : hoverFill }
        return pressed ? Theme.Palette.tileHover : Theme.Palette.tile
    }
}

/// 列表行 / 侧栏项的悬停反馈：整行铺圆角底。
///
/// 与 `HoverButtonStyle` 的区别：**不改前景色** —— 行里有状态点、多段文字，
/// 统一染色会把层级毁掉。
struct RowHoverButtonStyle: ButtonStyle {

    /// 悬停底色。白底上用瓷片灰；灰底上用 6% 黑。
    var hoverFill: Color = Theme.Palette.tile
    /// 按下底色：比悬停再深一档，让「点下去了」看得见。
    var pressedFill: Color = Theme.Palette.tileHover
    var cornerRadius: CGFloat = Theme.Radius.tile
    /// 底色向外扩多少（让底比内容宽一圈）。
    var outset: CGFloat = 0

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, outset)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? pressedFill : (isHovering ? hoverFill : Color.clear))
            )
            .padding(.horizontal, -outset)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
