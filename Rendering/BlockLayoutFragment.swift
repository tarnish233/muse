import AppKit

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

    private var containerWidth: CGFloat? {
        textLayoutManager?.textContainer?.size.width
    }

    // MARK: - 绘制

    private func drawDecoration(kind: String, at point: CGPoint, in context: CGContext) {
        if kind.hasPrefix(BlockVisual.list.rawValue + ":") {
            drawListMarker(kind: kind, at: point, in: context)
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
    private func drawListMarker(kind: String, at point: CGPoint, in context: CGContext) {
        guard let string = elementString, let info = ListMarkerInfo(string) else { return }

        let markerIndex = info.leadingCharacterCount
        guard markerIndex < string.length else { return }
        let font = string.attribute(.font, at: markerIndex, effectiveRange: nil) as? NSFont
        let color = string.attribute(.foregroundColor, at: markerIndex, effectiveRange: nil) as? NSColor
        let isHidden = (font?.pointSize ?? 0) < 1 || color?.alphaComponent == 0
        guard isHidden else { return } // 已回显或尚未渲染，不画

        let palette = BlockVisualPalette.shared.snapshot()
        let glyph = glyphText(kind: kind, info: info) as NSString
        let glyphFont: NSFont = kind.hasSuffix(":t")
            ? NSFont.systemFont(ofSize: 14)
            : NSFont.systemFont(ofSize: 15)
        let glyphSize = glyph.size(withAttributes: [.font: glyphFont])

        // With a near-zero marker the first line's content starts at the
        // fragment origin. Draw the replacement glyph immediately to its left;
        // centering it in the old source-marker band would put it underneath
        // the first content glyph and the subsequent `super.draw` would cover
        // it. The fragment origin already includes the depth's first-line
        // indent, so no extra depth offset is added here.
        let x = point.x - glyphSize.width - 4
        let y = point.y + (layoutFragmentFrame.height - glyphSize.height) / 2

        // fragment 的 CGContext 是左上原点（与文本视图同向）；NSString 绘制需要
        // 一个声明为 flipped 的 NSGraphicsContext，否则字形上下颠倒。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        glyph.draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: glyphFont,
            .foregroundColor: NSColor(cgColor: palette.marker) ?? NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func glyphText(kind: String, info: ListMarkerInfo) -> String {
        if kind.hasSuffix(":t") { return info.checked ? "☑" : "☐" }
        if kind.hasSuffix(":o") {
            // 序号来自 AST，经渲染属性传入；绘制层不重新解析源码。
            return "\(info.number ?? 1)."
        }
        // 无序：层级来自 AST 写入的属性，而不是源码缩进猜测。
        let level = max(1, info.depth)
        return ["•", "◦", "▪"][min(level - 1, 2)]
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
    let leadingCharacterCount: Int
    let indentationUnits: Int
    let leadingWidth: CGFloat
    let markerText: String
    let checked: Bool
    let number: Int?
    let depth: Int

    /// 从元素属性串解析前导空白与 marker 文本；非列表行返回 nil。
    init?(_ string: NSAttributedString) {
        let line = string.string
        var leadingCharacterCount = 0
        var indentationUnits = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
            indentationUnits += line[cursor] == "\t" ? 4 : 1
            leadingCharacterCount += 1
            cursor = line.index(after: cursor)
        }

        let rest = line[cursor...]
        if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") {
            markerText = "- [x] "
            checked = true
        } else if rest.hasPrefix("- [ ] ") {
            markerText = "- [ ] "
            checked = false
        } else if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            markerText = String(rest.prefix(2))
            checked = false
        } else {
            // 有序 "1. "：数字 + ". "
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
            markerText = String(digits) + ". "
            checked = false
        }

        self.leadingCharacterCount = leadingCharacterCount
        self.indentationUnits = indentationUnits
        self.leadingWidth = (String(line.prefix(leadingCharacterCount)) as NSString)
            .size(withAttributes: [.font: Theme.standard.baseFont()]).width
        self.number = (string.attribute(.museListNumber, at: 0, effectiveRange: nil) as? NSNumber)?.intValue
        self.depth = max(1, (string.attribute(.museListDepth, at: 0, effectiveRange: nil) as? NSNumber)?.intValue ?? 1)
    }
}
