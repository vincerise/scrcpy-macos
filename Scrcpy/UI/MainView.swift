//  MainView.swift
//  Scrcpy
//

import AppKit
import SwiftUI

/// 主窗口内容。版式沿用设置页那一套：顶部标题、中间一列卡片、底部一条固定操作栏。
///
/// 操作栏贴底而不是跟着内容滚：能不能开始投屏、为什么不能，是这个界面唯一的
/// 主行为，不该需要滚到某处才够得着。
struct MainView: View {

    @ObservedObject var model: AppModel

    /// 手动输入无线地址。只活在界面上，不进 Preferences —— 每次连的设备不一样。
    @State private var wirelessAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ThinScrollView {
                VStack(alignment: .leading, spacing: Theme.Metric.cardSpacing) {
                    deviceCard
                    engineCard
                    videoCard
                    behaviorCard
                    recordingCard
                    wirelessCard
                    advancedCard
                    logCard
                }
                .padding(.horizontal, Theme.Metric.pageInset)
                .padding(.bottom, Theme.Metric.pageInset)
            }

            actionBar
        }
        .frame(minWidth: 560, minHeight: 660)
        .background(Theme.Palette.settingsContent)
        .appTheme()
        .onAppear {
            model.startDevicePolling()
            model.refreshDevices()
        }
        .onDisappear { model.stopDevicePolling() }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Scrcpy")
                .font(.system(size: Theme.FontSize.settingsTitle, weight: Theme.Weight.medium))
            Spacer()
            Text(versionLine)
                .font(.system(size: Theme.FontSize.footnote))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Metric.pageInset)
        .padding(.top, Theme.Metric.pageInset)
        .padding(.bottom, 14)
    }

    private var versionLine: String {
        guard let engine = model.engine else { return "引擎未就绪" }
        return "scrcpy \(engine.version) · \(engine.origin == .managed ? "已安装" : "内置")"
    }

    // MARK: - 设备

    private var deviceCard: some View {
        let summary = model.deviceSummary
        return SettingsCard {
            SettingsRowContainer {
                // 状态点和文字要自己成一组：`SettingsRowContainer` 内部是
                // `HStack(spacing: 0)`，直接并列的话点会紧贴在第一个字上。
                HStack(spacing: 8) {
                    StatusDot(state: summary.state)
                    Text(summary.text)
                        .font(.system(size: Theme.FontSize.settingsRow))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
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

            if model.devices.count > 1 {
                SettingsRowDivider()
                SettingsRow("投屏到哪一台") {
                    ChoiceChip(
                        selection: model.deviceSelection,
                        options: model.devices.map {
                            .init(value: $0.serial as String?,
                                  title: $0.displayName,
                                  color: $0.isReady ? Theme.Accent.brand : Theme.Palette.warning,
                                  subtitle: $0.isReady ? nil : $0.statusText)
                        },
                        menuWidth: 240
                    )
                }
            }

            if let device = model.selectedDevice, device.isReady, !device.isWireless {
                SettingsRowDivider()
                SettingsRow("切换到无线", hint: "把这台 USB 设备切成 Wi-Fi 连接，之后可以不插线") {
                    ActionButton(title: "切换", systemImage: "wifi", style: .tinted) {
                        model.enableWireless()
                    }
                }
            }
        }
    }

    // MARK: - 引擎

    private var engineCard: some View {
        SettingsCard {
            SettingsRow("scrcpy 引擎", hint: engineHint) {
                engineAccessory
            }
        }
    }

    private var engineHint: String {
        if let engine = model.engine {
            return model.isRunning
                ? "投屏进行中，停掉之后才能更新"
                : "v\(engine.version) · 官方 macOS \(UpdateChecker.assetArchSuffix) 版"
        }
        return model.engineMessage ?? "正在准备…"
    }

    @ViewBuilder
    private var engineAccessory: some View {
        switch model.updateState {
        case .idle:
            ActionButton(title: "检查更新", systemImage: "arrow.triangle.2.circlepath", style: .tinted) {
                model.checkForUpdates()
            }
            .disabled(model.isRunning || model.isPreparingEngine)

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("检查中…").font(.system(size: Theme.FontSize.small)).foregroundStyle(.secondary)
            }

        case .upToDate:
            HStack(spacing: 8) {
                Text("已是最新").font(.system(size: Theme.FontSize.small)).foregroundStyle(.secondary)
                ActionButton(title: "重查", style: .quiet, height: 26) { model.checkForUpdates() }
            }

        case .available(let version):
            ActionButton(title: "更新到 \(version)", systemImage: "arrow.down.circle", style: .primary) {
                model.downloadPendingUpdate()
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: Theme.FontSize.small))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .installed(let version):
            HStack(spacing: 8) {
                Text("已更新到 \(version)")
                    .font(.system(size: Theme.FontSize.small))
                    .foregroundStyle(Theme.Palette.success)
                ActionButton(title: "好", style: .quiet, height: 26) { model.dismissUpdateState() }
            }

        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: Theme.FontSize.small))
                    .foregroundStyle(Theme.Palette.danger)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
                ActionButton(title: "重试", style: .tinted, height: 26) { model.checkForUpdates() }
            }
        }
    }

    // MARK: - 画面

    private var videoCard: some View {
        SettingsCard {
            SettingsRow("分辨率上限", hint: "限制画面长边。手机仍按原分辨率渲染，这里只压投屏的画质") {
                ChoiceChip(selection: $model.maxSize, options: [
                    .init(value: 0, title: "原始"),
                    .init(value: 1920, title: "1920"),
                    .init(value: 1280, title: "1280"),
                    .init(value: 1024, title: "1024"),
                    .init(value: 800, title: "800"),
                ])
            }
            SettingsRowDivider()
            SettingsRow("视频码率", hint: "越高越清晰，也越吃带宽。Wi-Fi 不稳就往下调") {
                ChoiceChip(selection: $model.videoBitRate, options: [
                    .init(value: "8M", title: "8 Mbps"),
                    .init(value: "4M", title: "4 Mbps"),
                    .init(value: "2M", title: "2 Mbps"),
                    .init(value: "1M", title: "1 Mbps"),
                ])
            }
            SettingsRowDivider()
            SettingsRow("帧率上限", hint: "玩游戏可以拉到 60，看文档 30 更省电") {
                ChoiceChip(selection: $model.maxFPS, options: [
                    .init(value: 0, title: "不限制"),
                    .init(value: 60, title: "60"),
                    .init(value: 30, title: "30"),
                ])
            }
        }
    }

    // MARK: - 行为

    private var behaviorCard: some View {
        SettingsCard {
            SettingsRow("转发音频", hint: "把手机的媒体声音一并传到电脑") {
                SettingsToggle(isOn: $model.audioEnabled)
            }
            SettingsRowDivider()
            SettingsRow("投屏时关闭手机屏幕", hint: "手机屏幕黑掉但仍在镜像，省电也不泄露内容") {
                SettingsToggle(isOn: $model.turnScreenOff)
            }
            SettingsRowDivider()
            SettingsRow("保持设备唤醒", hint: "投屏期间不让手机自动息屏") {
                SettingsToggle(isOn: $model.stayAwake)
            }
            SettingsRowDivider()
            SettingsRow("窗口置顶", hint: "投屏窗口压在其他窗口之上") {
                SettingsToggle(isOn: $model.alwaysOnTop)
            }
        }
    }

    // MARK: - 录制

    private var recordingCard: some View {
        SettingsCard {
            SettingsRow("录制到文件", hint: "投屏的同时把画面存成 mp4，文件名自动带时间戳") {
                SettingsToggle(isOn: $model.recordingEnabled)
            }
            if model.recordingEnabled {
                SettingsRowDivider()
                SettingsRow("保存目录") {
                    DirectoryPickerChip(path: model.recordingDirectory) {
                        pickRecordingDirectory()
                    }
                }
            }
        }
    }

    private func pickRecordingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (model.recordingDirectory as NSString).expandingTildeInPath)
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            model.recordingDirectory = url.path
        }
    }

    // MARK: - 无线

    private var wirelessCard: some View {
        SettingsCard {
            SettingsRow("按地址连接", hint: "手机与电脑在同一 Wi-Fi 时，填 手机IP:5555。首次仍需先用 USB 切一次") {
                HStack(spacing: 8) {
                    TileTextField(placeholder: "192.168.1.5:5555", text: $wirelessAddress, width: 168)
                    ActionButton(title: "连接", style: .tinted) {
                        model.connectWireless(wirelessAddress.trimmingCharacters(in: .whitespaces))
                    }
                    .disabled(!wirelessAddress.contains(":"))
                }
            }

            let wireless = model.devices.filter(\.isWireless)
            if !wireless.isEmpty {
                SettingsRowDivider()
                ForEach(Array(wireless.enumerated()), id: \.element.serial) { index, device in
                    if index > 0 { SettingsRowDivider() }
                    SettingsRow(device.displayName, hint: device.serial) {
                        ActionButton(title: "断开", style: .destructive) {
                            model.disconnectWireless(device.serial)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 高级

    private var advancedCard: some View {
        SettingsCard {
            SettingsRow("额外参数", hint: "原样透传给 scrcpy，例如 --crop=1080:1920:0:0。同名选项以这里为准") {
                TileTextField(placeholder: "留空即不追加", text: $model.extraArguments, width: 240, isMonospaced: true)
            }
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        SettingsCard {
            SettingsRowContainer {
                Text("运行日志")
                    .font(.system(size: Theme.FontSize.settingsRow))
                Spacer(minLength: 12)
                ActionButton(title: "清空", style: .quiet, height: 26) { model.clearLog() }
                    .disabled(model.logLines.isEmpty)
            }
            LogConsole(lines: model.logLines)
        }
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        VStack(spacing: 0) {
            ThemeDivider()
            HStack(spacing: 12) {
                ActionButton(
                    title: model.isRunning ? "停止投屏" : "开始投屏",
                    systemImage: model.isRunning ? "stop.fill" : "play.fill",
                    style: model.isRunning ? .destructive : .primary,
                    height: 36
                ) {
                    model.toggleSession()
                }
                .disabled(!model.isRunning && !model.canStart)

                Text(actionHint)
                    .font(.system(size: Theme.FontSize.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Metric.pageInset)
            .padding(.vertical, 12)
        }
    }

    /// 按钮禁用时说清楚为什么 —— 一个灰掉又没解释的按钮是最气人的。
    private var actionHint: String {
        if model.isRunning { return "投屏中。关闭投屏窗口，或点左边的按钮停止。" }
        if model.isPreparingEngine { return "正在准备引擎…" }
        if model.engine == nil { return "还没有 scrcpy 引擎，先在上面点「检查更新」下载一份。" }
        if model.selectedDevice?.isReady != true { return "没有可用的设备。用 USB 连上手机并打开「USB 调试」。" }
        if case .downloading = model.updateState { return "正在下载引擎更新…" }
        return "参数改完直接点开始。"
    }
}
