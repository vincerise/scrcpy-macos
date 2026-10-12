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
            // 页头、作用域条、底部操作栏这三条钉在窗口上，高度只由内容决定（fixedSize）；
            // 伸缩的活儿全归中间的滚动区。不钉的话它们会跟着窗口高度一起分空间，
            // 而文字是可以被压到一行以下的 —— 表现出来就是说明文字被压掉半行、
            // 标题栏底下那条分隔线从字中间穿过去。
            header
                .fixedSize(horizontal: false, vertical: true)
            scopeBar
                .fixedSize(horizontal: false, vertical: true)

            ThinScrollView {
                VStack(alignment: .leading, spacing: Theme.Metric.cardSpacing) {
                    DeviceListCard(model: model, wirelessAddress: $wirelessAddress)
                    engineCard
                    videoCard
                    behaviorCard
                    recordingCard
                    advancedCard
                    globalCard
                    logCard
                }
                .padding(.horizontal, Theme.Metric.pageInset)
                .padding(.bottom, Theme.Metric.pageInset)
            }

            actionBar
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 560, minHeight: 660)
        // ignoresSafeArea 是必须的：窗口用了 .fullSizeContentView，内容铺到标题栏底下，
        // 不忽略安全区的话标题栏那一条不会被这个背景盖住，会露出一段系统灰。
        .background(Theme.Palette.settingsContent.ignoresSafeArea())
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
            Text("ScrcpyMac")
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

    // MARK: - 参数作用域

    /// 参数作用域条：**钉在滚动区之上、不随内容滚动**。
    ///
    /// 它要回答的是「我现在改的是哪台的参数」，而这个疑问恰恰在滚到下面几张卡片时才冒出来
    /// —— 做成随内容滚的条，等滚到「额外参数」时它已经不在屏幕上了，等于没做。
    ///
    /// 也不是第二排 tab：设备列表已经有序列号 / 连接方式 / 状态点 / 按钮，再列一遍同一批
    /// 设备，在 640 宽的窗口里是把同一件事说两遍。
    private var scopeBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        if let row = model.selectedRow {
                            StatusDot(state: row.isReady ? .connected : .warning)
                            Text(row.name)
                                .font(.system(size: Theme.FontSize.settingsRow, weight: Theme.Weight.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(model.isCustomized(row.serial) ? "单独设置" : "跟随默认")
                                .font(.system(size: Theme.FontSize.small))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("默认参数")
                                .font(.system(size: Theme.FontSize.settingsRow, weight: Theme.Weight.medium))
                        }
                    }
                    SettingsHint(scopeHint)
                }
                Spacer(minLength: 0)
                if model.selectedRow != nil {
                    OverflowMenu(
                        items: scopeMenuItems,
                        title: "应用到其他设备",
                        help: "把这台的参数同步给别的设备，或把它改回默认",
                        menuWidth: 320
                    )
                }
            }
            .padding(.horizontal, Theme.Metric.pageInset)
            .padding(.vertical, 8)

            ThemeDivider()
        }
        .background(Theme.Palette.settingsContent)
    }

    private var scopeHint: String {
        guard let row = model.selectedRow else {
            return "新插入的设备按这份初始化；点上面的设备行可以单独设置某一台"
        }
        if model.sessionStates[row.serial] != nil {
            return "只对这一台生效 · 正在投屏，改动下次投屏生效"
        }
        return "只对这一台生效，别的设备各自一套"
    }

    /// 作用域菜单。
    ///
    /// 这几个动作都收在菜单里而不是铺在卡片上：它们改的是「别的设备」或「这台之外的所有设备」，
    /// 而卡片上每一个控件改的都是当前这一台 —— 混在一起会让人以为「应用到所有设备」也是个开关。
    /// 菜单本身就是二次确认（点开、读到副标题、再点那一项），不用系统弹窗；
    /// 全项目到现在也只有自绘 popover。
    private var scopeMenuItems: [OverflowMenu.Item] {
        let customized = model.selectedRow.map { model.isCustomized($0.serial) } ?? false
        // 副标题是**一行 inline**（`MenuRow` 的版式），太长会被截掉尾巴 —— 所以每句都压到
        // 十字上下，把非说不可的那半句放在最前面。
        var items: [OverflowMenu.Item] = [
            .init(
                title: "恢复默认参数",
                subtitle: "改回跟随默认",
                isEnabled: customized
            ) { [serial = model.selectedSerial] in
                guard let serial else { return }
                model.resetToDefault(serial)
            },
            .separator,
            .init(
                title: "把这台设为默认",
                subtitle: "只影响以后插的设备",
                isEnabled: customized
            ) {
                model.setSelectedAsDefault()
            },
        ]

        // 只有一台设备时「所有设备」就是它自己，这个动作没有意义。
        if model.rows.count > 1 {
            items.append(.init(
                title: "应用到所有 \(model.rows.count) 台设备",
                subtitle: "覆盖其他所有设备",
                isDestructive: true
            ) {
                model.applySelectedToAllDevices()
            })
        }
        return items
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

        case .engineReady(let version):
            HStack(spacing: 8) {
                Text("引擎已就绪 · scrcpy \(version)")
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
                ChoiceChip(selection: model.binding(\.maxSize), options: [
                    .init(value: 0, title: "原始"),
                    .init(value: 1920, title: "1920"),
                    .init(value: 1280, title: "1280"),
                    .init(value: 1024, title: "1024"),
                    .init(value: 800, title: "800"),
                ])
            }
            SettingsRowDivider()
            SettingsRow("视频码率", hint: "越高越清晰，也越吃带宽。Wi-Fi 不稳就往下调") {
                ChoiceChip(selection: model.binding(\.videoBitRate), options: [
                    .init(value: "8M", title: "8 Mbps"),
                    .init(value: "4M", title: "4 Mbps"),
                    .init(value: "2M", title: "2 Mbps"),
                    .init(value: "1M", title: "1 Mbps"),
                ])
            }
            SettingsRowDivider()
            SettingsRow("帧率上限", hint: "玩游戏可以拉到 60，看文档 30 更省电") {
                ChoiceChip(selection: model.binding(\.maxFPS), options: [
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
                SettingsToggle(isOn: model.binding(\.audioEnabled))
            }
            SettingsRowDivider()
            SettingsRow("投屏时关闭手机屏幕", hint: "手机屏幕黑掉但仍在镜像，省电也不泄露内容") {
                SettingsToggle(isOn: model.binding(\.turnScreenOff))
            }
            SettingsRowDivider()
            SettingsRow("保持设备唤醒", hint: "投屏期间不让手机自动息屏") {
                SettingsToggle(isOn: model.binding(\.stayAwake))
            }
            SettingsRowDivider()
            SettingsRow("停止投屏后让手机息屏", hint: "投屏结束、scrcpy 退出之后把手机屏幕按灭，省得再伸手按一次电源键") {
                SettingsToggle(isOn: model.binding(\.screenOffOnStop))
            }
            SettingsRowDivider()
            SettingsRow("窗口置顶", hint: "投屏窗口压在其他窗口之上") {
                SettingsToggle(isOn: model.binding(\.alwaysOnTop))
            }
        }
    }

    // MARK: - 录制

    private var recordingCard: some View {
        SettingsCard {
            SettingsRow("录制到文件", hint: "投屏的同时把画面存成 mp4，文件名自动带设备名和时间戳") {
                SettingsToggle(isOn: model.binding(\.recordingEnabled))
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

    // MARK: - 高级

    private var advancedCard: some View {
        SettingsCard {
            SettingsRow("额外参数", hint: "原样透传给 scrcpy，例如 --crop=1080:1920:0:0。同名选项以这里为准。只对这一台生效 —— 想让多台一致就用上面的「应用到其他设备」") {
                TileTextField(placeholder: "留空即不追加", text: model.binding(\.extraArguments), width: 240, isMonospaced: true)
            }
        }
    }

    // MARK: - 全局

    /// 全机一份的两项。
    ///
    /// 单独挪出来而不是留在各自的卡片里：上面那四张卡从设备列表往下全是「当前这一台」的，
    /// 保护这件事唯一的办法是**结构性**的，靠一句「（全局）」的 hint 去对抗误改是文案对
    /// 结构的补丁，迟早会漏。
    private var globalCard: some View {
        SettingsCard {
            SettingsRow("多台时错开窗口", hint: "同时投屏多台设备时把窗口依次错开，否则它们会精确重叠在一起。说的是整组窗口怎么摆，不属于任何一台") {
                SettingsToggle(isOn: $model.cascadeWindows)
            }
            SettingsRowDivider()
            SettingsRow("录制保存目录", hint: "所有设备的录制都存到这里，文件名里已经带设备名，不会撞") {
                DirectoryPickerChip(path: model.recordingDirectory) {
                    pickRecordingDirectory()
                }
            }
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        let sources = model.logSources
        return SettingsCard {
            SettingsRowContainer {
                Text("运行日志")
                    .font(.system(size: Theme.FontSize.settingsRow))
                Spacer(minLength: 12)
                // 只有一台设备时没什么可筛的，那个下拉就不出现。
                if sources.count > 1 {
                    ChoiceChip(
                        selection: $model.logSource,
                        options: [.init(value: nil, title: "全部", systemImage: "square.stack.3d.up")]
                            + sources.map { .init(value: $0.serial as String?, title: $0.name) },
                        menuWidth: 200
                    )
                }
                ActionButton(title: "清空", style: .quiet, height: 26) { model.clearLog() }
                    .disabled(model.logLines.isEmpty)
            }
            // 前缀只在「多台、且没筛单台」时才有意义：只有一台设备时那个下拉根本不出现，
            // 此时每行都挂一个同样的前缀纯属噪音。
            let tags = sources.count > 1 && model.logSource == nil
            LogConsole(lines: model.visibleLogLines, showsSourceTags: tags)
        }
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        VStack(spacing: 0) {
            ThemeDivider()
            HStack(spacing: 12) {
                if model.isRunning {
                    ActionButton(
                        title: model.runningCount > 1 ? "全部停止" : "停止投屏",
                        systemImage: "stop.fill",
                        style: .destructive,
                        height: 36
                    ) {
                        model.stopAll()
                    }
                    // 已经在投的时候插进来一台新的，不必先全停再全开。
                    if !model.startableSerials.isEmpty {
                        ActionButton(
                            title: "投屏另外 \(model.startableSerials.count) 台",
                            systemImage: "play.fill",
                            style: .tinted,
                            height: 36
                        ) {
                            model.startAll()
                        }
                        .disabled(!model.canStartAny)
                    }
                } else {
                    ActionButton(
                        title: model.startableSerials.count > 1 ? "全部投屏" : "开始投屏",
                        systemImage: "play.fill",
                        style: .primary,
                        height: 36
                    ) {
                        model.startAll()
                    }
                    .disabled(!model.canStartAny)
                }

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
        if model.isRunning {
            let count = model.runningCount
            return count > 1
                ? "\(count) 台投屏中。关掉投屏窗口，或点左边的按钮全部停止。"
                : "投屏中。关闭投屏窗口，或点左边的按钮停止。"
        }
        if model.isPreparingEngine { return "正在准备引擎…" }
        if model.engine == nil { return "还没有 scrcpy 引擎，先在上面点「检查更新」下载一份。" }
        if case .downloading = model.updateState { return "正在下载引擎更新…" }
        if case .checking = model.updateState { return "正在检查更新…" }
        if model.startableSerials.isEmpty {
            return model.rows.isEmpty
                ? "没有可用的设备。用 USB 连上手机并打开「USB 调试」。"
                : "没有可用设备。未授权或离线的设备要先在手机上确认。"
        }
        if model.startableSerials.count > 1 {
            return "\(model.startableSerials.count) 台设备已就绪，会同时打开 \(model.startableSerials.count) 个投屏窗口。"
        }
        return "参数改完直接点开始。"
    }
}
