//  DeviceListCard.swift
//  Scrcpy
//

import AppKit
import SwiftUI

/// 设备卡：一台上一条，各自带「投屏 / 停止」。
///
/// 取代了早先「下拉里挑一台」的写法 —— 同时投几台时，那套「选中一台」的心智模型
/// 和界面对不上：底部那个按钮到底会启动哪一台，取决于一个看不见的选中项。
///
/// 零设备时退化成一行状态提示，和以前看到的一样。
struct DeviceListCard: View {

    @ObservedObject var model: AppModel
    @Binding var wirelessAddress: String

    var body: some View {
        SettingsCard {
            header

            if model.rows.isEmpty {
                SettingsRowDivider()
                emptyState
            } else {
                ForEach(model.rows) { row in
                    SettingsRowDivider()
                    DeviceRowView(model: model, row: row)
                }
            }

            SettingsRowDivider()
            connectRow
        }
    }

    // MARK: - 组头

    private var header: some View {
        SettingsRowContainer {
            Text("设备")
                .font(.system(size: Theme.FontSize.settingsRow))
            Spacer(minLength: 12)
            if model.rows.count > 1 {
                Text("\(model.rows.count) 台")
                    .font(.system(size: Theme.FontSize.small))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                model.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: Theme.Weight.medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(HoverButtonStyle())
            .help("重新扫描设备")
            .disabled(model.isRefreshingDevices)
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        SettingsRowContainer {
            HStack(spacing: 8) {
                StatusDot(state: .idle)
                Text("未检测到设备，请用 USB 连接手机并打开「USB 调试」")
                    .font(.system(size: Theme.FontSize.settingsRow))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 按地址连接

    private var connectRow: some View {
        SettingsRow("按地址连接", hint: "手机与电脑在同一 Wi-Fi 时，填 手机IP:5555。首次仍需先用 USB 切一次") {
            HStack(spacing: 8) {
                TileTextField(placeholder: "192.168.1.5:5555", text: $wirelessAddress, width: 168)
                ActionButton(title: "连接", style: .tinted) {
                    model.connectWireless(wirelessAddress.trimmingCharacters(in: .whitespaces))
                }
                .disabled(!wirelessAddress.contains(":"))
            }
        }
    }
}

// MARK: - 单台设备

private struct DeviceRowView: View {

    @ObservedObject var model: AppModel
    let row: AppModel.DeviceRow

    /// 副标题的左缩进 = 状态点直径 + 间距，让两行文字左对齐而不是挂在点下面。
    private let textInset: CGFloat = 15

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedSerial == row.serial }

    var body: some View {
        SettingsRowContainer {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    StatusDot(state: dotState)
                    Text(row.name)
                        .font(.system(size: Theme.FontSize.settingsRow))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitle)
                    .font(.system(size: Theme.FontSize.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, textInset)
                    .help(detail)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                sessionControls
                OverflowMenu(items: menuItems, help: "\(row.name) 的更多操作")
            }
        }
        // 整行可点：按钮（停止 / ⋯）自己会先吃掉点击，落不到这里来。
        .contentShape(Rectangle())
        .background(rowBackground)
        .overlay(alignment: .leading) { selectionBar }
        .onHover { isHovering = $0 }
        // 单击 = 选中（下面的参数卡片切到这台），双击 = 把投屏窗口提到最前。
        // 不给单击两种含义（「没选中就选中、已选中就唤起」那种）：一个手势的意思随状态变，
        // 用户没法预期；而双击「激活」本来就是 macOS 的语义。
        .onTapGesture(count: 2) { model.bringMirrorToFront(serial: row.serial) }
        .onTapGesture { model.select(serial: row.serial) }
        // 整行可点这件事对辅助功能是隐形的：这一行暴露出去的只有「投屏 / 停止」和「⋯」
        // 两个按钮，不加这一句，VoiceOver 用户没有任何入口能切换参数卡片编辑的是哪台。
        // `.contain` 而不是 `.combine`：两个按钮要各自还是一个可点的元素。
        .accessibilityElement(children: .contain)
        .accessibilityAction { model.select(serial: row.serial) }
        .help(helpText)
    }

    // MARK: - 选中态

    /// 选中 > 悬停 > 无。选中用强调色淡底，和上面作用域条里那个状态点同色，两处连得起来。
    private var rowBackground: Color {
        if isSelected { return Theme.Accent.brand.opacity(Theme.Accent.tintOpacity) }
        return isHovering ? Theme.Palette.tileHover : Color.clear
    }

    /// 选中行左侧那道竖条。设备行永远在卡片中间（上有机头、下有「按地址连接」），
    /// 碰不到卡片的圆角，所以这里可以放心铺满整行高度。
    @ViewBuilder
    private var selectionBar: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                .fill(Theme.Accent.brand)
                .frame(width: Theme.Metric.selectionBarWidth)
                .padding(.vertical, 6)
        }
    }

    private var helpText: String {
        row.state == .running
            ? "点一下选中：下面的参数卡片切到这台；双击把投屏窗口提到最前"
            : "点一下选中：下面的参数卡片切到这台"
    }

    // MARK: 左侧

    private var dotState: StatusDot.State {
        row.isReady ? .connected : .warning
    }

    private var subtitle: String {
        guard let device = row.device else { return "设备已断开" }
        guard device.isReady else { return device.statusText }
        return "\(device.serial) · \(device.connectionKind.rawValue)"
    }

    private var detail: String {
        guard let device = row.device else {
            return "\(row.serial)\n设备已不在 adb 列表里，但投屏进程还在跑。"
        }
        return "\(device.serial)\n\(device.statusText)"
    }

    // MARK: 右侧

    @ViewBuilder
    private var sessionControls: some View {
        switch row.state {
        case .starting:
            stateLabel("启动中…", isActive: false)
            ActionButton(title: "投屏", style: .tinted, isEnabled: false) {}

        case .running:
            stateLabel("投屏中", isActive: true)
            ActionButton(title: "停止", style: .destructive) {
                model.stopSession(serial: row.serial)
            }

        case .stopping:
            stateLabel("停止中…", isActive: false)
            ActionButton(title: "停止", style: .destructive, isEnabled: false) {}

        default:
            ActionButton(title: "投屏", style: .tinted, isEnabled: row.isReady) {
                model.startSession(serial: row.serial)
            }
        }
    }

    /// 会话状态文字。用颜色而不是第二个圆点区分 —— 行首那个点说的是「设备连上没有」，
    /// 再放一个点会让人分不清哪个是哪个。
    private func stateLabel(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: Theme.FontSize.small))
            .foregroundStyle(isActive ? Theme.Accent.brand : Color.secondary)
    }

    // MARK: 行内菜单

    private var menuItems: [OverflowMenu.Item] {
        var items: [OverflowMenu.Item] = []

        // 整行可点这件事是看不出来的，所以这里再给一个写明了动作的入口。
        if row.state == .running {
            items.append(.init(title: "显示投屏窗口", systemImage: "macwindow.on.rectangle") {
                model.bringMirrorToFront(serial: row.serial)
            })
        }

        if let device = row.device, device.isReady, !device.isWireless, !row.isBusy {
            items.append(.init(title: "切换到无线", systemImage: "wifi") {
                model.enableWireless(serial: row.serial)
            })
        }

        if let device = row.device, device.isWireless {
            items.append(.init(title: "断开连接", systemImage: "wifi.slash", isDestructive: true) {
                model.disconnectWireless(row.serial)
            })
        }

        if !items.isEmpty { items.append(.separator) }

        // 序列号是这个界面上唯一能拿去 `adb -s` 用的东西，给个复制入口。
        items.append(.init(title: "复制序列号", systemImage: "doc.on.doc") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(row.serial, forType: .string)
        })

        return items
    }
}
