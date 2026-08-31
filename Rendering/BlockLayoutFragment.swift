import AppKit
import CoreText

/// The visual glyph used for a list marker.
///
/// This is deliberately driven by the semantic depth written by `RenderEngine`
/// (`.museListDepth`).  The drawing layer never infers depth from source
/// indentation, which keeps the visual result consistent for tabs, mixed
/// indentation, and AST-normalized lists.
public nonisolated enum ListMarkerGlyph: Equatable, Sendable {
    case unordered(depth: Int)
    case ordered(number: Int)
    case task(checked: Bool)

    public var text: String {
        switch self {
        case let .unordered(depth):
            switch max(1, min(depth, 3)) {
            case 1: return "•"
            case 2: return "◦"
            default: return "▪"
            }
        case let .ordered(number):
            return "\(number)."
        case let .task(checked):
            return checked ? "☑" : "☐"
        }
    }

    public var fontSize: CGFloat {
        if case .task = self { return 14 }
        return 15
    }
}

/// Geometry shared by marker drawing and rendering tests.
///
/// Marker vertical placement follows the first line's real glyph baseline. A
/// line box includes leading above and below the glyphs, so centering a smaller
/// marker font in `typographicBounds` makes its baseline sit visibly too high.
public nonisolated enum ListMarkerGeometry {
    public static let markerGap: CGFloat = 7
    /// System-font metrics describe the baseline accurately, but list markers
    /// are much smaller than a 16pt CJK body glyph. With no optical correction,
    /// their ink reads about 1.5pt lower even though the mathematical baseline
    /// is shared. Apply one common lift so numbers, bullets, and checkboxes sit
    /// on the same visual centerline.
    public static let opticalLift: CGFloat = 1.5
    /// marker 允许占用的最大横向预算：正文列左侧这么宽的一条 lane。
    ///
    /// 它**不是落点**（落点见 `originX`：墨迹右缘紧贴正文列），只用来决定宽 marker
    /// （`100.`）要不要缩字号。必须 ≤ `Theme.listIndentStep`，否则 marker 会越到
    /// 上一层的正文列左边。
    public static let defaultMarkerLaneWidth: CGFloat = 24

    public enum VerticalAlignment: Equatable, Sendable {
        /// Text markers (ordered numbers and task checkboxes) share the body
        /// baseline, using the marker font's ascender to find its top edge.
        case textBaseline(markerAscender: CGFloat)
        /// Vector bullets sit in the visual middle of the body's x-height.
        case bodyXHeightCenter(bodyXHeight: CGFloat)
    }

    /// Keep ordered marker text inside the semantic marker lane. The lane is
    /// derived from paragraph indentation, so long numbers fit without moving
    /// the content column or applying per-digit x offsets.
    public static func font(
        for glyph: ListMarkerGlyph,
        laneWidth: CGFloat,
        gap: CGFloat = markerGap
    ) -> NSFont {
        let preferred = NSFont.systemFont(ofSize: glyph.fontSize)
        let text = glyph.text as NSString
        let measuredWidth: (NSFont) -> CGFloat = { font in
            text.size(withAttributes: [.font: font]).width
        }
        let naturalWidth = measuredWidth(preferred)
        let availableWidth = max(0.1, laneWidth - gap)
        guard naturalWidth > availableWidth, naturalWidth > 0 else {
            return preferred
        }
        // Font hinting means measured glyph advances do not scale perfectly
        // linearly with point size. Find the largest font that actually fits
        // the lane instead of trusting a one-shot proportional estimate.
        var lowerSize: CGFloat = 0.1
        var upperSize = preferred.pointSize
        for _ in 0..<16 {
            let candidateSize = (lowerSize + upperSize) / 2
            let candidate = NSFont.systemFont(ofSize: candidateSize)
            if measuredWidth(candidate) <= availableWidth {
                lowerSize = candidateSize
            } else {
                upperSize = candidateSize
            }
        }
        return NSFont.systemFont(ofSize: lowerSize)
    }

    /// Optical ink bounds of the exact text AppKit will draw, relative to the
    /// draw origin. Positioning by ink (rather than by the advance box) is what
    /// keeps `1.` and `2.` optically aligned when their sidebearings differ.
    /// Null for a glyph with no ink — callers fall back to the advance box.
    public static func inkBounds(for glyph: ListMarkerGlyph, font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph.text,
            attributes: [.font: font]
        ))
        return CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    }

    /// 无序 marker 落的墨不是字形，而是矢量图形（字体回退会把 U+25E6 画成实心点，
    /// 所以圆点/空心圆/方块都自己画）。形状尺寸固定、居中在 advance 盒里，因此
    /// 它的墨迹盒必须从这里算，不能问字体。
    ///
    /// **绘制与几何都只从这一个函数取值**：落点要按墨迹右缘对齐正文列，如果绘制
    /// 层另算一份，marker 就会偏出去（而且偏移量随字号变化，很难看出来）。
    public static func unorderedInkBox(in frame: CGRect, depth: Int) -> CGRect {
        let side = min(frame.width, max(1, min(depth, 3)) == 3 ? 6 : 7)
        return CGRect(
            x: frame.midX - side / 2,
            y: frame.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// 任务复选框的几何（绘制、落点、命中判定共用这一份）。
    ///
    /// 复选框**不是字形**：`☐`/`☑`（U+2610/U+2611）在 AppKit 的字体回退下又细又方，
    /// 圆角、勾形、填充色都不可控。这里自己画圆角矩形，尺寸因此固定，墨迹盒也就
    /// 等于它自己的 advance 盒。
    ///
    /// 三个数值都由 Typora 默认主题的 2x 截图实测：方框 24px、圆角 5px、描边 3px。
    public static let taskCheckboxSide: CGFloat = 12
    /// 圆角半径按边长取比例（5/24），换边长时不必重新量。
    public static let taskCheckboxCornerRadius: CGFloat = taskCheckboxSide * 5 / 24
    public static let taskCheckboxBorderWidth: CGFloat = 1.5

    /// 复选框到正文列的间隔。
    ///
    /// 比圆点/序号的 `markerGap` 宽一点——这不是拍的，是实测：Typora 的复选框到
    /// 文字是 18px（9pt），而圆点到文字是 7.6pt。两者在 CSS 里本来就是不同的盒。
    public static let taskCheckboxGap: CGFloat = 9

    public static let taskCheckboxSize = CGSize(
        width: taskCheckboxSide, height: taskCheckboxSide)

    /// 这种 marker 到正文列的间隔。
    public static func gap(for glyph: ListMarkerGlyph) -> CGFloat {
        if case .task = glyph { return taskCheckboxGap }
        return markerGap
    }

    /// 复选框在 advance 盒里的落位：整盒就是方框本身。
    public static func taskCheckboxBox(in frame: CGRect) -> CGRect {
        let side = min(taskCheckboxSide, min(frame.width, frame.height))
        return CGRect(
            x: frame.midX - side / 2,
            y: frame.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// Horizontal draw origin for a marker.
    ///
    /// marker 的**墨迹右缘**贴在正文列左侧 `gap` 处——也就是 CSS
    /// `list-style-position: outside` 的模型（Typora 的 github.css 就是它）。
    /// lane 只决定「宽到什么程度要缩字号」，不决定落点：所以窄的 `•` 和宽的
    /// `100.` 都紧贴自己的正文，而不是一起左对齐在 lane 起点、让窄 marker 和
    /// 正文之间空出一大截。缩过字号的 marker 墨迹宽度 ≤ `lane - gap`，因此右对齐
    /// 后墨迹左缘天然不会越过 `contentColumn - lane`，无需额外钳制。
    public static func originX(
        contentColumn: CGFloat,
        inkBounds: CGRect,
        advanceWidth: CGFloat,
        gap: CGFloat = markerGap
    ) -> CGFloat {
        let inkRightEdge = inkBounds.isNull ? advanceWidth : inkBounds.maxX
        return contentColumn - gap - inkRightEdge
    }

    public static func frame(
        at fragmentPoint: CGPoint,
        firstLineBaseline: CGFloat,
        glyphSize: CGSize,
        verticalAlignment: VerticalAlignment,
        inkBounds: CGRect = .null,
        gap: CGFloat = markerGap
    ) -> CGRect {
        let baselineY = fragmentPoint.y + firstLineBaseline
        let originY: CGFloat
        switch verticalAlignment {
        case let .textBaseline(markerAscender):
            originY = baselineY - markerAscender
        case let .bodyXHeightCenter(bodyXHeight):
            originY = baselineY - bodyXHeight / 2 - glyphSize.height / 2
        }
        return CGRect(
            // `fragmentPoint.x` is the content-column anchor.
            x: originX(
                contentColumn: fragmentPoint.x,
                inkBounds: inkBounds,
                advanceWidth: glyphSize.width,
                gap: gap
            ),
            y: originY - opticalLift,
            width: glyphSize.width,
            height: glyphSize.height
        )
    }
}

/// 块级视觉绘制（对标 Typora 的块呈现）。
///
/// 文本属性只能把背景画到字形宽度——引用/代码块要「整行通宽」、引用要有左侧竖线、
/// 分隔线要画真实横线、列表要画图形符号（圆点/序号/复选框）。
///
/// 实现路径必须是自定义 `NSTextLayoutFragment`：TextKit 2 的 NSTextView 在
/// layer-backed 时把字形渲染进各 fragment 自己的图层，视图级的 `draw(_:)` /
/// `drawBackground(in:)` 画出的内容会被整片盖掉（实测：连全尺寸红块都不可见）。
/// fragment 的 `draw(at:in:)` 是「和字形同一图层、且在字形之前」的唯一时机窗口。
///
/// 行属于哪个块由文本元素上的 `.museBlock` 属性决定（渲染引擎写入，
/// 见 RenderEngine.applyStyle），与样式状态严格一致。
///
/// 隔离：基类的绘制/度量接口是 nonisolated（AppKit 只在主线程调用它们），
/// 主题为此声明 nonisolated —— 见 Theme。
public nonisolated struct TableDragHandleGeometry: Sendable, Equatable {
    public enum Axis: String, Sendable {
        case row
        case column
    }

    public let tableID: Int
    public let axis: Axis
    public let index: Int
    public let frame: CGRect
    public let itemFrame: CGRect
    public let isLastRow: Bool

    public init(
        tableID: Int,
        axis: Axis,
        index: Int,
        frame: CGRect,
        itemFrame: CGRect,
        isLastRow: Bool = false
    ) {
        self.tableID = tableID
        self.axis = axis
        self.index = index
        self.frame = frame
        self.itemFrame = itemFrame
        self.isLastRow = isLastRow
    }
}

public nonisolated final class MuseLayoutFragment: NSTextLayoutFragment {
    public override func draw(at point: CGPoint, in context: CGContext) {
        drawBlockVisuals(at: point, in: context)
        drawTableDragFeedback(at: point, in: context)
        drawTableSelection(at: point, in: context)
        super.draw(at: point, in: context)
    }

    /// 通宽背景/竖线会超出字形包围盒，必须先把渲染面扩到容器宽度，否则被裁掉。
    public override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        guard blockKind != nil, let width = textLayoutManager?.textContainer?.size.width else {
            return base
        }
        let containerLeft = -layoutFragmentFrame.minX
        // Hidden list markers are drawn immediately before the first content
        // glyph. Extend the fragment surface far enough to the leading side;
        // otherwise TextKit clips the replacement glyph at the normal fragment
        // bounds even though the CGContext draw itself is correct.
        let markerExtension: CGFloat = blockKind?.hasPrefix(BlockVisual.list.rawValue + ":") == true
            ? ListMarkerGeometry.defaultMarkerLaneWidth
            : 0
        var extended = base.union(CGRect(x: containerLeft - markerExtension, y: 0,
                                         width: width + markerExtension, height: layoutFragmentFrame.height))
        // 代码围栏首末行把背景延伸出内边距（与撑出的段落间距互补），
        // 渲染面必须覆盖延伸区，否则延伸部分被裁掉。
        if blockKind == BlockVisual.codeFence.rawValue {
            let role = blockRole ?? ""
            let topPadding: CGFloat = role.contains("open") ? Theme.codeFencePaddingTop : 0
            let bottomPadding: CGFloat = role.contains("close") ? Theme.codeFencePaddingBottom : 0
            if topPadding > 0 || bottomPadding > 0 {
                extended = extended.union(CGRect(
                    x: containerLeft - markerExtension,
                    y: -topPadding,
                    width: width + markerExtension,
                    height: layoutFragmentFrame.height + topPadding + bottomPadding
                ))
            }
        }
        // 块图片：图画在段落撑出的行高里，但 base 只覆盖折叠后的零宽字形，
        // 不扩面的话整张图会被裁成一条线。
        if blockKind == BlockVisual.image.rawValue, let size = imageDisplaySize {
            extended = extended.union(CGRect(
                x: 0,
                y: 0,
                width: max(size.width, 1),
                height: max(layoutFragmentFrame.height, size.height)
            ))
        }
        if blockKind == BlockVisual.table.rawValue,
           let tableWidth = tableColumnBoundaries?.last {
            let topExtension: CGFloat = tableRowIndex == 0 ? 16 : 0
            extended = extended.union(CGRect(
                x: -16,
                y: -topExtension,
                width: tableWidth + 16,
                height: layoutFragmentFrame.height + topExtension
            ))
        }
        return extended
    }

    /// 只画块视觉、不画字形。生产路径由 `draw(at:in:)` 调用；
    /// 测试用它把「块视觉是否落墨」和字形像素分开断言。
    public func drawBlockVisuals(at point: CGPoint, in context: CGContext) {
        guard let kind = blockKind else { return }
        drawDecoration(kind: kind, at: point, in: context)
    }

    // MARK: - 块种类（直接读元素自己的属性串，无需回查 storage 偏移）

    private var elementString: NSAttributedString? {
        (textElement as? NSTextParagraph)?.attributedString
    }

    public var blockKind: String? {
        guard let string = elementString, string.length > 0 else { return nil }
        return string.attribute(.museBlock, at: 0, effectiveRange: nil) as? String
    }

    /// 块内角色（代码围栏首/末行的 "open"/"close"/"open+close"），由渲染引擎写入。
    var blockRole: String? {
        guard let string = elementString, string.length > 0 else { return nil }
        return string.attribute(.museBlockRole, at: 0, effectiveRange: nil) as? String
    }

    /// 表格列边界（相对本行正文起点的 x 偏移），由属性层跨行算好后写入。
    var tableColumnBoundaries: [CGFloat]? {
        guard let string = elementString, string.length > 0,
              let numbers = string.attribute(.museTableColumns, at: 0, effectiveRange: nil) as? [NSNumber]
        else { return nil }
        return numbers.map { CGFloat($0.doubleValue) }
    }

    /// 表格内的行序号（0 为表头）。
    var tableRowIndex: Int? {
        guard let string = elementString, string.length > 0 else { return nil }
        return (string.attribute(.museTableRow, at: 0, effectiveRange: nil) as? NSNumber)?.intValue
    }

    /// 同一张表所有可见行共享的身份（表头源码行号）。
    public var tableIdentifier: Int? {
        guard let string = elementString, string.length > 0 else { return nil }
        return (string.attribute(.museTableID, at: 0, effectiveRange: nil) as? NSNumber)?.intValue
    }

    private var tableDragAxis: TableDragHandleGeometry.Axis? {
        guard let string = elementString, string.length > 0,
              let raw = string.attribute(.museTableDragAxis, at: 0, effectiveRange: nil) as? String
        else { return nil }
        return TableDragHandleGeometry.Axis(rawValue: raw)
    }

    private var tableDragSource: Int? {
        guard let string = elementString, string.length > 0 else { return nil }
        return (string.attribute(.museTableDragSource, at: 0, effectiveRange: nil) as? NSNumber)?.intValue
    }

    private var tableDragDestination: Int? {
        guard let string = elementString, string.length > 0 else { return nil }
        return (string.attribute(.museTableDragDestination, at: 0, effectiveRange: nil) as? NSNumber)?.intValue
    }

    private var tableCellSelection: TableSelectionBounds? {
        guard let string = elementString, string.length > 0,
              let values = string.attribute(.museTableCellSelection, at: 0, effectiveRange: nil) as? [NSNumber],
              values.count == 4
        else { return nil }
        return TableSelectionBounds(
            minRow: values[0].intValue,
            maxRow: values[1].intValue,
            minColumn: values[2].intValue,
            maxColumn: values[3].intValue
        )
    }

    public var isLastTableRow: Bool {
        (blockRole ?? "").contains("close")
    }

    /// 这一行的表格源码是否处于回显态。
    ///
    /// 能画格线的表格，行首必然是折叠掉的结构字符（首格的 `leadingGap` 至少两个
    /// 字符，否则属性层就不会写 `.museTableColumns`），所以行首字体是否近零宽，
    /// 就是显隐状态本身。
    var isTableSourceRevealed: Bool {
        guard let string = elementString, string.length > 0,
              let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return false }
        return font.pointSize >= 1
    }

    /// 块图片解析后的本地路径。
    var imagePath: String? {
        guard let string = elementString, string.length > 0 else { return nil }
        return string.attribute(.museImagePath, at: 0, effectiveRange: nil) as? String
    }

    /// 块图片的目的地字符串（占位框上显示）。
    var imageDestination: String? {
        guard let string = elementString, string.length > 0 else { return nil }
        return string.attribute(.museImageDestination, at: 0, effectiveRange: nil) as? String
    }

    /// 块图片的呈现尺寸，与撑出的行高同源。
    var imageDisplaySize: CGSize? {
        guard let string = elementString, string.length > 0,
              let numbers = string.attribute(.museImageSize, at: 0, effectiveRange: nil) as? [NSNumber],
              numbers.count == 2 else { return nil }
        return CGSize(width: numbers[0].doubleValue, height: numbers[1].doubleValue)
    }

    /// 块图片预览命中与绘制共用同一个图片盒，避免折叠源码字形的窄范围与视觉图像分叉。
    public func imagePreviewHitTarget() -> (destination: String, frame: CGRect)? {
        guard blockKind == BlockVisual.image.rawValue,
              let destination = imageDestination,
              let size = imageDisplaySize
        else { return nil }
        let fragmentFrame = layoutFragmentFrame
        return (
            destination,
            CGRect(
                x: fragmentFrame.minX,
                y: fragmentFrame.minY + max(0, (fragmentFrame.height - size.height) / 2),
                width: size.width,
                height: size.height
            )
        )
    }

    /// Semantic marker glyph for this fragment.  Exposed so tests can inspect
    /// the same decision used by drawing.
    public var listMarkerGlyph: ListMarkerGlyph? {
        guard let kind = blockKind, let string = elementString,
              let info = ListMarkerInfo(string) else { return nil }
        return markerGlyph(kind: kind, info: info)
    }

    /// Appearance-resolved color selected for this marker. Task markers use an
    /// accent for the checked state and a contrasting label color for the empty
    /// outline; ordinary list markers retain the neutral marker color.
    public var listMarkerColor: CGColor? {
        guard let glyph = listMarkerGlyph else { return nil }
        return color(for: glyph)
    }

    private func color(for glyph: ListMarkerGlyph) -> CGColor? {
        let palette = BlockVisualPalette.shared.snapshot()
        switch glyph {
        case .task(checked: true): return palette.checkboxChecked
        case .task(checked: false): return palette.checkboxUnchecked
        default: return palette.marker
        }
    }

    /// The actual bounds used for a hidden marker glyph, in the same coordinate
    /// system as `draw(at:in:)`.  Keeping this calculation here makes the
    /// rendering geometry follow the first visual line's baseline rather than a
    /// paragraph-height or line-box-center heuristic.
    /// 一次解析出这个 fragment 的 marker 几何。
    ///
    /// 每个入口只构造一次 `ListMarkerInfo`（每次 init 要做 6 次属性查找）、只调一次
    /// `ListMarkerGeometry.font`（对宽字形要走 16 轮二分，每轮分配 NSFont 并度量）。
    /// 改这条路之前实测 `listMarkerFrame` 单次 33.6µs，而 `drawListMarker` 传递性地
    /// 把 `ListMarkerInfo` 构造 5 次、`font` 调 2 次。
    ///
    /// 刻意**不做跨调用缓存**：`isHidden` 依赖的 font/color 属性每次光标移动都翻转，
    /// 而实测 `elementString` 的对象身份也不跨光标移动保持（marker 显隐会重建文本
    /// 元素），所以按身份做键的缓存在重绘时命中率为零，只剩失效风险。
    private struct ResolvedMarker {
        let glyph: ListMarkerGlyph
        let string: NSAttributedString
        let info: ListMarkerInfo
        let glyphFont: NSFont
        let glyphSize: CGSize
        let verticalAlignment: ListMarkerGeometry.VerticalAlignment
        let inkBounds: CGRect
    }

    private func resolvedMarker() -> ResolvedMarker? {
        guard let kind = blockKind,
              let string = elementString,
              let info = ListMarkerInfo(string),
              let glyph = markerGlyph(kind: kind, info: info) else {
            return nil
        }

        let markerIndex = info.markerLocation
        guard markerIndex < string.length else { return nil }
        // 显隐每次光标移动都翻转，必须每次重算——只有两次属性读，便宜且永远正确。
        let font = string.attribute(.font, at: markerIndex, effectiveRange: nil) as? NSFont
        let color = string.attribute(.foregroundColor, at: markerIndex, effectiveRange: nil) as? NSColor
        guard (font?.pointSize ?? 0) < 1 || color?.alphaComponent == 0 else { return nil }

        let glyphFont = ListMarkerGeometry.font(for: glyph, laneWidth: info.markerLaneWidth)
        let bodyFont = firstVisibleBodyFont(
            in: string,
            after: info.markerLocation + info.markerLength
        ) ?? Theme.standard.baseFont()

        let glyphSize: CGSize
        let verticalAlignment: ListMarkerGeometry.VerticalAlignment
        let inkBounds: CGRect
        switch glyph {
        case let .unordered(depth):
            glyphSize = (glyph.text as NSString).size(withAttributes: [.font: glyphFont])
            verticalAlignment = .bodyXHeightCenter(bodyXHeight: bodyFont.xHeight)
            // 矢量图形，不是字形：墨迹盒按绘制层用的同一份几何算。
            inkBounds = ListMarkerGeometry.unorderedInkBox(
                in: CGRect(origin: .zero, size: glyphSize),
                depth: depth
            )
        case .task:
            // 同样是矢量图形。方框撑满自己的 advance 盒，所以墨迹盒就是整盒；
            // 竖直方向对正文 x-height 居中（贴基线会让方框显得偏高）。
            glyphSize = ListMarkerGeometry.taskCheckboxSize
            verticalAlignment = .bodyXHeightCenter(bodyXHeight: bodyFont.xHeight)
            inkBounds = CGRect(origin: .zero, size: glyphSize)
        case .ordered:
            glyphSize = (glyph.text as NSString).size(withAttributes: [.font: glyphFont])
            verticalAlignment = .textBaseline(markerAscender: glyphFont.ascender)
            inkBounds = ListMarkerGeometry.inkBounds(for: glyph, font: glyphFont)
        }

        return ResolvedMarker(
            glyph: glyph,
            string: string,
            info: info,
            glyphFont: glyphFont,
            glyphSize: glyphSize,
            verticalAlignment: verticalAlignment,
            inkBounds: inkBounds
        )
    }

    /// Return the font of the first visible inline run after the list marker.
    ///
    /// A list item may start with hidden Markdown syntax such as `**` or `` ` ``.
    /// Those runs use the 0.1pt marker font, so using the first source character
    /// after `- ` as the body metric pulls the replacement bullet down toward
    /// the baseline. The bullet must instead follow the first text users can
    /// actually see on the line.
    private func firstVisibleBodyFont(
        in string: NSAttributedString,
        after location: Int
    ) -> NSFont? {
        let start = max(0, min(location, string.length))
        guard start < string.length else { return nil }

        var visibleFont: NSFont?
        string.enumerateAttributes(
            in: NSRange(location: start, length: string.length - start),
            options: []
        ) { attributes, _, stop in
            guard let font = attributes[.font] as? NSFont,
                  font.pointSize >= 1 else { return }
            if let color = attributes[.foregroundColor] as? NSColor,
               color.alphaComponent == 0 {
                return
            }
            visibleFont = font
            stop.pointee = true
        }
        return visibleFont
    }

    private func frame(of marker: ResolvedMarker, at point: CGPoint) -> CGRect? {
        guard let firstLine = textLineFragments.first else { return nil }
        return ListMarkerGeometry.frame(
            at: CGPoint(x: point.x + contentOffsetX(of: marker, in: firstLine), y: point.y),
            firstLineBaseline: firstLine.glyphOrigin.y,
            glyphSize: marker.glyphSize,
            verticalAlignment: marker.verticalAlignment,
            inkBounds: marker.inkBounds,
            gap: ListMarkerGeometry.gap(for: marker.glyph)
        )
    }

    /// 从 fragment 原点到**内容列**的水平距离。
    ///
    /// 不能直接把 `point.x` 当内容列：行首的源码缩进被段落样式从行起点里扣掉了
    /// （见 `Theme.listParagraph`——缩进只由语义深度决定），所以 fragment 原点是
    /// 行起点，内容列还要再往右走一段可见前缀的宽度。这里不自己重算前缀宽度，
    /// 而是问第一行「第 0 个字符和 marker 之后第一个字符分别落在哪」，差值就是
    /// 前缀的真实推进量——隐藏态（marker 折叠成 0.1pt）与任何缩进写法下都精确。
    private func contentOffsetX(
        of marker: ResolvedMarker,
        in firstLine: NSTextLineFragment
    ) -> CGFloat {
        let contentStart = marker.info.markerLocation + marker.info.markerLength
        guard contentStart > 0, contentStart <= marker.string.length else { return 0 }
        return firstLine.locationForCharacter(at: contentStart).x
            - firstLine.locationForCharacter(at: 0).x
    }

    public func listMarkerFrame(at point: CGPoint) -> CGRect? {
        guard let marker = resolvedMarker() else { return nil }
        return frame(of: marker, at: point)
    }

    /// 这个 marker 的横向预算槽：正文列左侧宽 `markerLaneWidth` 的一条 lane。
    /// 落点不在槽的左缘（见 `ListMarkerGeometry.originX`），但字号缩放以它为界，
    /// 所以比较「同一深度的有序/无序 marker 是否共用同一预算」要用这个槽。
    public func listMarkerLaneFrame(at point: CGPoint) -> CGRect? {
        guard let marker = resolvedMarker(),
              let markerFrame = frame(of: marker, at: point) else {
            return nil
        }
        return CGRect(
            x: point.x - marker.info.markerLaneWidth,
            y: markerFrame.minY,
            width: marker.info.markerLaneWidth,
            height: markerFrame.height
        )
    }

    /// Click target and body offset for an ordinary rendered list marker.
    ///
    /// The marker is painted outside TextKit's native glyph fragment. Asking
    /// NSTextView to resolve that point can therefore select the next paragraph
    /// (most visibly on the first ordered item). Keep the hit geometry tied to
    /// the same frame used for drawing and place the caret at this item's body.
    public func listMarkerHitTarget() -> (frame: CGRect, contentOffset: Int)? {
        guard let resolved = resolvedMarker() else { return nil }
        if case .task = resolved.glyph { return nil }
        guard let markerFrame = frame(of: resolved, at: layoutFragmentFrame.origin) else {
            return nil
        }
        return (
            frame: markerFrame.insetBy(dx: -3, dy: -2),
            contentOffset: resolved.info.markerLocation + resolved.info.markerLength
        )
    }

    /// Click target and source toggle range for a rendered task checkbox.
    ///
    /// The frame comes from the exact geometry used by drawing. The range is
    /// relative to this fragment's text element and covers only the state
    /// character inside `[ ]`, `[x]`, or `[X]`.
    public func taskCheckboxHitTarget() -> (frame: CGRect, toggleRange: NSRange)? {
        guard let resolved = resolvedMarker(),
              case .task = resolved.glyph,
              let markerFrame = frame(of: resolved, at: layoutFragmentFrame.origin)
        else { return nil }

        let info = resolved.info
        let sourceMarkerRange = NSRange(location: info.markerLocation, length: info.markerLength)
        let marker = resolved.string.string as NSString
        // 一次扫描定位状态框：`[ ]` 与 `[x]/[X]` 互斥，`[xX]` 的大小写不敏感搜索
        // 也能命中 `[ ]` 之外的两种，所以不需要先判断再取值扫两遍。
        var taskRange = marker.range(of: "[ ]", options: [], range: sourceMarkerRange)
        if taskRange.location == NSNotFound {
            taskRange = marker.range(of: "[x]", options: [.caseInsensitive], range: sourceMarkerRange)
        }
        guard taskRange.location != NSNotFound, taskRange.length == 3 else { return nil }

        // Keep the visual glyph easy to click without allowing the entire
        // indentation lane to toggle the task accidentally.
        let hitFrame = markerFrame.insetBy(dx: -3, dy: -2)
        return (
            frame: hitFrame,
            toggleRange: NSRange(location: taskRange.location + 1, length: 1)
        )
    }

    private var containerWidth: CGFloat? {
        textLayoutManager?.textContainer?.size.width
    }

    // MARK: - 绘制

    private func drawDecoration(kind: String, at point: CGPoint, in context: CGContext) {
        if kind.hasPrefix(BlockVisual.list.rawValue + ":") {
            drawListMarker(at: point, in: context)
            return
        }

        guard let width = containerWidth else { return }
        let palette = BlockVisualPalette.shared.snapshot()
        // 容器左边缘在本次绘制坐标系里的 x（fragment 可能有段落缩进）。
        let left = point.x - layoutFragmentFrame.minX
        let height = layoutFragmentFrame.height

        context.saveGState()
        switch kind {
        case BlockVisual.quote.rawValue:
            // 整行通宽背景 + 左侧竖线（对标 Typora：4px 浅灰竖条）。
            context.setFillColor(palette.quoteBackground)
            context.fill(CGRect(x: left, y: point.y, width: width, height: height))
            context.setFillColor(palette.border)
            context.fill(CGRect(x: left, y: point.y, width: 4, height: height))

        case BlockVisual.codeFence.rawValue:
            // 代码块通宽背景。首/末行按块角色把背景延伸出垂直内边距并做
            // 单侧圆角（与 Theme.fenceParagraph 撑出的段落间距互补）。
            let role = blockRole
            let isTop = role?.contains("open") == true
            let isBottom = role?.contains("close") == true
            let topPadding: CGFloat = isTop ? Theme.codeFencePaddingTop : 0
            let bottomPadding: CGFloat = isBottom ? Theme.codeFencePaddingBottom : 0
            let rect = CGRect(
                x: left,
                y: point.y - topPadding,
                width: width,
                height: height + topPadding + bottomPadding
            )
            context.setFillColor(palette.codeBackground)
            if isTop || isBottom {
                let radius = Theme.codeFenceCornerRadius
                context.addPath(Self.roundedPath(
                    rect,
                    topLeft: isTop,
                    topRight: isTop,
                    bottomLeft: isBottom,
                    bottomRight: isBottom,
                    radius: radius
                ))
                context.fillPath()
            } else {
                context.fill(rect)
            }

        case BlockVisual.rule.rawValue:
            // 隐形的分隔线行：在间隙中央画真实横线（Typora：2px 高）。
            context.setFillColor(palette.border)
            context.fill(CGRect(x: left, y: point.y + height / 2 - 1, width: width, height: 2))

        case BlockVisual.table.rawValue:
            drawTable(at: point, in: context, palette: palette, left: left, width: width, height: height)

        case BlockVisual.image.rawValue:
            drawImage(at: point, in: context, palette: palette, left: left, height: height)

        default:
            break
        }
        context.restoreGState()
    }

    /// 表格的一行：底色 + 单元格边框。
    ///
    /// 列边界由属性层算好随行携带（`.museTableColumns`）——列宽是跨行的最大值，
    /// 而 fragment 只看得见自己这一行，没有能力自己算。缺这个属性时（表格无法
    /// 对齐成网格）只画整行弱化底色，不画格线。
    ///
    /// 行盒取 `textLineFragments.first.typographicBounds` 而不是
    /// `layoutFragmentFrame`：末行的段落间距里含表格与下一段的外边距，按 fragment
    /// 画会把下边框拉到表格外面。下内边距是已知量（`tableCellPaddingY`），加回来
    /// 就是单元格的真实高度。
    private func drawTable(
        at point: CGPoint,
        in context: CGContext,
        palette: BlockVisualPaletteSnapshot,
        left: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) {
        let role = blockRole ?? ""
        // 分隔行（`|---|`）在渲染态塌成零高：不画，否则会在表头下留一条色带。
        guard !role.contains("delimiter") else { return }
        // 防御性兼容旧属性或过渡帧：若结构字符意外处于回显态，不叠画第二套格线。
        // 正常的渲染模式会始终折叠表格结构；完整源码只在源码模式显示，而源码模式
        // 本身不会携带 `.museBlock`，因此不会进入这里。
        guard !isTableSourceRevealed else { return }

        let isHead = role.contains("head")
        guard let boundaries = tableColumnBoundaries, boundaries.count >= 2 else {
            context.setFillColor(palette.quoteBackground)
            context.fill(CGRect(x: left, y: point.y, width: width, height: height))
            return
        }
        guard let line = textLineFragments.first else { return }

        let boxTop = point.y + line.typographicBounds.minY
        let boxHeight = line.typographicBounds.height + Theme.tableCellPaddingY
        let available = width - (point.x - left)
        let rect = CGRect(
            x: point.x,
            y: boxTop,
            width: min(boundaries[boundaries.count - 1], available),
            height: boxHeight
        )

        // 底色：表头一档，数据行隔行一档（对标 Typora github.css 的 nth-child(2n)）。
        if isHead {
            context.setFillColor(palette.tableHeaderBackground)
            context.fill(rect)
        } else if let row = tableRowIndex, row % 2 == 0 {
            context.setFillColor(palette.tableStripeBackground)
            context.fill(rect)
        }

        let border = Theme.tableBorderWidth
        context.setFillColor(palette.border)
        // 横线：表头上沿 + 每行下沿（相邻行共用一条，不重复画）。
        if isHead {
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: border))
        }
        context.fill(CGRect(x: rect.minX, y: rect.maxY - border, width: rect.width, height: border))
        // 竖线：每个列边界一条（含最左与最右）。
        for boundary in boundaries {
            let x = min(point.x + boundary, rect.maxX - border)
            guard x >= rect.minX else { continue }
            context.fill(CGRect(x: x, y: rect.minY, width: border, height: rect.height))
        }
    }

    /// 当前 fragment 对应的真实表格行盒。拖拽手柄、命中测试、选中底色与格线
    /// 全部从这里取几何，避免各层各算一套后发生漂移。
    public func tableRowFrame(at point: CGPoint) -> CGRect? {
        guard blockKind == BlockVisual.table.rawValue,
              !isTableSourceRevealed,
              !(blockRole ?? "").contains("delimiter"),
              let line = textLineFragments.first,
              let boundaries = tableColumnBoundaries,
              let tableWidth = boundaries.last,
              tableWidth > 0
        else { return nil }
        return CGRect(
            x: point.x,
            y: point.y + line.typographicBounds.minY,
            width: tableWidth,
            height: line.typographicBounds.height + Theme.tableCellPaddingY
        )
    }

    /// 本行贡献的拖拽手柄。每行有一个左侧行手柄；只有表头贡献顶部列手柄。
    public func tableDragHandleGeometries(at point: CGPoint) -> [TableDragHandleGeometry] {
        guard let tableID = tableIdentifier,
              let row = tableRowIndex,
              let rowFrame = tableRowFrame(at: point),
              let boundaries = tableColumnBoundaries,
              boundaries.count >= 2
        else { return [] }

        let handleThickness = Theme.tableChromeSize
        var result = [TableDragHandleGeometry(
            tableID: tableID,
            axis: .row,
            index: row,
            frame: CGRect(
                x: rowFrame.minX - handleThickness,
                y: rowFrame.minY,
                width: handleThickness,
                height: rowFrame.height
            ),
            itemFrame: rowFrame,
            isLastRow: isLastTableRow
        )]
        guard row == 0 else { return result }

        for column in 0..<(boundaries.count - 1) {
            let item = CGRect(
                x: rowFrame.minX + boundaries[column],
                y: rowFrame.minY,
                width: boundaries[column + 1] - boundaries[column],
                height: rowFrame.height
            )
            result.append(TableDragHandleGeometry(
                tableID: tableID,
                axis: .column,
                index: column,
                frame: CGRect(
                    x: item.minX,
                    y: rowFrame.minY - handleThickness,
                    width: item.width,
                    height: handleThickness
                ),
                itemFrame: item,
                isLastRow: isLastTableRow
            ))
        }
        return result
    }

    /// Obsidian 风格的结构选择与拖拽反馈。手柄本身由 EditorTextView 的顶层 chrome
    /// 按悬停绘制；fragment 只负责必须落在字形下方的单元格底色和边框。
    private func drawTableDragFeedback(at point: CGPoint, in context: CGContext) {
        let handles = tableDragHandleGeometries(at: point)
        guard !handles.isEmpty else { return }

        let accent = NSColor.controlAccentColor
        let axis = tableDragAxis
        let source = tableDragSource
        let row = tableRowIndex
        let rowFrame = tableRowFrame(at: point)
        let boundaries = tableColumnBoundaries

        if let selection = tableCellSelection,
           let row, row >= selection.minRow, row <= selection.maxRow,
           let rowFrame, let boundaries,
           selection.minColumn >= 0, selection.maxColumn + 1 < boundaries.count {
            let rect = CGRect(
                x: rowFrame.minX + boundaries[selection.minColumn],
                y: rowFrame.minY,
                width: boundaries[selection.maxColumn + 1] - boundaries[selection.minColumn],
                height: rowFrame.height
            )
            context.setFillColor(accent.withAlphaComponent(0.10).cgColor)
            context.fill(rect)
            context.setFillColor(accent.cgColor)
            let border: CGFloat = 2
            if row == selection.minRow {
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: border))
            }
            if row == selection.maxRow {
                context.fill(CGRect(x: rect.minX, y: rect.maxY - border, width: rect.width, height: border))
            }
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: border, height: rect.height))
            context.fill(CGRect(x: rect.maxX - border, y: rect.minY, width: border, height: rect.height))
        }

        if let axis, let source, tableDragDestination != nil, let rowFrame {
            switch axis {
            case .row:
                if row == source {
                    context.setFillColor(accent.withAlphaComponent(0.07).cgColor)
                    context.fill(rowFrame)
                }
            case .column:
                if let boundaries, source >= 0, source + 1 < boundaries.count {
                    let selected = CGRect(
                        x: rowFrame.minX + boundaries[source],
                        y: rowFrame.minY,
                        width: boundaries[source + 1] - boundaries[source],
                        height: rowFrame.height
                    )
                    context.setFillColor(accent.withAlphaComponent(0.07).cgColor)
                    context.fill(selected)
                }
            }
        }
    }

    /// 表格选区按行片段的真实字符落点绘制。系统选区使用另一条几何路径，会把
    /// 结构字符上的列对齐 kern 重复计算，第三列的高亮因此漂到表格右边。
    private func drawTableSelection(at point: CGPoint, in context: CGContext) {
        for rect in tableSelectionRects(at: point) {
            context.setFillColor(NSColor.selectedContentBackgroundColor.cgColor)
            context.fill(rect)
        }
    }

    /// 与绘制共用的可观测几何，供回归测试确认高亮留在表格边界内。
    func tableSelectionRects(at point: CGPoint) -> [CGRect] {
        guard blockKind == BlockVisual.table.rawValue,
              let string = elementString,
              let line = textLineFragments.first,
              let boundaries = tableColumnBoundaries,
              let tableWidth = boundaries.last
        else { return [] }

        var rects: [CGRect] = []
        string.enumerateAttribute(
            .museTableSelection,
            in: NSRange(location: 0, length: string.length),
            options: []
        ) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            let start = line.locationForCharacter(at: range.location).x
            let end = line.locationForCharacter(at: NSMaxRange(range)).x
            let left = max(0, min(start, end))
            let right = min(tableWidth, max(start, end))
            guard right > left else { return }
            rects.append(CGRect(
                x: point.x + left,
                y: point.y + line.typographicBounds.minY,
                width: right - left,
                height: line.typographicBounds.height
            ))
        }
        return rects
    }

    /// 块图片：把图画进段落撑出的行高里。
    ///
    /// 图片的呈现尺寸与这一行的 `minimumLineHeight` 是同一个值（属性层写入
    /// `.museImageSize`），所以这里不需要再决定缩放，只做居中定位。
    private func drawImage(
        at point: CGPoint,
        in context: CGContext,
        palette: BlockVisualPaletteSnapshot,
        left: CGFloat,
        height: CGFloat
    ) {
        guard let size = imageDisplaySize else { return }
        let box = CGRect(
            x: point.x,
            y: point.y + max(0, (height - size.height) / 2),
            width: size.width,
            height: size.height
        )

        if let path = imagePath,
           let image = ImageResolver.cachedLocalImage(url: URL(fileURLWithPath: path)) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // 占位框：虚线边 + 目的地文字。比把源码摊回正文更能说明「这里是一张图」。
        context.saveGState()
        context.setStrokeColor(palette.border)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()

        let label = imageDestination ?? ""
        guard !label.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(cgColor: palette.marker) ?? NSColor.secondaryLabelColor,
        ]
        let text = "图片无法加载：\(label)" as NSString
        let textSize = text.size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(
            at: CGPoint(x: box.minX + 12, y: box.midY - textSize.height / 2),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 单侧圆角矩形（左上原点坐标系：minY 是顶边）。radius 不会超过边长的一半。
    private nonisolated static func roundedPath(
        _ rect: CGRect,
        topLeft: Bool,
        topRight: Bool,
        bottomLeft: Bool,
        bottomRight: Bool,
        radius: CGFloat
    ) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - (bottomLeft ? r : 0)))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + (topLeft ? r : 0)))
        if topLeft {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        }
        path.addLine(to: CGPoint(x: rect.maxX - (topRight ? r : 0), y: rect.minY))
        if topRight {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (bottomRight ? r : 0)))
        if bottomRight {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        }
        path.addLine(to: CGPoint(x: rect.minX + (bottomLeft ? r : 0), y: rect.maxY))
        if bottomLeft {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        }
        path.closeSubpath()
        return path
    }

    /// 列表图形符号：源码 marker 处于 hidden（近零宽）时，在段落 marker 带画圆点/序号/复选框。
    /// marker 回显（光标行）时不画——源码标记本体可见。
    private func drawListMarker(at point: CGPoint, in context: CGContext) {
        guard let marker = resolvedMarker(),
              let glyphFrame = frame(of: marker, at: point),
              let markerColor = color(for: marker.glyph) else { return }
        let glyph = marker.glyph
        let glyphFont = marker.glyphFont

        if case let .unordered(depth) = glyph {
            drawUnorderedMarker(depth: depth, in: glyphFrame, color: markerColor, context: context)
            return
        }
        if case let .task(checked) = glyph {
            drawTaskCheckbox(checked: checked, in: glyphFrame, context: context)
            return
        }

        // fragment 的 CGContext 是左上原点（与文本视图同向）；NSString 绘制需要
        // 一个声明为 flipped 的 NSGraphicsContext，否则字形上下颠倒。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (glyph.text as NSString).draw(at: glyphFrame.origin, withAttributes: [
            .font: glyphFont,
            .foregroundColor: NSColor(cgColor: markerColor) ?? NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draw unordered markers as simple vector shapes.  A font fallback can
    /// render U+25E6 (the hollow bullet) as a filled dot; the semantic glyph
    /// remains exposed as "◦" for inspection, while this path guarantees the
    /// second-level marker has an open center on every AppKit font fallback.
    private func drawUnorderedMarker(
        depth: Int,
        in frame: CGRect,
        color: CGColor,
        context: CGContext
    ) {
        let box = ListMarkerGeometry.unorderedInkBox(in: frame, depth: depth)

        context.saveGState()
        context.setFillColor(color)
        context.setStrokeColor(color)
        switch max(1, min(depth, 3)) {
        case 1:
            context.fillEllipse(in: box)
        case 2:
            context.setLineWidth(1.25)
            // 描边向外扩 lineWidth/2，先内缩同样的量，外缘才正好落在 box 上——
            // 落点是按 box 的右缘对齐正文列的。
            context.strokeEllipse(in: box.insetBy(dx: 0.625, dy: 0.625))
        default:
            context.fill(box)
        }
        context.restoreGState()
    }

    /// 任务复选框：自己画圆角方框。
    ///
    /// 三条路都试过，这是唯一对得上 Typora 的：
    /// - `☐`/`☑` 字形：AppKit 字体回退下又细又方，圆角/勾形/填充都不可控；
    /// - 系统控件（`NSButton(checkboxWithTitle:)` 预渲成位图）：macOS 26 把未勾选态
    ///   改成了**实心浅灰圆角块**，而 Typora 里是白底 + 灰描边——因为 WebKit 画
    ///   `input[type=checkbox]` 用的是它自己那套仿平台绘制，并不实例化 NSButton，
    ///   系统控件一改它并不跟；
    /// - 自绘：按 Typora 截图实测的几何与配色画，两边一致。
    ///
    /// 几何取自 `ListMarkerGeometry.taskCheckboxBox`，与落点/命中判定同源。
    private func drawTaskCheckbox(checked: Bool, in frame: CGRect, context: CGContext) {
        let palette = BlockVisualPalette.shared.snapshot()
        let box = ListMarkerGeometry.taskCheckboxBox(in: frame)
        let radius = ListMarkerGeometry.taskCheckboxCornerRadius
        let border = ListMarkerGeometry.taskCheckboxBorderWidth

        context.saveGState()
        defer { context.restoreGState() }

        if checked {
            context.setFillColor(palette.checkboxChecked)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.fillPath()
            drawCheckmark(in: box, context: context)
            return
        }

        // 描边向外扩 lineWidth/2：先内缩同样的量，方框外缘才正好落在 box 上——
        // 落点是按 box 的右缘对齐正文列的。
        let stroked = box.insetBy(dx: border / 2, dy: border / 2)
        context.setStrokeColor(palette.checkboxUnchecked)
        context.setLineWidth(border)
        context.addPath(CGPath(
            roundedRect: stroked,
            cornerWidth: max(0, radius - border / 2),
            cornerHeight: max(0, radius - border / 2),
            transform: nil
        ))
        context.strokePath()
    }

    /// 勾形。坐标是左上原点（与文本视图同向），所以「低点」是 y 更大的那个。
    /// 三个点按方框边长取比例，换尺寸不需要重新调数。
    private func drawCheckmark(in box: CGRect, context: CGContext) {
        let side = box.width
        let start = CGPoint(x: box.minX + side * 0.26, y: box.minY + side * 0.52)
        let elbow = CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.70)
        let end = CGPoint(x: box.minX + side * 0.75, y: box.minY + side * 0.32)

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(1.5, side * 0.13))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: elbow)
        context.addLine(to: end)
        context.strokePath()
    }

    private func markerGlyph(kind: String, info: ListMarkerInfo) -> ListMarkerGlyph? {
        if kind.hasSuffix(":t") { return .task(checked: info.checked) }
        if kind.hasSuffix(":o") {
            // 序号来自 AST，经渲染属性传入；绘制层不重新解析源码。
            return .ordered(number: info.number ?? 1)
        }
        guard kind.hasSuffix(":u") else { return nil }
        // 无序层级来自 AST 写入的属性，而不是源码缩进猜测。
        return .unordered(depth: info.depth)
    }
}

