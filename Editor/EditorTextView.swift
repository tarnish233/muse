import AppKit
import MuseKit

private struct TableChromeControl: Equatable {
    enum Kind: Equatable {
        case handle(axis: TableDragHandleGeometry.Axis, index: Int)
        case addRow
        case addColumn
    }

    let tableID: Int
    let kind: Kind
    let frame: CGRect
    let itemFrame: CGRect
}

/// 表格 chrome 的几何来自 NSTextView 的文档坐标；覆盖层本身正好铺在
/// `visibleRect` 上，所以这里只需要移除滚动偏移。
///
/// 不要在这里再翻转 Y：`TableChromeOverlayView.isFlipped == true`，AppKit 会让它
/// 的 backing layer 同样使用翻转后的内容坐标。手工执行 `height - y` 会造成二次
/// 翻转，表现就是顶部列手柄被镜像到可视区下方。
nonisolated enum TableChromeCoordinateSpace {
    static func layerRect(for documentRect: CGRect, overlayFrame: CGRect) -> CGRect {
        CGRect(
            x: documentRect.minX - overlayFrame.minX,
            y: documentRect.minY - overlayFrame.minY,
            width: documentRect.width,
            height: documentRect.height
        )
    }
}

/// 表格外沿的交互 chrome。它位于 TextKit fragment 图层之上，但不参与命中；
/// EditorTextView 用同一份几何处理鼠标。未悬停时完全不绘制，行为与 Obsidian 一致。
private final class TableChromeOverlayView: NSView {
    var hoveredControl: TableChromeControl? {
        didSet { updateControl(animated: oldValue != hoveredControl) }
    }
    var activeControl: TableChromeControl? {
        didSet { updateControl(animated: oldValue != activeControl) }
    }

