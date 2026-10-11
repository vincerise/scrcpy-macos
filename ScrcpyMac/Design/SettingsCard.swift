//  SettingsCard.swift
//  Scrcpy
//

import SwiftUI

/// 一张卡片：圆角 12、白卡填充 + 1pt 描边，里面按行摆内容。
///
/// 不用 `Form(.grouped)` 的 `Section`：系统分组表单的样式改不动（行高、描边、
/// 底色都是它自己定的），而我们要的是更高的行、更明确的卡片边界。
/// 行与行之间的分隔线由调用方用 `SettingsRowDivider` 显式放 ——
/// SwiftUI 没有「子视图之间自动插东西」的公开 API。
struct SettingsCard<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Palette.settingsCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Palette.settingsCardBorder, lineWidth: 1)
        )
    }
}

/// 卡片里的一行：左侧标题（可带一行说明），右侧一个控件。
///
/// 行高不低于 42：这是「开关 + 13.5pt 文字」看起来不挤的下限。
struct SettingsRow<Accessory: View>: View {

    let title: String
    var hint: String?

    @ViewBuilder let accessory: Accessory

    init(_ title: String, hint: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.hint = hint
        self.accessory = accessory()
    }

    var body: some View {
        SettingsRowContainer {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Theme.FontSize.settingsRow))
                if let hint {
                    SettingsHint(hint)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

/// 一行的外壳：只管内边距与最小行高，内容随意。
/// 不是「标题 + 控件」结构的行（状态条、日志区）用它。
struct SettingsRowContainer<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: Theme.Metric.settingsRowHeight, alignment: .leading)
    }
}

/// 卡片内两行之间的分隔线，左侧缩进与行内容对齐。
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.settingsCardBorder)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

/// 标题下面那行灰色说明。
struct SettingsHint: View {

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: Theme.FontSize.small))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 卡片下方右对齐的一句说明。贴紧上面那张卡片：它是注脚，不是下一组的开头。
struct SettingsCardFootnote: View {

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: Theme.FontSize.small))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 4)
            .padding(.top, -6)
    }
}
