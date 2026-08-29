import CoreGraphics

enum EditorChromeMetrics {
    static let titlebarHeight: CGFloat = 46
    static let projectSidebarDefaultWidth: CGFloat = 280
    static let outlineSidebarDefaultWidth: CGFloat = 300
    static let projectSidebarRange: ClosedRange<CGFloat> = 240...380
    static let outlineSidebarRange: ClosedRange<CGFloat> = 240...380
    static let titlebarControlSize: CGFloat = 28
    static let trailingControlInset: CGFloat = 10

    /// Distance from the traffic lights' trailing edge to the center of the first
    /// chrome control. Measured off the reference app: its sidebar glyph centers
    /// 94.1pt from the window's leading edge with the button group ending at
    /// 68.5pt. The control's *center* is the anchor rather than its frame edge, so
    /// the spacing survives a change to `titlebarControlSize`.
    static let controlCenterGap: CGFloat = 25

    /// Gap between the first chrome control and the document title beside it.
    static let titleClearance: CGFloat = 20

    /// Document title inset when the project sidebar already clears the window
    /// controls. Tracks the editor's text container inset so the title sits on
    /// the body text column.
    static let documentTitleEdgeInset: CGFloat = 28

    /// Room reserved on the document title's trailing side for the outline toggle.
    static let documentTitleTrailingInset: CGFloat = 52
}