    private let chromeLayer = CALayer()
    private let backgroundLayer = CAShapeLayer()
    private let iconLayer = CAShapeLayer()
    private let dragGhostLayer = CAShapeLayer()
    private let dropIndicatorLayer = CAShapeLayer()
    private var dragGhostFrame: CGRect?
    private var dropIndicatorFrame: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chromeLayer.frame = bounds
        backgroundLayer.frame = bounds
        iconLayer.frame = bounds
        dragGhostLayer.frame = bounds
        dropIndicatorLayer.frame = bounds
        CATransaction.commit()
        updateControl(animated: false)
        updateDragPaths()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateControl(animated: false)
        updateDragPaths()
    }

    func setDragFeedback(ghostFrame: CGRect, dropIndicatorFrame: CGRect) {
        dragGhostFrame = ghostFrame
        self.dropIndicatorFrame = dropIndicatorFrame
        updateDragPaths()
        setOpacity(1, for: dragGhostLayer, duration: 0)
        setOpacity(1, for: dropIndicatorLayer, duration: 0)
    }

    func clearDragFeedback(animated: Bool) {
        let duration = animated && !reduceMotion ? 0.11 : 0
        setOpacity(0, for: dragGhostLayer, duration: duration)
        setOpacity(0, for: dropIndicatorLayer, duration: duration)
        dragGhostFrame = nil
        dropIndicatorFrame = nil
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func configureLayers() {
        wantsLayer = true
        let root = CALayer()
        layer = root

        chromeLayer.opacity = 0
        backgroundLayer.fillColor = NSColor.clear.cgColor
        backgroundLayer.lineJoin = .round
        iconLayer.fillColor = NSColor.clear.cgColor
        iconLayer.strokeColor = NSColor.clear.cgColor
        iconLayer.lineCap = .round
        iconLayer.lineJoin = .round

        dragGhostLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        dragGhostLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor
        dragGhostLayer.lineWidth = 1.5
        dragGhostLayer.lineDashPattern = [5, 3]
        dragGhostLayer.opacity = 0
        dragGhostLayer.shadowColor = NSColor.black.cgColor
        dragGhostLayer.shadowOpacity = 0.10
        dragGhostLayer.shadowRadius = 5
        dragGhostLayer.shadowOffset = CGSize(width: 0, height: 2)

        dropIndicatorLayer.fillColor = NSColor.controlAccentColor.cgColor
        dropIndicatorLayer.opacity = 0
        dropIndicatorLayer.shadowColor = NSColor.controlAccentColor.cgColor
        dropIndicatorLayer.shadowOpacity = 0.28
        dropIndicatorLayer.shadowRadius = 3
        dropIndicatorLayer.shadowOffset = .zero

        chromeLayer.addSublayer(backgroundLayer)
        chromeLayer.addSublayer(iconLayer)
        root.addSublayer(dragGhostLayer)
        root.addSublayer(dropIndicatorLayer)
        root.addSublayer(chromeLayer)
    }

    private func updateControl(animated: Bool) {
        guard let control = activeControl ?? hoveredControl else {
            setOpacity(0, for: chromeLayer, duration: animated && !reduceMotion ? 0.07 : 0)
            return
        }

        let rect = local(control.frame)
        let active = activeControl != nil
        let accent = NSColor.controlAccentColor
        let isAddControl: Bool
        switch control.kind {
        case .addRow, .addColumn: isAddControl = true
        case .handle: isAddControl = false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.path = CGPath(
            roundedRect: rect.insetBy(dx: active ? 1 : 0, dy: active ? 1 : 0),
            cornerWidth: isAddControl ? 0 : 4,
            cornerHeight: isAddControl ? 0 : 4,
            transform: nil
        )
        if active {
            backgroundLayer.fillColor = accent.cgColor
            backgroundLayer.strokeColor = accent.cgColor
            backgroundLayer.lineWidth = 2
        } else if isAddControl {
            backgroundLayer.fillColor = NSColor.clear.cgColor
            backgroundLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.62).cgColor
            backgroundLayer.lineWidth = Theme.tableBorderWidth
        } else {
            // Obsidian 的悬浮手柄不画“按钮盒子”，只显露淡色点阵。
            backgroundLayer.fillColor = NSColor.clear.cgColor
            backgroundLayer.strokeColor = NSColor.clear.cgColor
            backgroundLayer.lineWidth = 0
        }

        let foreground = active ? NSColor.white : NSColor.tertiaryLabelColor
        switch control.kind {
        case let .handle(axis, _):
            iconLayer.path = gripPath(axis: axis, in: rect)
            iconLayer.fillColor = foreground.cgColor
            iconLayer.strokeColor = NSColor.clear.cgColor
            iconLayer.lineWidth = 0
        case .addRow, .addColumn:
            iconLayer.path = plusPath(in: rect)
            iconLayer.fillColor = NSColor.clear.cgColor
            iconLayer.strokeColor = foreground.cgColor
            iconLayer.lineWidth = 1.6
        }
        CATransaction.commit()

        let wasHidden = (chromeLayer.presentation()?.opacity ?? chromeLayer.opacity) < 0.01
        let delay = isAddControl && wasHidden ? 0.08 : 0
        setOpacity(
            1,
            for: chromeLayer,
            duration: animated && !reduceMotion ? (active ? 0.06 : 0.09) : 0,
            delay: delay
        )
    }

    private func gripPath(axis: TableDragHandleGeometry.Axis, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let columns = axis == .column ? 3 : 2
        let rows = axis == .column ? 2 : 3
        let gap: CGFloat = 4.5
        let dot: CGFloat = 2.6
        let width = CGFloat(columns - 1) * gap
        let height = CGFloat(rows - 1) * gap
        for row in 0..<rows {
            for column in 0..<columns {
                let center = CGPoint(
                    x: rect.midX - width / 2 + CGFloat(column) * gap,
                    y: rect.midY - height / 2 + CGFloat(row) * gap
                )
                path.addEllipse(in: CGRect(
                    x: center.x - dot / 2,
                    y: center.y - dot / 2,
                    width: dot,
                    height: dot
                ))
            }
        }
        return path
    }

    private func plusPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let length: CGFloat = 9
        path.move(to: CGPoint(x: rect.midX - length / 2, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX + length / 2, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - length / 2))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + length / 2))
        return path
    }

    private func updateDragPaths() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let dragGhostFrame {
            let rect = local(dragGhostFrame).insetBy(dx: 1, dy: 1)
            dragGhostLayer.path = CGPath(
                roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil
            )
            dragGhostLayer.shadowPath = dragGhostLayer.path
        }
        if let dropIndicatorFrame {
            let rect = local(dropIndicatorFrame)
            dropIndicatorLayer.path = CGPath(
                roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil
            )
        }
        dragGhostLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        dragGhostLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor
        dropIndicatorLayer.fillColor = NSColor.controlAccentColor.cgColor
        dropIndicatorLayer.shadowColor = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
    }

    private func local(_ rect: CGRect) -> CGRect {
        TableChromeCoordinateSpace.layerRect(for: rect, overlayFrame: frame)
    }

    private func setOpacity(
        _ opacity: Float,
        for layer: CALayer,
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0
    ) {
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
        guard duration > 0, abs(current - opacity) > 0.001 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = opacity
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "muse.opacity")
    }
}

