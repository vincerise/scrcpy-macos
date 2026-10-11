//  Inputs.swift
//  Scrcpy
//

import SwiftUI

/// 瓷片风格的单行输入框。
///
/// 不用 `.textFieldStyle(.roundedBorder)`：系统那个圆角边框 + 内阴影跟瓷片语言
/// 不是一套东西，摆在白卡里像贴了别的 App 的零件。这里自己铺瓷片底，
/// 聚焦时才浮现强调色描边 —— 焦点反馈只给一次，不要常态就描一圈。
struct TileTextField: View {

    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    var isMonospaced = false

    @FocusState private var isFocused: Bool
    @Environment(\.appAccent) private var accent

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: Theme.FontSize.settingsRow, design: isMonospaced ? .monospaced : .default))
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.Palette.tile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isFocused ? accent.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// 「选一个目录」的行内控件：显示当前路径（过长时中间省略），右侧一个选择按钮。
///
/// 路径用 `Text` 而不是输入框 —— 用户不该手打路径，那是 `NSSavePanel` 的事。
struct DirectoryPickerChip: View {

    let path: String
    let onPick: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(abbreviated)
                .font(.system(size: Theme.FontSize.small))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .trailing)
            ActionButton(title: "选择…", style: .quiet, height: 26, action: onPick)
        }
    }

    /// 把 home 前缀缩成 `~`，长路径才有机会露出尾部。
    private var abbreviated: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
