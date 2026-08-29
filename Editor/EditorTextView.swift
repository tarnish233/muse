import AppKit
import MuseKit

/// M1：编辑视图。手工搭建 TextKit 2 栈，把文档的单一 NSTextStorage 挂进编辑面
/// （v0.2 数据所有权边界：EditorBuffer.textStorage 是唯一可变正文）。
/// 禁止代码访问 TextKit 1 的 layoutManager（会把视图打进不可逆的兼容模式）。
final class EditorTextView: NSTextView {
    /// 块级视觉的 fragment 工厂（layoutManager.delegate 是 unowned，需强引用持有）。
    private var fragmentProvider: MuseLayoutFragmentProvider?

    /// Closer inserted by Muse for the active symmetric pair. Its validity is
    /// tied to the view's edit epoch: any other edit invalidates the pair, so
    /// locations can never go stale (缺陷 13：取代整篇字符串快照的 O(n) 比较).
    private struct PendingPair {
        let marker: String
        let openerLocation: Int
        let closerLocation: Int
        let epoch: Int
    }
    private var pendingPair: PendingPair?
    /// 每次真实文本变化自增（didChangeText 是 NSTextView 所有编辑路径的汇合点）。
    private var editEpoch = 0

    override func didChangeText() {
        editEpoch += 1
        super.didChangeText()
    }

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

    // MARK: - M4 editing behavior