/// M1：编辑视图。手工搭建 TextKit 2 栈，把文档的单一 NSTextStorage 挂进编辑面
/// （v0.2 数据所有权边界：EditorBuffer.textStorage 是唯一可变正文）。
/// 禁止代码访问 TextKit 1 的 layoutManager（会把视图打进不可逆的兼容模式）。
final class EditorTextView: NSTextView {
    /// 块级视觉的 fragment 工厂（layoutManager.delegate 是 unowned，需强引用持有）。
    private var fragmentProvider: MuseLayoutFragmentProvider?
    /// App 层接到文档的 RenderCoordinator。返回 true 表示表格已消费按键。
    var tableNavigationHandler: ((Bool) -> Bool)?
    /// 表格内 Return 向下一行同列导航；末行则追加一行。返回 false 时交回普通换行。
    var tableReturnHandler: (() -> Bool)?
    /// 表格单元格边界上的方向键导航；单元格内部返回 false 交还 NSTextView。
    var tableArrowHandler: ((TableArrowDirection) -> Bool)?
    /// Shift+方向键扩展 Obsidian 风格矩形单元格选区。
    var tableSelectionArrowHandler: ((TableArrowDirection) -> Bool)?
    /// 整行/整列拖拽。began 返回 false 时视图放弃接管本次鼠标序列。
    var tableDragHandler: ((TableDragEvent) -> Bool)?
    var tableStructureActionHandler: ((Int, TableStructureAction) -> Bool)?
    var tableSelectionHandler: ((Int, TableSelectionBounds?) -> Bool)?
    var tableCopyHandler: ((NSPasteboard, Bool) -> Bool)?
    var tablePasteHandler: ((NSPasteboard) -> Bool)?
    var tableCurrentSelectionProvider: (() -> (tableID: Int, bounds: TableSelectionBounds)?)?
    var tableDimensionProvider: ((Int) -> (rows: Int, columns: Int)?)?
    /// 非表格选区的系统默认属性。表格选区由 MuseLayoutFragment 按真实字形位置画，
    /// 这里只把 TextKit 那个会受 kern 干扰的背景关掉。
    private var standardSelectedTextAttributes: [NSAttributedString.Key: Any]?
    private var usesCustomTableSelection = false
    private struct ActiveTableDrag {
        let tableID: Int
        let axis: TableDragHandleGeometry.Axis
        let source: Int
        let sourceFrame: CGRect
        let grabOffset: CGFloat
        var destination: Int
        var hasMoved = false
    }
    private var activeTableDrag: ActiveTableDrag?
    private let tableChromeOverlay = TableChromeOverlayView(frame: .zero)
    private var tableTrackingArea: NSTrackingArea?
    private var hoveredTableControl: TableChromeControl?
    private struct TableMenuContext {
        let tableID: Int
        let row: Int
        let column: Int
    }
    private var tableMenuTarget: TableMenuContext?
    private enum TableMenuCommand: Int {
        case rowBefore = 1, rowAfter, rowUp, rowDown, rowDuplicate, rowDelete
        case columnBefore, columnAfter, columnLeft, columnRight, columnDuplicate, columnDelete
        case alignLeft, alignCenter, alignRight, sortAscending, sortDescending
        case clearSelection, deleteSelection
    }

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
        textView.standardSelectedTextAttributes = textView.selectedTextAttributes
        textView.addSubview(textView.tableChromeOverlay, positioned: .above, relativeTo: nil)
        return textView
    }

    func setUsesCustomTableSelection(_ enabled: Bool) {
        guard enabled != usesCustomTableSelection else { return }
        usesCustomTableSelection = enabled
        if enabled {
            if standardSelectedTextAttributes == nil {
                standardSelectedTextAttributes = selectedTextAttributes
            }
            var attributes = standardSelectedTextAttributes ?? selectedTextAttributes
            attributes[.backgroundColor] = NSColor.clear
            selectedTextAttributes = attributes
        } else if let standardSelectedTextAttributes {
            selectedTextAttributes = standardSelectedTextAttributes
        }
        needsDisplay = true
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
        for geometry in tableDragHandleGeometries() {
            addCursorRect(geometry.frame, cursor: .openHand)
        }
        for control in tableChromeControls() {
            switch control.kind {
            case .addRow: addCursorRect(control.frame, cursor: .resizeUpDown)
            case .addColumn: addCursorRect(control.frame, cursor: .resizeLeftRight)
            case .handle: break
            }
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

    /// 可见表格手柄，已转换为 NSTextView 坐标。绘制与命中都由 fragment 提供
    /// 原始几何，因此缩放、字体或列宽变化不会让手柄与表格脱节。
    func tableDragHandleGeometries() -> [TableDragHandleGeometry] {
        guard let layoutManager = textLayoutManager else { return [] }
        let inset = textContainerOrigin
        let visible = visibleRect
        guard !visible.isEmpty else { return [] }
        let topInContainer = visible.minY - inset.y
        guard let first = layoutManager.textLayoutFragment(
            for: CGPoint(x: 0, y: max(0, topInContainer))
        ) else { return [] }

        var result: [TableDragHandleGeometry] = []
        layoutManager.enumerateTextLayoutFragments(
            from: first.rangeInElement.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset.y > visible.maxY { return false }
            guard let fragment = fragment as? MuseLayoutFragment else { return true }
            for geometry in fragment.tableDragHandleGeometries(at: frame.origin) {
                result.append(TableDragHandleGeometry(
                    tableID: geometry.tableID,
                    axis: geometry.axis,
                    index: geometry.index,
                    frame: geometry.frame.offsetBy(dx: inset.x, dy: inset.y),
                    itemFrame: geometry.itemFrame.offsetBy(dx: inset.x, dy: inset.y),
                    isLastRow: geometry.isLastRow
                ))
            }
            return true
        }
        return result
    }

    private func tableChromeControls() -> [TableChromeControl] {
        let handles = tableDragHandleGeometries()
        var controls = handles.map { geometry in
            TableChromeControl(
                tableID: geometry.tableID,
                kind: .handle(axis: geometry.axis, index: geometry.index),
                frame: geometry.frame,
                itemFrame: geometry.itemFrame
            )
        }
        let grouped = Dictionary(grouping: handles, by: \.tableID)
        let thickness = Theme.tableChromeSize
        for (tableID, group) in grouped {
            let columns = group.filter { $0.axis == .column }.sorted { $0.index < $1.index }
            let rows = group.filter { $0.axis == .row }.sorted { $0.index < $1.index }
            guard let firstColumn = columns.first,
                  let lastColumn = columns.last,
                  let lastRow = rows.first(where: \.isLastRow)
            else { continue }
            let tableMinX = firstColumn.itemFrame.minX
            let tableMaxX = lastColumn.itemFrame.maxX
            controls.append(TableChromeControl(
                tableID: tableID,
                kind: .addRow,
                frame: CGRect(
                    x: tableMinX,
                    y: lastRow.itemFrame.maxY,
                    width: tableMaxX - tableMinX,
                    height: thickness
                ),
                itemFrame: lastRow.itemFrame
            ))
            if let firstRow = rows.first {
                controls.append(TableChromeControl(
                    tableID: tableID,
                    kind: .addColumn,
                    frame: CGRect(
                        x: tableMaxX,
                        y: firstRow.itemFrame.minY,
                        width: thickness,
                        height: lastRow.itemFrame.maxY - firstRow.itemFrame.minY
                    ),
                    itemFrame: CGRect(
                        x: tableMinX,
                        y: firstRow.itemFrame.minY,
                        width: tableMaxX - tableMinX,
                        height: lastRow.itemFrame.maxY - firstRow.itemFrame.minY
                    )
                ))
            }
        }
        return controls
    }

    private func syncTableChrome() {
        tableChromeOverlay.frame = visibleRect
        tableChromeOverlay.hoveredControl = hoveredTableControl
        if let drag = activeTableDrag {
            tableChromeOverlay.activeControl = tableChromeControls().first {
                guard $0.tableID == drag.tableID else { return false }
                if case let .handle(axis, index) = $0.kind {
                    return axis == drag.axis && index == drag.source
                }
                return false
            }
        } else if hoveredTableControl == nil,
                  let selection = tableCurrentSelectionProvider?(),
                  let dimensions = tableDimensionProvider?(selection.tableID) {
            let bounds = selection.bounds
            let selectedAxisAndIndex: (TableDragHandleGeometry.Axis, Int)?
            if bounds.minRow == bounds.maxRow,
               bounds.minColumn == 0,
               bounds.maxColumn == dimensions.columns - 1 {
                selectedAxisAndIndex = (.row, bounds.minRow)
            } else if bounds.minColumn == bounds.maxColumn,
                      bounds.minRow == 0,
                      bounds.maxRow == dimensions.rows - 1 {
                selectedAxisAndIndex = (.column, bounds.minColumn)
            } else {
                selectedAxisAndIndex = nil
            }
            tableChromeOverlay.activeControl = selectedAxisAndIndex.flatMap { axis, index in
                tableChromeControls().first {
                    guard $0.tableID == selection.tableID else { return false }
                    if case let .handle(controlAxis, controlIndex) = $0.kind {
                        return controlAxis == axis && controlIndex == index
                    }
                    return false
                }
            }
        } else {
            tableChromeOverlay.activeControl = nil
        }
    }

    private func sourceFrame(
        for control: TableChromeControl,
        axis: TableDragHandleGeometry.Axis
    ) -> CGRect {
        guard axis == .column else { return control.itemFrame }
        let rows = tableDragHandleGeometries().filter {
            $0.tableID == control.tableID && $0.axis == .row
        }
        guard let minY = rows.map(\.itemFrame.minY).min(),
              let maxY = rows.map(\.itemFrame.maxY).max()
        else { return control.itemFrame }
        return CGRect(
            x: control.itemFrame.minX,
            y: minY,
            width: control.itemFrame.width,
            height: maxY - minY
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tableTrackingArea { removeTrackingArea(tableTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tableTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = activeTableDrag == nil
            ? tableChromeControls().last(where: { $0.frame.contains(point) })
            : hoveredTableControl
        guard next != hoveredTableControl else {
            super.mouseMoved(with: event)
            return
        }
        hoveredTableControl = next
        syncTableChrome()
        window?.invalidateCursorRects(for: self)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard activeTableDrag == nil else { return }
        hoveredTableControl = nil
        syncTableChrome()
        super.mouseExited(with: event)
    }

    private func tableCell(at point: CGPoint) -> TableMenuContext? {
        let handles = tableDragHandleGeometries()
        let grouped = Dictionary(grouping: handles, by: \.tableID)
        for (tableID, group) in grouped {
            guard let row = group.first(where: {
                $0.axis == .row && point.y >= $0.itemFrame.minY && point.y <= $0.itemFrame.maxY
            }),
            let column = group.first(where: {
                $0.axis == .column && point.x >= $0.itemFrame.minX && point.x <= $0.itemFrame.maxX
            }),
            point.x >= row.itemFrame.minX, point.x <= row.itemFrame.maxX
            else { continue }
            return TableMenuContext(tableID: tableID, row: row.index, column: column.index)
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let control = tableChromeControls().last(where: { $0.frame.contains(point) })
        let context: TableMenuContext?
        var directAxis: TableDragHandleGeometry.Axis?
        if let control, case let .handle(axis, index) = control.kind {
            directAxis = axis
            let row = axis == .row ? index : 0
            let column = axis == .column ? index : 0
            context = TableMenuContext(tableID: control.tableID, row: row, column: column)
            let dimensions = tableDimensionProvider?(control.tableID)
            let bounds: TableSelectionBounds
            if axis == .row {
                bounds = TableSelectionBounds(
                    minRow: index, maxRow: index,
                    minColumn: 0,
                    maxColumn: max(0, (dimensions?.columns ?? 1) - 1)
                )
            } else {
                bounds = TableSelectionBounds(
                    minRow: 0,
                    maxRow: max(0, (dimensions?.rows ?? 1) - 1),
                    minColumn: index, maxColumn: index
                )
            }
            _ = tableSelectionHandler?(control.tableID, bounds)
        } else {
            context = tableCell(at: point)
        }
        guard let context else { return super.menu(for: event) }
        tableMenuTarget = context

        let menu = NSMenu(title: "表格")
        if let selection = tableCurrentSelectionProvider?(), selection.tableID == context.tableID,
           context.row >= selection.bounds.minRow, context.row <= selection.bounds.maxRow,
           context.column >= selection.bounds.minColumn, context.column <= selection.bounds.maxColumn {
            menu.addItem(menuItem("清空选区", symbol: "eraser", command: .clearSelection))
            menu.addItem(menuItem("删除选区", symbol: "trash", command: .deleteSelection))
            menu.addItem(.separator())
        }

        if directAxis == .row {
            appendRowMenu(to: menu, context: context)
        } else if directAxis == .column {
            appendColumnMenu(to: menu, context: context)
            menu.addItem(.separator())
            appendSortItems(to: menu)
        } else {
            let rowItem = NSMenuItem(title: "行", action: nil, keyEquivalent: "")
            let rowMenu = NSMenu(title: "行")
            appendRowMenu(to: rowMenu, context: context)
            rowItem.submenu = rowMenu
            menu.addItem(rowItem)

            let columnItem = NSMenuItem(title: "列", action: nil, keyEquivalent: "")
            let columnMenu = NSMenu(title: "列")
            appendColumnMenu(to: columnMenu, context: context)
            columnItem.submenu = columnMenu
            menu.addItem(columnItem)
            menu.addItem(.separator())
            appendSortItems(to: menu)
        }
        return menu
    }

    private func appendRowMenu(to menu: NSMenu, context: TableMenuContext) {
        menu.addItem(menuItem("在上方插入行", symbol: "rectangle.tophalf.inset.filled", command: .rowBefore))
        menu.addItem(menuItem("在下方插入行", symbol: "rectangle.bottomhalf.inset.filled", command: .rowAfter))
        menu.addItem(.separator())
        if context.row > 0 { menu.addItem(menuItem("向上移动", symbol: "arrow.up", command: .rowUp)) }
        if context.row < tableLastIndices(tableID: context.tableID).row {
            menu.addItem(menuItem("向下移动", symbol: "arrow.down", command: .rowDown))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("复制行", symbol: "plus.square.on.square", command: .rowDuplicate))
        menu.addItem(menuItem("删除行", symbol: "trash", command: .rowDelete))
    }

    private func appendColumnMenu(to menu: NSMenu, context: TableMenuContext) {
        menu.addItem(menuItem("在左侧插入列", symbol: "rectangle.leadinghalf.inset.filled", command: .columnBefore))
        menu.addItem(menuItem("在右侧插入列", symbol: "rectangle.trailinghalf.inset.filled", command: .columnAfter))
        menu.addItem(.separator())
        if context.column > 0 { menu.addItem(menuItem("向左移动", symbol: "arrow.left", command: .columnLeft)) }
        if context.column < tableLastIndices(tableID: context.tableID).column {
            menu.addItem(menuItem("向右移动", symbol: "arrow.right", command: .columnRight))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("左对齐", symbol: "text.alignleft", command: .alignLeft))
        menu.addItem(menuItem("居中对齐", symbol: "text.aligncenter", command: .alignCenter))
        menu.addItem(menuItem("右对齐", symbol: "text.alignright", command: .alignRight))
        menu.addItem(.separator())
        menu.addItem(menuItem("复制列", symbol: "plus.square.on.square", command: .columnDuplicate))
        menu.addItem(menuItem("删除列", symbol: "trash", command: .columnDelete))
    }

    private func appendSortItems(to menu: NSMenu) {
        menu.addItem(menuItem("升序排列", symbol: "arrow.down", command: .sortAscending))
        menu.addItem(menuItem("降序排列", symbol: "arrow.up", command: .sortDescending))
    }

    private func tableLastIndices(tableID: Int) -> (row: Int, column: Int) {
        if let dimensions = tableDimensionProvider?(tableID) {
            return (max(0, dimensions.rows - 1), max(0, dimensions.columns - 1))
        }
        let handles = tableDragHandleGeometries().filter { $0.tableID == tableID }
        return (
            handles.filter { $0.axis == .row }.map(\.index).max() ?? 0,
            handles.filter { $0.axis == .column }.map(\.index).max() ?? 0
        )
    }

    private func menuItem(
        _ title: String,
        symbol: String,
        command: TableMenuCommand
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performTableMenuCommand(_:)), keyEquivalent: "")
        item.target = self
        item.tag = command.rawValue
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    @objc private func performTableMenuCommand(_ sender: NSMenuItem) {
        guard let context = tableMenuTarget,
              let command = TableMenuCommand(rawValue: sender.tag)
        else { return }
        let action: TableStructureAction
        switch command {
        case .rowBefore: action = .insertRow(index: context.row, copying: nil)
        case .rowAfter: action = .insertRow(index: context.row + 1, copying: nil)
        case .rowUp: action = .moveRow(from: context.row, to: context.row - 1)
        case .rowDown: action = .moveRow(from: context.row, to: context.row + 1)
        case .rowDuplicate: action = .insertRow(index: context.row, copying: context.row)
        case .rowDelete: action = .removeRow(index: context.row)
        case .columnBefore:
            action = .insertColumn(index: context.column, copying: nil, alignmentFrom: context.column)
        case .columnAfter:
            action = .insertColumn(index: context.column + 1, copying: nil, alignmentFrom: context.column)
        case .columnLeft: action = .moveColumn(from: context.column, to: context.column - 1)
        case .columnRight: action = .moveColumn(from: context.column, to: context.column + 1)
        case .columnDuplicate:
            action = .insertColumn(index: context.column, copying: context.column, alignmentFrom: context.column)
        case .columnDelete: action = .removeColumn(index: context.column)
        case .alignLeft: action = .align(columns: context.column...context.column, alignment: .leading)
        case .alignCenter: action = .align(columns: context.column...context.column, alignment: .center)
        case .alignRight: action = .align(columns: context.column...context.column, alignment: .trailing)
        case .sortAscending: action = .sort(column: context.column, direction: .ascending)
        case .sortDescending: action = .sort(column: context.column, direction: .descending)
        case .clearSelection:
            guard let selection = tableCurrentSelectionProvider?(), selection.tableID == context.tableID else { return }
            action = .clear(selection.bounds)
        case .deleteSelection:
            guard let selection = tableCurrentSelectionProvider?(), selection.tableID == context.tableID else { return }
            action = .delete(selection.bounds)
        }
        _ = tableStructureActionHandler?(context.tableID, action)
        hoveredTableControl = nil
        syncTableChrome()
    }

    /// 复选框位置只随「重排」和「滚动」变化，两者都不改文本视图自身的 bounds，
    /// 所以 AppKit 不会自动重算光标区——这里显式失效。
    private func invalidateCheckboxCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        invalidateCheckboxCursorRects()
        syncTableChrome()
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
        window?.acceptsMouseMovedEvents = true
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange() {
        hoveredTableControl = nil
        invalidateCheckboxCursorRects()
        syncTableChrome()
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
        if let selection = tableCurrentSelectionProvider?(),
           tableStructureActionHandler?(
               selection.tableID, .clear(selection.bounds)
           ) == true {
            pendingPair = nil
            return
        }
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
        pendingPair = nil
        if tableReturnHandler?() == true { return }
        guard performSmartNewline() else {
            super.insertNewline(sender)
            return
        }
    }

    /// Obsidian 风格表格导航：Tab 前进，Shift-Tab 后退。非表格位置仍交还 AppKit。
    override func insertTab(_ sender: Any?) {
        pendingPair = nil
        guard tableNavigationHandler?(false) == true else {
            super.insertTab(sender)
            return
        }
    }

    override func insertBacktab(_ sender: Any?) {
        pendingPair = nil
        guard tableNavigationHandler?(true) == true else {
            super.insertBacktab(sender)
            return
        }
    }

    override func moveUp(_ sender: Any?) {
        pendingPair = nil
        guard tableArrowHandler?(.up) == true else {
            super.moveUp(sender)
            return
        }
    }

    override func moveDown(_ sender: Any?) {
        pendingPair = nil
        guard tableArrowHandler?(.down) == true else {
            super.moveDown(sender)
            return
        }
    }

    override func moveLeft(_ sender: Any?) {
        pendingPair = nil
        guard tableArrowHandler?(.left) == true else {
            super.moveLeft(sender)
            return
        }
    }

    override func moveRight(_ sender: Any?) {
        pendingPair = nil
        guard tableArrowHandler?(.right) == true else {
            super.moveRight(sender)
            return
        }
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        pendingPair = nil
        guard tableSelectionArrowHandler?(.up) == true else {
            super.moveUpAndModifySelection(sender)
            return
        }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        pendingPair = nil
        guard tableSelectionArrowHandler?(.down) == true else {
            super.moveDownAndModifySelection(sender)
            return
        }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        pendingPair = nil
        guard tableSelectionArrowHandler?(.left) == true else {
            super.moveLeftAndModifySelection(sender)
            return
        }
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        pendingPair = nil
        guard tableSelectionArrowHandler?(.right) == true else {
            super.moveRightAndModifySelection(sender)
            return
        }
    }

    override func deleteForward(_ sender: Any?) {
        if let selection = tableCurrentSelectionProvider?(),
           tableStructureActionHandler?(
               selection.tableID, .clear(selection.bounds)
           ) == true {
            pendingPair = nil
            return
        }
        super.deleteForward(sender)
    }

    /// ⌃Return. `NSTextView`'s implementation inserts `NSLineSeparatorCharacter`
    /// (U+2028, verified) — cmark does not treat that as a line break and
    /// `MuseDocument` writes it straight back to disk, so redirect it to a plain
    /// newline. No list continuation: ⌃Return and ⌥Return are the deliberate
    /// escape hatch for "just give me a clean newline".
    override func insertLineBreak(_ sender: Any?) {
        insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Whether a mouse event should be considered for a direct marker action.
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
    static func isPlainPrimaryClick(_ event: NSEvent) -> Bool {
        let blockingChords: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return event.type == .leftMouseDown
            && event.clickCount == 1
            && event.modifierFlags.isDisjoint(with: blockingChords)
    }

    override func mouseDown(with event: NSEvent) {
        pendingPair = nil
        let point = convert(event.locationInWindow, from: nil)
        if Self.isPlainPrimaryClick(event),
           hasMarkedText() == false,
           isEditable,
           let control = tableChromeControls().last(where: { $0.frame.contains(point) })
        {
            switch control.kind {
            case .addRow:
                let rows = tableDragHandleGeometries().filter {
                    $0.tableID == control.tableID && $0.axis == .row
                }
                let index = (rows.map(\.index).max() ?? -1) + 1
                window?.makeFirstResponder(self)
                if tableStructureActionHandler?(control.tableID, .insertRow(index: index, copying: nil)) == true {
                    hoveredTableControl = nil
                    syncTableChrome()
                    return
                }
            case .addColumn:
                let columns = tableDragHandleGeometries().filter {
                    $0.tableID == control.tableID && $0.axis == .column
                }
                let index = (columns.map(\.index).max() ?? -1) + 1
                window?.makeFirstResponder(self)
                if tableStructureActionHandler?(control.tableID, .insertColumn(
                    index: index, copying: nil, alignmentFrom: nil
                )) == true {
                    hoveredTableControl = nil
                    syncTableChrome()
                    return
                }
            case let .handle(axis, index):
                let sourceFrame = sourceFrame(for: control, axis: axis)
                let drag = ActiveTableDrag(
                    tableID: control.tableID,
                    axis: axis,
                    source: index,
                    sourceFrame: sourceFrame,
                    grabOffset: axis == .row
                        ? point.y - sourceFrame.minY
                        : point.x - sourceFrame.minX,
                    destination: index
                )
                let accepted = tableDragHandler?(TableDragEvent(
                    phase: .began,
                    tableID: drag.tableID,
                    axis: drag.axis,
                    source: drag.source,
                    destination: drag.destination
                )) == true
                if accepted {
                    window?.makeFirstResponder(self)
                    activeTableDrag = drag
                    tableChromeOverlay.activeControl = control
                    NSCursor.closedHand.set()
                    return
                }
            }
        }
        if event.type == .leftMouseDown,
           event.clickCount == 1,
           event.modifierFlags.contains(.shift),
           let cell = tableCell(at: point),
           let selection = tableCurrentSelectionProvider?(),
           selection.tableID == cell.tableID {
            let bounds = TableSelectionBounds(
                minRow: min(selection.bounds.minRow, cell.row),
                maxRow: max(selection.bounds.maxRow, cell.row),
                minColumn: min(selection.bounds.minColumn, cell.column),
                maxColumn: max(selection.bounds.maxColumn, cell.column)
            )
            window?.makeFirstResponder(self)
            if tableSelectionHandler?(cell.tableID, bounds) == true { return }
        }
        if event.type == .leftMouseDown,
           !event.modifierFlags.contains(.shift),
           let selection = tableCurrentSelectionProvider?() {
            _ = tableSelectionHandler?(selection.tableID, nil)
        }
        if Self.isPlainPrimaryClick(event),
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
        if Self.isPlainPrimaryClick(event),
           hasMarkedText() == false,
           let destination = imageDestination(at: point)
        {
            window?.makeFirstResponder(self)
            showImagePreview(destination: destination, at: point)
            return
        }
        if Self.isPlainPrimaryClick(event),
           hasMarkedText() == false,
           let location = listMarkerCaretLocation(at: point)
        {
            // Ordinary markers are painted outside the native glyph fragment.
            // Letting NSTextView resolve that point can place the caret in the
            // next item; map this small painted area to its own body explicitly.
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: location, length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = activeTableDrag else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let candidates = tableDragHandleGeometries().filter {
            $0.tableID == drag.tableID && $0.axis == drag.axis
        }
        guard let nearest = candidates.min(by: { lhs, rhs in
            let leftDistance: CGFloat
            let rightDistance: CGFloat
            switch drag.axis {
            case .row:
                leftDistance = abs(lhs.itemFrame.midY - point.y)
                rightDistance = abs(rhs.itemFrame.midY - point.y)
            case .column:
                leftDistance = abs(lhs.itemFrame.midX - point.x)
                rightDistance = abs(rhs.itemFrame.midX - point.x)
            }
            return leftDistance < rightDistance
        }) else { return }

        let ghostFrame: CGRect
        let indicatorFrame: CGRect
        switch drag.axis {
        case .row:
            ghostFrame = CGRect(
                x: drag.sourceFrame.minX,
                y: point.y - drag.grabOffset,
                width: drag.sourceFrame.width,
                height: drag.sourceFrame.height
            )
            let y = nearest.index < drag.source ? nearest.itemFrame.minY : nearest.itemFrame.maxY
            indicatorFrame = CGRect(
                x: drag.sourceFrame.minX,
                y: y - 1.5,
                width: drag.sourceFrame.width,
                height: 3
            )
        case .column:
            ghostFrame = CGRect(
                x: point.x - drag.grabOffset,
                y: drag.sourceFrame.minY,
                width: drag.sourceFrame.width,
                height: drag.sourceFrame.height
            )
            let x = nearest.index < drag.source ? nearest.itemFrame.minX : nearest.itemFrame.maxX
            indicatorFrame = CGRect(
                x: x - 1.5,
                y: drag.sourceFrame.minY,
                width: 3,
                height: drag.sourceFrame.height
            )
        }
        drag.hasMoved = true
        tableChromeOverlay.setDragFeedback(
            ghostFrame: ghostFrame,
            dropIndicatorFrame: indicatorFrame
        )

        guard nearest.index != drag.destination else {
            activeTableDrag = drag
            return
        }
        drag.destination = nearest.index
        activeTableDrag = drag
        _ = tableDragHandler?(TableDragEvent(
            phase: .changed,
            tableID: drag.tableID,
            axis: drag.axis,
            source: drag.source,
            destination: drag.destination
        ))
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = activeTableDrag else {
            super.mouseUp(with: event)
            return
        }
        activeTableDrag = nil
        tableChromeOverlay.clearDragFeedback(animated: drag.hasMoved)
        _ = tableDragHandler?(TableDragEvent(
            phase: .ended,
            tableID: drag.tableID,
            axis: drag.axis,
            source: drag.source,
            destination: drag.destination
        ))
        NSCursor.arrow.set()
        syncTableChrome()
        window?.invalidateCursorRects(for: self)
    }

    override func cancelOperation(_ sender: Any?) {
        guard let drag = activeTableDrag else {
            if let selection = tableCurrentSelectionProvider?(),
               tableSelectionHandler?(selection.tableID, nil) == true {
                hoveredTableControl = nil
                syncTableChrome()
                return
            }
            super.cancelOperation(sender)
            return
        }
        activeTableDrag = nil
        tableChromeOverlay.clearDragFeedback(animated: drag.hasMoved)
        _ = tableDragHandler?(TableDragEvent(
            phase: .cancelled,
            tableID: drag.tableID,
            axis: drag.axis,
            source: drag.source,
            destination: drag.destination
        ))
        NSCursor.arrow.set()
        syncTableChrome()
    }

    override func copy(_ sender: Any?) {
        if tableCopyHandler?(NSPasteboard.general, false) == true { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if tableCopyHandler?(NSPasteboard.general, true) == true { return }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        if tablePasteHandler?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard let source = pasteboard.string(forType: .string) else {
            return super.readSelection(from: pasteboard, type: type)
        }
        let replacement = MuseDocument.LineEnding.normalizeToLF(source)
        let range = selectedRange()
        super.insertText(replacement, replacementRange: range)
        return true
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
        // 悬挂式 marker 位于正文 fragment 左侧。TextKit 对这个点有时会返回垂直
        // 距离更近的前一段（而不是 nil）；只在 nil 时回退会导致段落后的首个 Todo
        // 看得见却点不中。先验实际落点，再始终用同一 y 的正文列复核一次。
        let direct = layoutManager.textLayoutFragment(for: containerPoint)
        let lineProbe = layoutManager.textLayoutFragment(for: CGPoint(
            x: (textContainer?.size.width ?? 0) / 2,
            y: containerPoint.y
        ))
        let candidates = [direct, lineProbe].compactMap { $0 as? MuseLayoutFragment }
        guard let match = candidates.lazy.compactMap({ fragment -> (MuseLayoutFragment, (frame: CGRect, toggleRange: NSRange))? in
            guard let target = fragment.taskCheckboxHitTarget(),
                  target.frame.contains(containerPoint) else { return nil }
            return (fragment, target)
        }).first else { return nil }
        let (fragment, target) = match

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

    /// Source location for a click on a rendered unordered/ordered marker.
    /// Task markers remain controls and are handled by `toggleTaskCheckbox`.
    func listMarkerCaretLocation(at point: CGPoint) -> Int? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return nil }

        let containerPoint = CGPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let direct = layoutManager.textLayoutFragment(for: containerPoint)
        let lineProbe = layoutManager.textLayoutFragment(for: CGPoint(
            x: (textContainer?.size.width ?? 0) / 2,
            y: containerPoint.y
        ))
        let candidates = [direct, lineProbe].compactMap { $0 as? MuseLayoutFragment }
        guard let match = candidates.lazy.compactMap({ fragment -> (MuseLayoutFragment, Int)? in
            guard let target = fragment.listMarkerHitTarget(),
                  target.frame.contains(containerPoint) else { return nil }
            return (fragment, target.contentOffset)
        }).first else { return nil }

        let (fragment, contentOffset) = match
        let elementStart = contentManager.offset(
            from: contentManager.documentRange.location,
            to: fragment.rangeInElement.location
        )
        let location = elementStart + contentOffset
        guard location >= 0, location <= (string as NSString).length else { return nil }
        return location
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
