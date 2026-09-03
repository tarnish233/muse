import AppKit
import SwiftUI
import Testing

/// 标题栏控件与红绿灯的对齐契约。
///
/// 这一组测试守的是「几何从窗口读、不写死」：把 `controlTopInset` 换回
/// `titlebarHeight / 2`（原实现）会让 `controlLandsOnTheTrafficLightCenterline`
/// 变红。
@Suite @MainActor struct WindowControlsGeometryTests {
    /// Muse 生产窗口的 style mask（见 `EditorWindowController`）。
    private static let museStyleMask: NSWindow.StyleMask =
        [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]

    private func makeWindow(
        styleMask: NSWindow.StyleMask = Self.museStyleMask,
        hostsSwiftUI: Bool = true,
        laidOut: Bool = true
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if hostsSwiftUI {
            window.contentViewController = NSHostingController(rootView: Color.clear)
        }
        if laidOut {
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.layoutIfNeeded()
        }
        return window
    }

    /// 红绿灯在标题栏里垂直居中，所以中心线也可以从 `contentLayoutRect` 独立推出。
    /// 这条路径不碰按钮 frame，能抓住坐标系用错（翻转视图上朴素 y-up 公式给 -15pt）。
    @Test func centerlineAgreesWithTheTitlebarDerivedFromContentLayoutRect() throws {
        let window = makeWindow()
        let geometry = try #require(WindowControlsGeometry.measured(in: window))
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height

        #expect(titlebarHeight > 0)
        #expect(abs(geometry.centerY - titlebarHeight / 2) < 0.5)
        #expect(geometry.centerY > 0, "翻转坐标系算反会得到负值")
    }

    /// 参考应用（Codex）截图实测：红绿灯中心线 16.00pt、按钮组右缘 68.48pt。
    /// 这里钉住绝对值——`EditorChromeMetrics.controlCenterGap` 是照着这两个数调的，
    /// 一旦 macOS 挪动红绿灯，这条会变红提醒重新测量，而不是静默错位。
    @Test func measuredValuesMatchTheReferenceMeasurement() throws {
        let geometry = try #require(WindowControlsGeometry.measured(in: makeWindow()))
        #expect(abs(geometry.centerY - 16) < 1)
        #expect(abs(try #require(geometry.trailingEdge) - 69) < 1)
    }

    /// 承重断言：控件中心必须落在红绿灯中心线上。
    @Test func controlLandsOnTheTrafficLightCenterline() throws {
        let geometry = try #require(WindowControlsGeometry.measured(in: makeWindow()))
        let controlCenter = geometry.controlTopInset + EditorChromeMetrics.titlebarControlSize / 2
        #expect(abs(controlCenter - geometry.centerY) < 0.01)

        // `titlebarHeight / 2` 不能再当反例：band 现在正好对称在这条中心线上
        // （32 = 2×16），两种实现的结果重合。改为喂一条人造中心线——写死实现会
        // 无视它、仍旧给 16pt。
        let moved = WindowControlsGeometry(centerY: 40, trailingEdge: geometry.trailingEdge)
        let movedCenter = moved.controlTopInset + EditorChromeMetrics.titlebarControlSize / 2
        #expect(abs(movedCenter - 40) < 0.01)
    }

    /// `NSHostingView.isFlipped == true`：转进内容视图后 `midY` 本身已经是「距顶
    /// 距离」，再套 y-up 的 `maxY - midY` 就量成了距底距离。测量因此走窗口坐标系。
    ///
    /// 朴素公式错得有两种面貌，取决于内容视图是否已布局（已布局 744pt，未布局
    /// -15pt），所以这里只断言「两种状态下都与正确值差得很远」，不去钉具体错值。
    @Test func flippedHostingViewDoesNotInvertTheCenterline() throws {
        for laidOut in [true, false] {
            let window = makeWindow(laidOut: laidOut)
            let content = try #require(window.contentView)
            #expect(content.isFlipped, "NSHostingView 是翻转的；本测试的前提")

            let geometry = try #require(WindowControlsGeometry.measured(in: window))
            let close = try #require(window.standardWindowButton(.closeButton))
            let naiveYUp = content.bounds.maxY - content.convert(close.bounds, from: close).midY

            #expect(geometry.centerY > 0)
            #expect(
                abs(naiveYUp - geometry.centerY) > 25,
                "laidOut=\(laidOut) 朴素 y-up 公式给 \(naiveYUp)，正确值 \(geometry.centerY)"
            )
        }
    }

    /// 窗口未显示时 `NSHostingView.bounds` 还是 1×1，但测量走的是窗口坐标系里的
    /// 内容区，所以未布局与已布局必须给出同一组数。
    @Test func geometryIsIdenticalBeforeAndAfterLayout() throws {
        let unlaid = try #require(WindowControlsGeometry.measured(in: makeWindow(laidOut: false)))
        let laidOut = try #require(WindowControlsGeometry.measured(in: makeWindow(laidOut: true)))
        #expect(unlaid == laidOut)
    }

    @Test func firstControlClearsTheTrafficLightsByTheMeasuredGap() throws {
        let geometry = try #require(WindowControlsGeometry.measured(in: makeWindow()))
        let trailingEdge = try #require(geometry.trailingEdge)
        let controlCenterX = geometry.leadingControlInset
            + EditorChromeMetrics.titlebarControlSize / 2

        #expect(geometry.leadingControlInset > trailingEdge, "控件 frame 不得压住红绿灯")
        #expect(
            abs(controlCenterX - (trailingEdge + EditorChromeMetrics.controlCenterGap)) < 0.01
        )
        // 参考截图里侧栏字形中心在 94.08pt。
        #expect(abs(controlCenterX - 94.08) < 1)
    }

    @Test func documentTitleClearsTheFirstControl() throws {
        let geometry = try #require(WindowControlsGeometry.measured(in: makeWindow()))
        #expect(
            geometry.documentTitleInset
                >= geometry.leadingControlInset + EditorChromeMetrics.titlebarControlSize
        )
    }

    /// 没有红绿灯可对齐时回退到条内居中。
    ///
    /// 这里用无按钮的窗口触发，而不是全屏：AppKit 对「非全屏过渡期间设置
    /// NSWindowStyleMaskFullScreen」直接抛 NSGenericException，测试里合成不出那个状态。
    /// 全屏路径由 `measured` 里的 `.fullScreen` 守卫加进出全屏通知重测覆盖。
    @Test func windowWithoutTrafficLightsFallsBackToBandCentering() throws {
        #expect(WindowControlsGeometry.measured(in: makeWindow(styleMask: .borderless, hostsSwiftUI: false)) == nil)
        #expect(WindowControlsGeometry.measured(in: makeWindow(styleMask: [.titled, .fullSizeContentView])) == nil)

        // 按钮存在但被隐藏：`compactMap` 挡不住这种，要靠 isHidden 过滤器。
        let hidden = makeWindow()
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            hidden.standardWindowButton(kind)?.isHidden = true
        }
        #expect(WindowControlsGeometry.measured(in: hidden) == nil)

        let fallback = WindowControlsGeometry.unavailable
        let controlCenter = fallback.controlTopInset + EditorChromeMetrics.titlebarControlSize / 2
        #expect(abs(controlCenter - EditorChromeMetrics.titlebarHeight / 2) < 0.01)
        #expect(fallback.leadingControlInset == EditorChromeMetrics.trailingControlInset)
    }
}
