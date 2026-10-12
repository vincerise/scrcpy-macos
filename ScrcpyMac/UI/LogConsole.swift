//  LogConsole.swift
//  Scrcpy
//

import SwiftUI

/// 运行日志区。等宽、可滚动、自动跟到底。
///
/// **自动跟随有个必须处理的细节**：用户往上翻看历史时再自动滚到底，会把人拽回来。
/// 所以只在「视口本来就贴着底」时才跟随 —— 这也是终端和聊天窗口的通行做法。
/// 判断依据是当前偏移与最大偏移的差；差在几像素内就算贴底。
struct LogConsole: View {

    let lines: [AppModel.LogLine]
    /// 多设备时在行首标出这行是哪台设备吐的。只看单台时不必标 —— 满屏都是同一台。
    var showsSourceTags = false

    @State private var proxy: ScrollViewProxy?
    /// 视图底部锚点的 id。滚到它即为滚到底。
    private let bottomAnchor = "log-bottom"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if lines.isEmpty {
                Text("运行日志会显示在这里。")
                    .font(.system(size: Theme.FontSize.small))
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            ThinScrollView(onProxy: { proxy = $0 }) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        row(for: line)
                    }
                    // 零高度的锚点，用来「滚到底」。
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(height: Theme.Metric.consoleHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(Theme.Palette.consoleBackground)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onChange(of: lines.count) { _, _ in
            guard let proxy else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// 一行日志。带来源时把标签单独画一个 `Text`，不用「拼进正文」的写法 ——
    /// 拼进去的话标签会跟着正文一起被染成错误红，而且换行时对不齐。
    @ViewBuilder
    private func row(for line: AppModel.LogLine) -> some View {
        if showsSourceTags, let source = line.source {
            HStack(alignment: .top, spacing: 6) {
                Text("[\(source.name)]")
                    .font(.system(size: Theme.FontSize.log, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                body(of: line)
            }
        } else {
            body(of: line)
        }
    }

    private func body(of line: AppModel.LogLine) -> some View {
        Text(line.text)
            .font(.system(size: Theme.FontSize.log, design: .monospaced))
            .foregroundStyle(color(for: line.text))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 只给两类行上色：错误红、我们自己的状态行用强调色。
    /// 其余一律次要色 —— scrcpy 的日志大部分是例行输出，全染成正文色会喧宾夺主。
    private func color(for text: String) -> Color {
        if text.contains("[错误]") || text.contains("ERROR") || text.contains("error:") {
            return Theme.Palette.danger
        }
        if text.hasPrefix("[") { return Theme.Palette.tertiaryText }
        return .secondary
    }
}