/// 供 NSTextLayoutManager 生产自定义 fragment（编辑视图装配时挂上）。
public nonisolated final class MuseLayoutFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    public override init() {
        super.init()
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        MuseLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// 列表行的源码标记信息（供图形符号绘制）。
nonisolated private struct ListMarkerInfo {
    let markerLocation: Int
    let markerLength: Int
    let markerLaneWidth: CGFloat
    let checked: Bool
    let number: Int?
    let depth: Int

    /// Consume semantic attributes written by RenderEngine. Markdown syntax is
    /// deliberately not reparsed here: swift-markdown already accepted the
    /// exact bullet, checkbox, ordered delimiter, and whitespace variant.
    init?(_ string: NSAttributedString) {
        guard string.length > 0,
              let location = (string.attribute(.museListMarkerLocation, at: 0, effectiveRange: nil) as? NSNumber)?.intValue,
              let length = (string.attribute(.museListMarkerLength, at: 0, effectiveRange: nil) as? NSNumber)?.intValue,
              location >= 0, length > 0, location + length <= string.length else { return nil }
        markerLocation = location
        markerLength = length
        // The lane is a fixed slot in the leading gutter; paragraph indents no
        // longer encode it (the list body column is flush with body text).
        self.markerLaneWidth = ListMarkerGeometry.defaultMarkerLaneWidth
        self.number = (string.attribute(.museListNumber, at: 0, effectiveRange: nil) as? NSNumber)?.intValue
        self.depth = max(1, (string.attribute(.museListDepth, at: 0, effectiveRange: nil) as? NSNumber)?.intValue ?? 1)
        self.checked = (string.attribute(.museTaskChecked, at: 0, effectiveRange: nil) as? NSNumber)?.boolValue ?? false
    }
}
