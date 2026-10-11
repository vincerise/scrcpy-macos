//  ThinScrollView.swift
//  Scrcpy
//

import AppKit
import SwiftUI

/// 全项目统一的滚动容器：`ScrollView` + **自绘**细滚动条。
///
/// ## 为什么自己画一条，而不是用系统的
///
/// 系统的覆盖式滚动条粗细由 AppKit 定死（7pt），改不了；观感也比正文重。
/// 设计稿里滚动条根本没画过 —— 按「不画就不该抢眼」处理：把系统指示器整个关掉，
/// 自己画一条 3pt 的胶囊：滚动时露头（120ms 淡入），停手约 1 秒淡出（350ms），
/// 不滚动时滑块根本不在视图树里，不会挡住内容的点击。
///
/// ## 为什么不用 `onScrollGeometryChange`
///
/// 那个 API 是 macOS 15 起的，本 App 的部署目标是 14.0。这里退回
/// `GeometryReader` + `PreferenceKey` 的经典写法读滚动偏移 —— 只读，
/// 不改变滚动区本来的行为，所以调用方的滚轮路径一点没动。
///
/// ## 拖拽为什么走 AppKit
///
/// 读几何是只读的，写只有一处 —— 用户真去拖滑块那一刻。而 SwiftUI 在
/// macOS 14 上没有「命令式滚到某个偏移」的公开 API（`scrollPosition` 是可写绑定，
/// 挂上去就等于让绑定参与滚动区的定位，调用方全都要押在「绑定维护得对、
/// 且不与滚轮打架」这个假设上）。
///
/// 所以只留一个零尺寸的抓手把底下的 `NSScrollView` 捞出来，拖拽时调
/// `NSClipView.scroll(to:)` —— 那正是 AppKit 自己拖滚动条时调的同一个方法。
struct ThinScrollView<Content: View>: View {

    var axes: Axis.Set = .vertical
    /// 拿到 `ScrollViewProxy`。日志区靠它自动滚到底。
    var onProxy: ((ScrollViewProxy) -> Void)? = nil
    @ViewBuilder let content: () -> Content

    /// 内容相对滚动区原点的偏移。向下滚时内容上移，这个值是负的，取反后当进度用。
    @State private var contentOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var isKnobVisible = false
    /// 手指按在滑块上：按住不松时不该淡出。
    @State private var isDraggingKnob = false
    /// 一次拖拽开始时的内容偏移。拖动过程中会一直读它，所以单独存。
    @State private var dragStartOffset: CGFloat?

    /// 底下那个 `NSScrollView`，拖拽用。由 `ScrollDriverView` 在挂上视图树后回填。
    @State private var scrollView: NSScrollView?

    /// 每滚动一次 +1。`.task(id:)` 靠它重启「停手 1 秒」的计时。
    @State private var scrollTick = 0

    /// 几何测量要一个具名坐标空间才拿得到「相对滚动区」的位置。
    private let space = "ThinScrollView"

