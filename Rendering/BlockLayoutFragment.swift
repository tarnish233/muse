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
    public static let markerGap: CGFloat = 4
    /// The fallback slot used only when a malformed/legacy attributed string
    /// has no paragraph geometry. Production list paragraphs always provide
    /// this width through `headIndent - firstLineHeadIndent`.
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

    /// Optical left bearing of the exact text that AppKit will draw. Aligning
    /// this bound (rather than the advance origin) keeps `1.` and `2.` visually
    /// aligned even when their glyph sidebearings differ.
    public static func inkOriginX(for glyph: ListMarkerGlyph, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph.text,
            attributes: [.font: font]
        ))
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        return bounds.isNull ? 0 : bounds.minX
    }

    public static func frame(
        at fragmentPoint: CGPoint,
        firstLineBaseline: CGFloat,
        glyphSize: CGSize,
        verticalAlignment: VerticalAlignment,
        markerLaneWidth: CGFloat = defaultMarkerLaneWidth,
        markerOriginOffsetX: CGFloat = 0
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
            // `fragmentPoint.x` is the content-column anchor. The marker is
            // left-aligned in the fixed lane immediately before that column,
            // so `1.` and `2.` have the same visible start. Text markers also
            // subtract their measured ink left bearing from the draw origin.
            x: fragmentPoint.x - markerLaneWidth - markerOriginOffsetX,
            y: originY,
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
public nonisolated final class MuseLayoutFragment: NSTextLayoutFragment {
    public override func draw(at point: CGPoint, in context: CGContext) {
        drawBlockVisuals(at: point, in: context)
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
            ? 24
            : 0
        return base.union(CGRect(x: containerLeft - markerExtension, y: 0,
                                 width: width + markerExtension, height: layoutFragmentFrame.height))
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
    public func listMarkerFrame(at point: CGPoint) -> CGRect? {
        guard let glyph = listMarkerGlyph,
              let string = elementString,
              let info = ListMarkerInfo(string),
              let firstLine = textLineFragments.first else {
            return nil
        }

        let markerIndex = info.markerLocation
        guard markerIndex < string.length else { return nil }
        let font = string.attribute(.font, at: markerIndex, effectiveRange: nil) as? NSFont
        let color = string.attribute(.foregroundColor, at: markerIndex, effectiveRange: nil) as? NSColor
        let isHidden = (font?.pointSize ?? 0) < 1 || color?.alphaComponent == 0
        guard isHidden else { return nil }

        let glyphFont = ListMarkerGeometry.font(for: glyph, laneWidth: info.markerLaneWidth)
        let glyphSize = (glyph.text as NSString).size(withAttributes: [.font: glyphFont])
        let contentIndex = min(
            string.length - 1,
            info.markerLocation + info.markerLength
        )
        let bodyFont = string.attribute(.font, at: contentIndex, effectiveRange: nil) as? NSFont
            ?? Theme.standard.baseFont()
        let verticalAlignment: ListMarkerGeometry.VerticalAlignment
        if case .unordered = glyph {
            verticalAlignment = .bodyXHeightCenter(bodyXHeight: bodyFont.xHeight)
        } else {
            verticalAlignment = .textBaseline(markerAscender: glyphFont.ascender)
        }
        let inkOriginX = ListMarkerGeometry.inkOriginX(for: glyph, font: glyphFont)
        let markerOriginOffsetX: CGFloat
        if case .unordered = glyph {
            markerOriginOffsetX = 0
        } else {
            markerOriginOffsetX = inkOriginX
        }
        return ListMarkerGeometry.frame(
            at: point,
            firstLineBaseline: firstLine.glyphOrigin.y,
            glyphSize: glyphSize,
            verticalAlignment: verticalAlignment,
            markerLaneWidth: info.markerLaneWidth,
            markerOriginOffsetX: markerOriginOffsetX
        )
    }

    /// Fixed horizontal slot occupied by this marker. The glyph frame may be
    /// shifted by a measured ink bearing for optical alignment, so callers
    /// that compare ordered/unordered lanes should use this slot explicitly.
    public func listMarkerLaneFrame(at point: CGPoint) -> CGRect? {
        guard let markerFrame = listMarkerFrame(at: point),
              let string = elementString,
              let info = ListMarkerInfo(string) else {
            return nil
        }
        return CGRect(
            x: point.x - info.markerLaneWidth,
            y: markerFrame.minY,
            width: info.markerLaneWidth,
            height: markerFrame.height
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
            // 整行通宽背景 + 左侧竖线（Typora 引用块视觉）。
            context.setFillColor(palette.quoteBackground)
            context.fill(CGRect(x: left, y: point.y, width: width, height: height))
            context.setFillColor(palette.marker)
            context.fill(CGRect(x: left, y: point.y, width: 3, height: height))

        case BlockVisual.codeFence.rawValue:
            // 代码块通宽背景（含开/闭栏行）。
            context.setFillColor(palette.codeBackground)
            context.fill(CGRect(x: left, y: point.y, width: width, height: height))

        case BlockVisual.rule.rawValue:
            // 隐形的分隔线行：在间隙中央画真实横线。
            context.setFillColor(palette.border)
            context.fill(CGRect(x: left, y: point.y + height / 2 - 0.75, width: width, height: 1.5))

        default:
            break
        }
        context.restoreGState()
    }

    /// 列表图形符号：源码 marker 处于 hidden（近零宽）时，在段落 marker 带画圆点/序号/复选框。
    /// marker 回显（光标行）时不画——源码标记本体可见。
    private func drawListMarker(at point: CGPoint, in context: CGContext) {
        guard let glyph = listMarkerGlyph,
              let glyphFrame = listMarkerFrame(at: point) else { return }
        let info = elementString.flatMap { ListMarkerInfo($0) }
        let glyphFont = ListMarkerGeometry.font(
            for: glyph,
            laneWidth: info?.markerLaneWidth ?? ListMarkerGeometry.defaultMarkerLaneWidth
        )
        guard let markerColor = listMarkerColor else { return }

        if case let .unordered(depth) = glyph {
            drawUnorderedMarker(depth: depth, in: glyphFrame, color: markerColor, context: context)
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
        let diameter = min(frame.width, 7)
        let box = CGRect(
            x: frame.midX - diameter / 2,
            y: frame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setFillColor(color)
        context.setStrokeColor(color)
        switch max(1, min(depth, 3)) {
        case 1:
            context.fillEllipse(in: box)
        case 2:
            context.setLineWidth(1.25)
            context.strokeEllipse(in: box.insetBy(dx: 0.625, dy: 0.625))
        default:
            context.fill(CGRect(
                x: frame.midX - min(frame.width, 6) / 2,
                y: frame.midY - min(frame.width, 6) / 2,
                width: min(frame.width, 6),
                height: min(frame.width, 6)
            ))
        }
        context.restoreGState()
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
        let paragraph = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let paragraphLaneWidth = (paragraph?.headIndent ?? 0) - (paragraph?.firstLineHeadIndent ?? 0)
        self.markerLaneWidth = paragraphLaneWidth > 0
            ? paragraphLaneWidth
            : ListMarkerGeometry.defaultMarkerLaneWidth
        self.number = (string.attribute(.museListNumber, at: 0, effectiveRange: nil) as? NSNumber)?.intValue
        self.depth = max(1, (string.attribute(.museListDepth, at: 0, effectiveRange: nil) as? NSNumber)?.intValue ?? 1)
        self.checked = (string.attribute(.museTaskChecked, at: 0, effectiveRange: nil) as? NSNumber)?.boolValue ?? false
    }
}