    /// Called from the NSTextView delegate command hook. Returning false lets
    /// AppKit perform its normal newline command unchanged.
    func performSmartNewline(selectedRanges ranges: [NSValue]? = nil) -> Bool {
        pendingPair = nil
        let ranges = ranges ?? selectedRanges
        guard let selection = ranges.first?.rangeValue else { return false }
        guard hasMarkedText() == false,
              ranges.count == 1,
              let blockContext = typingBlockContext(at: selection.location),
              let edit = TypingBehaviors.newlineEdit(
                in: string as NSString,
                selection: selection,
                blockContext: blockContext
              )
        else { return false }

        breakUndoCoalescing()
        let manager = undoManager
        manager?.beginUndoGrouping()
        super.insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selectionAfter)
        manager?.endUndoGrouping()
        breakUndoCoalescing()
        return true
    }

    /// Block context for the line holding `location`, or `nil` when there is no
    /// line to classify.
    ///
    /// Rendered attributes are authoritative where they exist, but they trail the
    /// keystroke by far more than the pause before a user presses Enter —
    /// measured 37.9ms at 20KB, 343ms at 200KB and 1.83s at 1MB from the last
    /// keystroke to `.museBlock` landing. Requiring them made a freshly typed
    /// list item fail to continue, so resolution happens in three tiers: an
    /// authoritative veto, an authoritative accept, then the line's own shape.
    private func typingBlockContext(at location: Int) -> TypingBehaviors.BlockContext? {
        let source = string as NSString
        guard source.length > 0 else { return nil }

        if let index = lineContentIndex(in: source, at: location) {
            let block = textStorage?.attribute(.museBlock, at: index, effectiveRange: nil) as? String

            // Veto tier. A code fence owns `.museBlock` across the whole block
            // including its line terminators, and text typed inside inherits it
            // through typingAttributes, so it is present even on a brand-new
            // interior line and even before that line has been re-rendered
            // (verified against real AppKit). This is what keeps the shape
            // fallback below from injecting a bullet into someone's code.
            if block == BlockVisual.codeFence.rawValue || block == BlockVisual.rule.rawValue {
                return .other
            }

            // Accept tier. A container block owns `.museBlock` for the whole line,
            // so `> - item` reports "quote" — but the quote only writes that one
            // key, leaving the list marker attributes intact underneath. They are
            // therefore the reliable structural signal, and reading them is what
            // makes lists inside blockquotes continue.
            if textStorage?.attribute(.museListMarkerLocation, at: index, effectiveRange: nil) != nil {
                let depth = (textStorage?.attribute(.museListDepth, at: index, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
                return .list(depth: depth)
            }
            if block == BlockVisual.heading.rawValue {
                return .heading
            }
        }

        // 属性还没落地（或从未渲染）。上面的否决层已经承担了「行自己回答不了」的
        // 那个问题——围栏——剩下的按行形状判断是安全的。
        return TypingBehaviors.lineShapeContext(in: source, at: location)
    }

    /// An index guaranteed to sit inside the line's own contents.
    ///
    /// `.museBlock` for a list or heading stops at the line's last content
    /// character, so a caret parked on the terminator of `- item\nnext` would
    /// otherwise read the *following* block's attributes and misclassify.
    private func lineContentIndex(in source: NSString, at location: Int) -> Int? {
        let clamped = max(0, min(location, source.length))
        let line = source.lineRange(for: NSRange(location: clamped, length: 0))
        var end = NSMaxRange(line)
        while end > line.location {
            let character = source.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        guard end > line.location else { return nil }
        return min(max(clamped, line.location), end - 1)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard hasMarkedText() == false,
              selectedRanges.count == 1,
              let plainString = insertString as? String
        else {
                pendingPair = nil
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let effectiveRange = replacementRange.location == NSNotFound
            ? selectedRange()
            : replacementRange
        let activePair = pendingPair?.epoch == editEpoch ? pendingPair : nil
        let allowMarkerUpgrade = canUpgrade(
            activePair,
            with: plainString,
            at: effectiveRange
        )
        let allowCloserSkip = allowMarkerUpgrade == false
            && effectiveRange.length == 0
            && activePair?.marker.hasPrefix(plainString) == true
            && activePair?.closerLocation == effectiveRange.location
        pendingPair = nil
        guard let edit = TypingBehaviors.pairEdit(
            in: string as NSString,
            input: plainString,
            selection: effectiveRange,
            allowMarkerUpgrade: allowMarkerUpgrade,
            allowCloserSkip: allowCloserSkip
        ) else {
            super.insertText(insertString, replacementRange: replacementRange)
            pendingPair = updatedPendingPair(
                activePair,
                afterReplacing: effectiveRange,
                with: plainString
            )
            return
        }

        if edit.replacement.isEmpty == false {
            breakUndoCoalescing()
            let manager = undoManager
            manager?.beginUndoGrouping()
            super.insertText(edit.replacement, replacementRange: edit.range)
            setSelectedRange(edit.selectionAfter)
            manager?.endUndoGrouping()
            breakUndoCoalescing()
        } else {
            breakUndoCoalescing()
            setSelectedRange(edit.selectionAfter)
            breakUndoCoalescing()
            if allowCloserSkip, let activePair {
                let marker = activePair.marker as NSString
                let consumedLength = (plainString as NSString).length
                if consumedLength < marker.length {
                    pendingPair = PendingPair(
                        marker: marker.substring(from: consumedLength),
                        openerLocation: activePair.openerLocation,
                        closerLocation: edit.selectionAfter.location,
                        epoch: editEpoch
                    )
                }
            }
        }
        let markerLength = (plainString as NSString).length
        if allowMarkerUpgrade, let activePair {
            pendingPair = PendingPair(
                marker: activePair.marker + plainString,
                openerLocation: activePair.openerLocation,
                closerLocation: edit.selectionAfter.location,
                epoch: editEpoch
            )
        } else if effectiveRange.length == 0,
                  edit.replacement == plainString + plainString,
                  edit.selectionAfter.location == effectiveRange.location + markerLength
        {
            pendingPair = PendingPair(
                marker: plainString,
                openerLocation: effectiveRange.location,
                closerLocation: edit.selectionAfter.location,
                epoch: editEpoch
            )
        }
    }

    /// Consecutive marker input upgrades only the empty pair Muse just opened.
    /// `*|*` has one supported upgrade (`**|**`); backtick runs may grow to any
    /// length so code spans can safely contain shorter backtick runs.
    private func canUpgrade(
        _ pair: PendingPair?,
        with input: String,
        at range: NSRange
    ) -> Bool {
        guard let pair,
              range.length == 0,
              range.location == pair.closerLocation,
              pair.closerLocation == pair.openerLocation + (pair.marker as NSString).length
        else { return false }

        if input == "*" { return pair.marker == "*" }
        if input == "`" { return pair.marker.allSatisfy { $0 == "`" } }
        return false
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard hasMarkedText() == false,
              selectedRanges.count == 1,
              selection.length == 0,
              let pair = pendingPair,
              pair.epoch == editEpoch
        else {
            super.deleteBackward(sender)
            return
        }

        let markerLength = (pair.marker as NSString).length
        let pairRange = NSRange(location: pair.openerLocation, length: markerLength * 2)
        guard selection.location == pair.closerLocation,
              pair.closerLocation == pair.openerLocation + markerLength,
              NSMaxRange(pairRange) <= (string as NSString).length
        else {
            super.deleteBackward(sender)
            return
        }

        pendingPair = nil
        guard let textStorage,
              shouldChangeText(in: pairRange, replacementString: "")
        else { return }

        let deletedPair = textStorage.attributedSubstring(from: pairRange)
        breakUndoCoalescing()
        let manager = undoManager
        manager?.beginUndoGrouping()
        manager?.registerUndo(withTarget: self) { textView in
            textView.insertText(
                deletedPair,
                replacementRange: NSRange(location: pairRange.location, length: 0)
            )
            textView.setSelectedRange(NSRange(location: pair.closerLocation, length: 0))
        }
        textStorage.replaceCharacters(in: pairRange, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: pair.openerLocation, length: 0))
        manager?.endUndoGrouping()
        breakUndoCoalescing()
    }

    private func updatedPendingPair(
        _ pair: PendingPair?,
        afterReplacing range: NSRange,
        with replacement: String
    ) -> PendingPair? {
        guard let pair,
              range.length == 0,
              range.location >= pair.openerLocation + (pair.marker as NSString).length,
              range.location <= pair.closerLocation
        else { return nil }

        let closerLocation = pair.closerLocation + (replacement as NSString).length
        let source = string as NSString
        let closerRange = NSRange(location: closerLocation, length: (pair.marker as NSString).length)
        guard NSMaxRange(closerRange) <= source.length,
              source.substring(with: closerRange) == pair.marker
        else { return nil }
        return PendingPair(
            marker: pair.marker,
            openerLocation: pair.openerLocation,
            closerLocation: closerLocation,
            epoch: editEpoch
        )
    }

    /// Enter. Owning the command here rather than in the delegate's
    /// `doCommandBy` hook means every host of this view gets list continuation,
    /// and the production entry point is the one the tests drive.
    override func insertNewline(_ sender: Any?) {
        guard performSmartNewline() else {
            super.insertNewline(sender)
            return
        }
    }

    /// ⌃Return. `NSTextView`'s implementation inserts `NSLineSeparatorCharacter`
    /// (U+2028, verified) — cmark does not treat that as a line break and
    /// `MuseDocument` writes it straight back to disk, so redirect it to a plain
    /// newline. No list continuation: ⌃Return and ⌥Return are the deliberate
    /// escape hatch for "just give me a clean newline".
    override func insertLineBreak(_ sender: Any?) {
        insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Whether a mouse event should be considered for a checkbox toggle at all.
    ///
    /// Split out from `mouseDown` so it can be tested directly: driving the full
    /// `mouseDown` for a rejected event reaches `super`, which starts AppKit's
    /// mouse-tracking loop and blocks waiting for a mouse-up that a unit test
    /// never sends.
    ///
    /// Only the chords that change what a click means are excluded. Testing
    /// `flags.isEmpty` over `deviceIndependentFlagsMask` (0xFFFF0000) instead
    /// also demands Caps Lock, fn, the numeric keypad and the reserved high bits
    /// all be clear — Caps Lock alone was silently swallowing every click.
    static func isCheckboxToggleCandidate(_ event: NSEvent) -> Bool {
        let blockingChords: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return event.type == .leftMouseDown
            && event.clickCount == 1
            && event.modifierFlags.isDisjoint(with: blockingChords)
    }

    override func mouseDown(with event: NSEvent) {
        pendingPair = nil
        let point = convert(event.locationInWindow, from: nil)
        if Self.isCheckboxToggleCandidate(event),
           hasMarkedText() == false,
           isEditable,
           taskCheckboxToggleRange(at: point) != nil
        {
            // Focus first, then edit. The old order evaluated the toggle inside the
            // `if` condition and only became first responder afterwards, so a
            // focusing click arriving from the sidebar mutated the document while
            // the view was not even the responder.
            window?.makeFirstResponder(self)
            if toggleTaskCheckbox(at: point) { return }
        }
        if Self.isCheckboxToggleCandidate(event),
           hasMarkedText() == false,
           let destination = imageDestination(at: point)
        {
            window?.makeFirstResponder(self)
            showImagePreview(destination: destination, at: point)
            return
        }
        super.mouseDown(with: event)
    }

    /// Standard text replacement for the checkbox hit by `point`. The source
    /// length stays unchanged, so the existing selection remains valid.
    @discardableResult
    func toggleTaskCheckbox(at point: CGPoint) -> Bool {
        pendingPair = nil
        guard let range = taskCheckboxToggleRange(at: point) else { return false }
        let current = (string as NSString).substring(with: range)
        guard current == " " || current.lowercased() == "x" else { return false }
        let replacement = current == " " ? "x" : " "
        // `shouldChangeText` 是 AppKit 问「这段文本能不能改」的官方入口：它既覆盖
        // `isEditable`，也把否决权交给 delegate。不要用手写的 isEditable 检查代替，
        // 那只覆盖其中一半。
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }

        let selection = selectedRange()
        breakUndoCoalescing()
        let manager = undoManager
        manager?.beginUndoGrouping()
        super.insertText(replacement, replacementRange: range)
        setSelectedRange(selection)
        manager?.endUndoGrouping()
        breakUndoCoalescing()
        return true
    }

    /// Uses the actual TextKit 2 fragments and the same marker frame as the
    /// renderer. No TextKit 1 layout manager or duplicate hit geometry exists.
    func taskCheckboxToggleRange(at point: CGPoint) -> NSRange? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return nil }

        let containerPoint = CGPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        // 悬挂式 marker 画在容器原点左侧的留白里，点击落点可能解析不到
        // fragment；按同一行带在正文区内重新解析一次，交给 hit frame 精确判定。
        var resolved = layoutManager.textLayoutFragment(for: containerPoint)
        if resolved == nil {
            resolved = layoutManager.textLayoutFragment(for: CGPoint(
                x: (textContainer?.size.width ?? 0) / 2,
                y: containerPoint.y
            ))
        }
        guard let fragment = resolved as? MuseLayoutFragment,
              let target = fragment.taskCheckboxHitTarget(),
              target.frame.contains(containerPoint)
        else { return nil }

        // 只需要元素起点：`offset(from:to:)` 要走一趟内容树，算元素长度是白花的
        // 第二趟——它算出来从未被用到。
        let elementStart = contentManager.offset(
            from: contentManager.documentRange.location,
            to: fragment.rangeInElement.location
        )
        let location = elementStart + target.toggleRange.location
        guard location >= 0, location + target.toggleRange.length <= (self.string as NSString).length else {
            return nil
        }
        return NSRange(location: location, length: target.toggleRange.length)
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
