//  DesignKit.swift
//  Scrcpy
//

import SwiftUI

// 设计系统的基础组件（一处实现、处处复用）。
// 规则：界面上的按钮 / 分段 / 菜单 / 分隔线 / 浮层壳，只能从这里取；
// 各页面不再各写一份 `RoundedRectangle().fill(...)`。

// MARK: - 按钮

/// 文字按钮。四档：`primary` 实心强调色 + 白字（启动）；`tinted` 强调色淡底 + 强调色字（次要动作）；
/// `quiet` 无底次要色（取消）；`destructive` 红字灰底（断开）。
struct ActionButton: View {

    enum Style {
        case primary
        case tinted
        case quiet
        case destructive
    }

    let title: String
    var systemImage: String? = nil
    var style: Style = .tinted
    var width: CGFloat? = nil
    var height: CGFloat = 30
    var isEnabled = true
    let action: () -> Void

    @Environment(\.appAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: Theme.Weight.medium))
                }
                if !title.isEmpty {
                    Text(title).font(.system(size: Theme.FontSize.settingsRow, weight: style == .quiet ? Theme.Weight.regular : Theme.Weight.medium))
                }
            }
            .frame(width: width, height: height)
            .padding(.horizontal, width == nil ? 14 : 0)
            .frame(maxWidth: width == nil ? nil : width)
        }
        .buttonStyle(HoverButtonStyle(
            cornerRadius: Theme.Radius.tile,
            idleColor: idleColor,
            hoverFill: hoverFill,
            tintsOnHover: style == .quiet
        ))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(idleFill)
        )
        .disabled(!isEnabled)
        // 禁用态整体压暗，而不是换一套配色 —— 四档各写一份禁用色会失控。
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var idleColor: Color {
        switch style {
        case .primary: .white
        case .tinted: accent
        case .quiet: .secondary
        case .destructive: Theme.Palette.danger
        }
    }

    private var idleFill: Color {
        switch style {
        case .primary: accent
        case .tinted: accent.opacity(Theme.Accent.tintOpacity)
        case .quiet: .clear
        case .destructive: Theme.Palette.tile
        }
    }

    private var hoverFill: Color? {
        switch style {
        case .primary: accent.opacity(0.85)
        case .tinted: accent.opacity(0.13)
        case .quiet: Theme.Palette.tile
        case .destructive: Theme.Palette.tileHover
        }
    }
}

// MARK: - 分段

/// 分段选择：瓷片底槽 + 选中项实心强调色。
struct SegmentedChips<Value: Hashable>: View {

    struct Segment {
        let value: Value
        var title: String? = nil
        var systemImage: String? = nil
        var help: String? = nil
    }

    @Binding var selection: Value
    let segments: [Segment]
    var segmentWidth: CGFloat? = nil
    /// 底槽颜色（放在白卡里传 `panelBackground`，放在瓷片里传 `cardSurface`）。
    var trackFill: Color = Theme.Palette.tile

    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let isOn = selection == segment.value
                Button {
                    selection = segment.value
                } label: {
                    HStack(spacing: 4) {
                        if let systemImage = segment.systemImage {
                            Image(systemName: systemImage).font(.system(size: 12, weight: Theme.Weight.medium))
                        }
                        if let title = segment.title {
                            Text(title).font(.system(size: Theme.FontSize.caption, weight: isOn ? Theme.Weight.medium : Theme.Weight.regular))
                        }
                    }
                    .frame(width: segmentWidth, height: 26)
                    .padding(.horizontal, segmentWidth == nil ? 10 : 0)
                }
                // 未选中段悬停出瓷片灰；选中段已是强调色实底，悬停不再变。
                .buttonStyle(HoverButtonStyle(
                    cornerRadius: Theme.Radius.control,
                    idleColor: isOn ? .white : .secondary,
                    hoverFill: isOn ? .clear : Theme.Palette.tileHover,
                    tintsOnHover: false
                ))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(isOn ? accent : Color.clear))
                .help(segment.help ?? "")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(trackFill))
    }
}

// MARK: - 胶囊与自绘菜单

/// 胶囊控件：32 高、圆角 8、瓷片底，图标 + 文字 + 可选下拉箭头。
struct ChipButton: View {

