import AppKit
import MuseKit

/// M1：编辑视图。手工搭建 TextKit 2 栈，把文档的单一 NSTextStorage 挂进编辑面
/// （v0.2 数据所有权边界：EditorBuffer.textStorage 是唯一可变正文）。
/// 禁止代码访问 TextKit 1 的 layoutManager（会把视图打进不可逆的兼容模式）。
final class EditorTextView: NSTextView {
    /// 块级视觉的 fragment 工厂（layoutManager.delegate 是 unowned，需强引用持有）。
    private var fragmentProvider: MuseLayoutFragmentProvider?

    static func make(textStorage: NSTextStorage) -> EditorTextView {
        // TextKit 2 标准手工栈：NSTextStorage → NSTextContentStorage → NSTextLayoutManager → NSTextContainer。
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = textStorage

        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = EditorTextView(frame: .zero, textContainer: container)
        assert(textView.textLayoutManager != nil, "TextKit 2 未启用：NSTextView 未能挂接 NSTextLayoutManager")

        // 块级视觉（引用通宽背景+左竖线、代码块通宽背景、分隔线横线、列表图形符号）
        // 走自定义 fragment，不能走视图级 draw —— 见 MuseLayoutFragment 的说明。
        let provider = MuseLayoutFragmentProvider()
        textView.fragmentProvider = provider
        layoutManager.delegate = provider

        textView.allowsUndo = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true

        // 纯编辑语义：关闭所有会改写输入的自动替换/自动配对/链接检测。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        // 富文本必须保留（属性渲染依赖），但不接受图片/附件（v0.2：图片 Phase 2）。
        textView.importsGraphics = false

        // 链接的绘制样式与主题一致（.link 属性默认按 linkTextAttributes 绘制）。
        textView.linkTextAttributes = [
            .foregroundColor: Theme.standard.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        // 左侧 28pt 纯粹是正文的左页边距。列表 marker 的悬挂 lane 落在列表自己的
        // 缩进步长里（见 Theme.listIndentStep），不再借用这块页边距。
        textView.textContainerInset = NSSize(width: 28, height: 16)
        return textView
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        BlockVisualPalette.shared.update(for: effectiveAppearance)

        // TextKit 2 may reuse already-created fragments across an appearance change.
        // Invalidate the layout so the visible fragment surfaces are redrawn with the
        // palette resolved for the new appearance.
        if let layoutManager = textLayoutManager {
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
        needsDisplay = true
    }

    // MARK: - 复选框光标

    /// 复选框上换成小手光标（对标 Typora：它是可点的控件，不是文字）。
    ///
    /// AppKit 按「后加的矩形在上」解析光标区，所以先让 `NSTextView` 铺好它的
    /// I 型光标，再把复选框那几块盖上去。
    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in taskCheckboxCursorRects() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// 可见区域内每个复选框的矩形，视图坐标。
    ///
    /// 落点与命中判定共用 `taskCheckboxHitTarget()`——鼠标变小手的范围因此**恒等于**
    /// 真正能点中的范围，不会出现「显示可点却点不动」。
    ///
    /// 只走可见区间：从视口顶端那个 fragment 起枚举，越过视口底端立刻收手，
    /// 于是长文档里这条路的代价与文档长度无关。
    func taskCheckboxCursorRects() -> [CGRect] {
        guard let layoutManager = textLayoutManager else { return [] }
        let inset = textContainerOrigin
        let visible = visibleRect
        guard !visible.isEmpty else { return [] }

        let topInContainer = visible.minY - inset.y
        guard let first = layoutManager.textLayoutFragment(
            for: CGPoint(x: 0, y: max(0, topInContainer))
        ) else { return [] }

        var rects: [CGRect] = []
        layoutManager.enumerateTextLayoutFragments(
            from: first.rangeInElement.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset.y > visible.maxY { return false }
            if let fragment = fragment as? MuseLayoutFragment,
               let target = fragment.taskCheckboxHitTarget() {
                rects.append(target.frame.offsetBy(dx: inset.x, dy: inset.y))
            }
            return true
        }
        return rects
    }

    /// 复选框位置只随「重排」和「滚动」变化，两者都不改文本视图自身的 bounds，
    /// 所以 AppKit 不会自动重算光标区——这里显式失效。
    private func invalidateCheckboxCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        invalidateCheckboxCursorRects()
    }

    /// 观察 clip view 的 bounds 变化来接住滚动。
    ///
    /// 刻意用 selector 版的注册：NotificationCenter 对它持零化弱引用，视图析构时
    /// 登记自动失效，不需要在 `deinit` 里注销——而 Swift 6 的 nonisolated deinit
    /// 本来就碰不到非 Sendable 的 token。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: nil
        )
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange() {
        invalidateCheckboxCursorRects()
    }

    // MARK: - 图片预览（M5）

    /// 相对路径图片的解析基准（文档所在目录），由 EditorView 挂接时写入。
    var previewBaseURL: URL?

    private var imagePreviewPopover: NSPopover?

    /// 点击点所在字符带 `.museImageDestination` 属性时返回目的地字符串。
    func imageDestination(at point: CGPoint) -> String? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(max(0, characterIndex(for: point)), storage.length - 1)
        return storage.attribute(.museImageDestination, at: index, effectiveRange: nil) as? String
    }

    /// 在点击处弹出图片预览。transient 行为：点击别处自动关闭。
    func showImagePreview(destination: String, at point: CGPoint) {
        imagePreviewPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ImagePreviewController(
            destination: destination,
            baseURL: previewBaseURL
        )
        popover.contentSize = NSSize(width: 380, height: 280)
        popover.show(relativeTo: NSRect(origin: point, size: .zero), of: self, preferredEdge: .maxY)
        imagePreviewPopover = popover
    }
}
