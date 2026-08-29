import AppKit

/// Where the window's standard close/minimize/zoom buttons actually sit, so the
/// hand-built titlebar band can put its own controls on the same line.
///
/// Read from `NSWindow.standardWindowButton(_:)` rather than hard-coded. With
/// Muse's style mask AppKit currently centers them 16pt below the top of the
/// content area and ends the group at x=69 — but those are AppKit's numbers to
/// change (a toolbar moves them down, full screen takes them out of the titlebar
/// altogether), not ours to copy into a constant.
struct WindowControlsGeometry: Equatable, Sendable {
    /// Distance from the top of the window's content area down to the buttons'
    /// centerline. Chrome controls center on this to share their line.
    let centerY: CGFloat

    /// Distance from the leading edge of the content area to the trailing edge
    /// of the button group, or `nil` when there are no traffic lights to clear.
    let trailingEdge: CGFloat?

    /// Fallback for "there are no traffic lights to align to": before a window is
    /// attached, and in full screen where AppKit removes them from the titlebar.
    /// Centers controls in the chrome band, which is what the band did before it
    /// learned to align — and is correct in full screen, where no titlebar exists
    /// for them to line up with.
    static let unavailable = WindowControlsGeometry(
        centerY: EditorChromeMetrics.titlebarHeight / 2,
        trailingEdge: nil
    )

    /// Measures `window`'s traffic lights, or `nil` when it has none to measure.
    ///
    /// Everything is converted into the window's own coordinate space, which is
    /// always y-up. Converting into the content view instead needs an
    /// `isFlipped` branch to be correct: `NSHostingView` *is* flipped, and the
    /// y-up formula reports -15pt there rather than 16pt.
    @MainActor
    static func measured(in window: NSWindow) -> WindowControlsGeometry? {
        guard window.styleMask.contains(.fullScreen) == false,
              let content = window.contentView
        else { return nil }

        let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { $0.isHidden == false && $0.superview != nil }
            .map { $0.convert($0.bounds, to: nil) }
        guard let first = frames.first else { return nil }

        let group = frames.dropFirst().reduce(first) { $0.union($1) }
        // 用窗口坐标系里的内容区，而不是 contentView.bounds：窗口尚未显示时
        // bounds 可能还是 1×1，而两者都挂在同一个窗口空间里、标题栏恒定贴在内容区
        // 上方，所以这个差值在未布局与已布局两种状态下都得到同一个 16.00pt。
        let contentInWindow = content.convert(content.bounds, to: nil)
        return WindowControlsGeometry(
            centerY: contentInWindow.maxY - group.midY,
            trailingEdge: group.maxX - contentInWindow.minX
        )
    }
}

extension WindowControlsGeometry {
    /// Top padding that lands a `titlebarControlSize`-tall control on the
    /// traffic-light centerline.
    var controlTopInset: CGFloat {
        max(0, centerY - EditorChromeMetrics.titlebarControlSize / 2)
    }

    /// Leading padding for the first chrome control, placing its center
    /// `controlCenterGap` past the traffic lights — or at the plain edge inset
    /// when there are none to clear.
    var leadingControlInset: CGFloat {
        guard let trailingEdge else { return EditorChromeMetrics.trailingControlInset }
        return trailingEdge + EditorChromeMetrics.controlCenterGap
            - EditorChromeMetrics.titlebarControlSize / 2
    }

    /// Leading inset for document chrome that has to clear both the traffic
    /// lights and the first chrome control beside them.
    var documentTitleInset: CGFloat {
        leadingControlInset + EditorChromeMetrics.titlebarControlSize
            + EditorChromeMetrics.titleClearance
    }
}