    var body: some View {
        GeometryReader { outer in
            let viewport = outer.size.height
            ScrollView(axes) {
                ScrollViewReader { proxy in
                    ZStack(alignment: .topLeading) {
                        // 零尺寸的抓手必须在**内容里**：ScrollView 自己的 background
                        // 是 NSScrollView 的兄弟层，向上找不到它。
                        ScrollDriverView { scrollView = $0 }
                            .frame(width: 0, height: 0)
                        content()
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named(space)).minY)
                                        .preference(key: ContentHeightKey.self, value: geo.size.height)
                                }
                            )
                    }
                    .onAppear { onProxy?(proxy) }
                }
            }
            .coordinateSpace(name: space)
            .scrollIndicators(.never)
            .onPreferenceChange(ScrollOffsetKey.self) { minY in
                let newOffset = -minY
                let didScroll = abs(newOffset - contentOffset) > 0.5
                contentOffset = newOffset
                if didScroll { revealKnob(viewport: viewport) }
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .overlay(alignment: .topTrailing) { knob(viewport: viewport) }
        }
        .task(id: scrollTick) { await hideKnobAfterHold() }
    }

    // MARK: - 几何

    /// 滑块长度占轨道的比例 = 视口占内容的比例，和系统滚动条一个算法。
    private func knobTrack(viewport: CGFloat) -> (track: CGFloat, length: CGFloat, travel: CGFloat) {
        let track = max(viewport - Knob.trackInset * 2, 0)
        let ratio = contentHeight > 0 ? viewport / contentHeight : 1
        let length = min(max(track * ratio, Knob.minLength), track)
        return (track, length, max(track - length, 0))
    }

    /// 还能滚多远。0 表示内容没溢出。
    private func maxOffset(viewport: CGFloat) -> CGFloat {
        max(contentHeight - viewport, 0)
    }

    private func progress(viewport: CGFloat) -> CGFloat {
        let maxOff = maxOffset(viewport: viewport)
        guard maxOff > 0 else { return 0 }
        return min(max(contentOffset / maxOff, 0), 1)
    }

    // MARK: - 滑块

    @ViewBuilder
    private func knob(viewport: CGFloat) -> some View {
        let track = knobTrack(viewport: viewport)
        if maxOffset(viewport: viewport) > 0, isKnobVisible, track.track > 0 {
            ZStack(alignment: .trailing) {
                // 3pt 的滑块指针抓不住：命中区加宽到 11pt，只往左扩，
                // 右沿仍与滑块对齐，不侵占滚动区右侧的边距。
                Color.clear.frame(width: Knob.hitWidth, height: track.length)
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isDraggingKnob ? Knob.activeOpacity : Knob.idleOpacity))
                    .frame(width: Knob.thickness, height: track.length)
            }
            .contentShape(Rectangle())
            .gesture(knobDrag(viewport: viewport, travel: track.travel))
            .padding(.trailing, Knob.trailingInset)
            .offset(y: Knob.trackInset + progress(viewport: viewport) * track.travel)
            .transition(.opacity)
        }
    }

    private func knobDrag(viewport: CGFloat, travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let maxOff = maxOffset(viewport: viewport)
                guard travel > 0, maxOff > 0 else { return }
                if dragStartOffset == nil {
                    dragStartOffset = contentOffset
                    isDraggingKnob = true
                }
                let start = dragStartOffset ?? contentOffset
                // 拖动距离按「轨道能走多远 ↔ 内容能滚多远」等比放大。
                let moved = value.translation.height / travel * maxOff
                scroll(toY: min(max(start + moved, 0), maxOff))
            }
            .onEnded { _ in
                dragStartOffset = nil
                isDraggingKnob = false
                // 松手才开始算「停手 1 秒」，否则按住不动到 1 秒会被淡掉。
                scrollTick &+= 1
            }
    }

    /// 把可见原点挪到 `y`（内容坐标，向下为正）。钳位交给调用方。
    private func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - 出现 / 淡出

    private func revealKnob(viewport: CGFloat) {
        guard maxOffset(viewport: viewport) > 0 else { return }
        if !isKnobVisible {
            withAnimation(Timing.fadeIn) { isKnobVisible = true }
        }
        scrollTick &+= 1
    }

    /// `.task(id: scrollTick)`：id 一变，上一轮还没睡完的任务被取消，这一轮重新计时。
    private func hideKnobAfterHold() async {
        guard scrollTick > 0 else { return }
        do {
            try await Task.sleep(for: Timing.hold)
        } catch {
            // 又被滚了一下：新的一轮计时已经接管，这里什么都不做。
            return
        }
        // 手指还按着就不淡出 —— 松手时 `onEnded` 会再起一轮计时。
        guard !isDraggingKnob else { return }
        withAnimation(Timing.fadeOut) { isKnobVisible = false }
    }
}

// MARK: - 几何传递

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 抓手

/// 把 `ScrollView` 底下那个 `NSScrollView` 抓出来交给拖拽。
///
/// 自己不画任何东西，只是个零尺寸的钩子：挂上视图树后顺着 superview 找 `NSScrollView`。
/// 回填走 `Task { @MainActor }` 而不是就地赋值 —— `viewDidMoveToWindow` 在布局过程里，
/// 当场改 SwiftUI 状态会报「Modifying state during view update」。
private struct ScrollDriverView: NSViewRepresentable {

    let onFound: (NSScrollView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeNSView(context: Context) -> DriverView {
        let view = DriverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: DriverView, context: Context) {
        context.coordinator.onFound = onFound
    }

    final class Coordinator {

        var onFound: (NSScrollView) -> Void

        init(onFound: @escaping (NSScrollView) -> Void) {
            self.onFound = onFound
        }
    }

    final class DriverView: NSView {

        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            var cursor: NSView? = superview
            while let view = cursor {
                if let found = view as? NSScrollView {
                    Task { @MainActor [weak self] in self?.coordinator?.onFound(found) }
                    return
                }
                cursor = view.superview
            }
        }
    }
}

// MARK: - 尺寸与节奏

/// 自绘滑块的尺寸与配色。
private enum Knob {

    /// 滑块粗细。设计稿没有画过滚动条，3pt 是「看得见但不抢眼」的那一档。
    static let thickness: CGFloat = 3

    /// 滑块右沿距滚动区右沿。系统覆盖式滚动条留的是 3pt，这里窄一点更贴边。
    static let trailingInset: CGFloat = 2

    /// 轨道上下各留这么多：滑到顶 / 到底时不贴住滚动区的边。
    static let trackInset: CGFloat = 2

    /// 滑块最短长度。长列表里按比例算出来只有几像素，抓不住也看不清。
    static let minLength: CGFloat = 24

    /// 命中区宽度（含滑块本身）。3pt 的指针目标太小，往外扩到 11pt。
    static let hitWidth: CGFloat = 11

    /// 常态与按住时的不透明度。系统覆盖式滑块量出来是 50% 黑，
    /// 这里常态更淡一档 ——「细」靠 3pt，「不抢眼」靠这个透明度。
    static let idleOpacity: Double = 0.3
    static let activeOpacity: Double = 0.5
}

private enum Timing {

    static let fadeIn: Animation = .easeOut(duration: 0.12)
    static let fadeOut: Animation = .easeIn(duration: 0.35)

    /// 停手之后还留这么久再淡出。
    static let hold: Duration = .seconds(1)
}
