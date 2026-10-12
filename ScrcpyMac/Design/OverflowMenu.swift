//  OverflowMenu.swift
//  Scrcpy
//

import SwiftUI

/// 行尾的 `⋯` 菜单：一个图标按钮 + 一个自绘 popover。
///
/// 设备列表里每台设备都有若干次要动作（切无线、断开、复制序列号），
/// 全铺成按钮的话一行会挤满控件，而且这些动作大部分时候用不上。
///
/// 弹层的样式照抄 `ChoiceChip` 那一套（`panelBackground` + 固定宽度 + `MenuRow`），
/// 不用 SwiftUI 的 `Menu`：系统菜单会按自己的样式渲染触发按钮和菜单行，
/// 摆在瓷片风格的行里像贴了别的 App 的零件。
struct OverflowMenu: View {

    struct Item {
        var title: String = ""
        /// 跟在标题后面的一句小字，用来区分两个听起来很像的动作。太长会被截断。
        var subtitle: String? = nil
        var systemImage: String? = nil
        var isDestructive = false
        var isEnabled = true
        /// 分隔线。用「一个什么都没有的条目」表示，省掉在 ForEach 里判下标的麻烦。
        var isSeparator = false
        var action: () -> Void = {}

        static let separator = Item(isSeparator: true)
    }

    let items: [Item]
    /// 触发按钮的文案。给了就用一个带箭头的胶囊当触发按钮，不给仍是那个 `⋯` 图标。
    /// 有些菜单（参数作用域）需要把「这里能干什么」写在脸上，一个 `⋯` 说明不了。
    var title: String? = nil
    var help: String = "更多操作"
    /// 弹层宽度。带副标题的菜单要宽一些，否则副标题会被截掉。
    var menuWidth: CGFloat = 176

    @State private var isPresented = false

    var body: some View {
        trigger
            .help(help)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        if item.isSeparator {
                            ThemeDivider().padding(.vertical, 4)
                        } else {
                            MenuRow(
                                title: item.title,
                                subtitle: item.subtitle,
                                systemImage: item.systemImage,
                                isEnabled: item.isEnabled,
                                isDestructive: item.isDestructive
                            ) {
                                // 先关弹层再执行：动作里可能有会弹窗或改列表的操作，
                                // 让弹层停在屏幕上会挡住结果。
                                isPresented = false
                                item.action()
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(width: menuWidth)
                .background(Theme.Palette.panelBackground)
                .presentationBackground(Theme.Palette.panelBackground)
            }
    }

    @ViewBuilder
    private var trigger: some View {
        if let title {
            ChipButton(title: title, showsChevron: true, fill: Theme.Palette.tile) {
                isPresented.toggle()
            }
        } else {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: Theme.Weight.medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(HoverButtonStyle())
        }
    }
}