    var systemImage: String? = nil
    var color: Color? = nil
    let title: String
    var showsChevron = false
    var isProminent = false
    var textColor: Color? = nil
    /// 底色。默认瓷片灰；放在白卡里时传 `tile`，放在瓷片卡里传 `cardSurface`。
    var fill: Color = Theme.Palette.tile
    var isEnabled = true
    let action: () -> Void

    @Environment(\.appAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12))
                }
                Text(title).lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: Theme.Weight.medium))
                }
            }
            .font(.system(size: Theme.FontSize.itemTitle))
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .buttonStyle(HoverButtonStyle(
            cornerRadius: Theme.Radius.tile,
            idleColor: textColor ?? (isProminent ? Color.white : Color.primary),
            hoverFill: isProminent ? accent.opacity(0.85) : Theme.Palette.tileHover,
            tintsOnHover: false
        ))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(isProminent ? accent : fill)
        )
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// 「点胶囊弹自绘菜单选一项」。
///
/// 不用 SwiftUI 的 `Menu`：系统菜单会按自己的样式渲染触发按钮（蓝色高亮、
/// 自带指示器），和瓷片风格的胶囊摆在一起像贴了别的 App 的零件。
struct ChoiceChip<Value: Hashable>: View {

    struct Option {
        let value: Value
        let title: String
        var color: Color? = nil
        var systemImage: String? = nil
        var subtitle: String? = nil
    }

    @Binding var selection: Value
    let options: [Option]
    var systemImage: String? = nil
    var placeholder: String = "—"
    var menuWidth: CGFloat = 200
    var arrowEdge: Edge = .bottom
    var fill: Color = Theme.Palette.tile
    var isEnabled = true

    @State private var isPresented = false

    var body: some View {
        let current = options.first { $0.value == selection }
        ChipButton(
            systemImage: systemImage,
            color: current?.color,
            title: current?.title ?? placeholder,
            showsChevron: true,
            textColor: current == nil ? .secondary : nil,
            fill: fill,
            isEnabled: isEnabled
        ) { isPresented.toggle() }
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        MenuRow(
                            title: option.title,
                            subtitle: option.subtitle,
                            systemImage: option.systemImage,
                            color: option.color,
                            isChecked: option.value == selection
                        ) {
                            selection = option.value
                            isPresented = false
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(width: menuWidth)
            .frame(maxHeight: 320)
            .background(Theme.Palette.panelBackground)
            .presentationBackground(Theme.Palette.panelBackground)
        }
        .disabled(!isEnabled || options.isEmpty)
    }
}

/// 自绘菜单里的一行：行高 28、13pt 正文、选中项前打勾、可带色点或图标。
/// 悬停铺浅灰而不是系统蓝。
struct MenuRow: View {

    var title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var color: Color? = nil
    var isChecked = false
    var isEnabled = true
    /// 危险动作（断开连接、删除）用红字。系统菜单靠 `NSMenuItem` 的
    /// `isDestructive` 做同一件事，自绘菜单得自己来。
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: Theme.Weight.medium))
                    .frame(width: 12)
                    .opacity(isChecked ? 1 : 0)
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: Theme.FontSize.itemTitle))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: Theme.FontSize.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isHovering ? Theme.Palette.tile : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.Palette.tertiaryText }
        return isDestructive ? Theme.Palette.danger : .primary
    }
}

// MARK: - 分隔线 / 开关 / 状态点

/// 1pt 分隔线。`inset` = 左缩进（对齐行内文字）。
struct ThemeDivider: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(Theme.Palette.divider).frame(height: 1).padding(.leading, inset)
    }
}

/// 系统 switch，无标签。
struct SettingsToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
    }
}

/// 连接状态点。`connected` 时用强调色，其余用传入的色。
struct StatusDot: View {

    enum State {
        case connected
        case warning
        case idle
    }

    let state: State

    @Environment(\.appAccent) private var accent

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Theme.Metric.dot, height: Theme.Metric.dot)
    }

    private var color: Color {
        switch state {
        case .connected: accent
        case .warning: Theme.Palette.warning
        case .idle: Theme.Palette.tertiaryText
        }
    }
}
