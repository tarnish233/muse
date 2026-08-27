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
nonisolated final class MuseLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        drawBlockVisuals(at: point, in: context)
        super.draw(at: point, in: context)
    }

    /// 通宽背景/竖线会超出字形包围盒，必须先把渲染面扩到容器宽度，否则被裁掉。
    override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        guard blockKind != nil, let width = textLayoutManager?.textContainer?.size.width else {
            return base
        }
        return base.union(CGRect(x: -layoutFragmentFrame.minX, y: 0,
                                 width: width, height: layoutFragmentFrame.height))
    }

    /// 只画块视觉、不画字形。生产路径由 `draw(at:in:)` 调用；
    /// 测试用它把「块视觉是否落墨」和字形像素分开断言。
    func drawBlockVisuals(at point: CGPoint, in context: CGContext) {
        guard let kind = blockKind else { return }
        drawDecoration(kind: kind, at: point, in: context)
    }

    // MARK: - 块种类（直接读元素自己的属性串，无需回查 storage 偏移）

    private var elementString: NSAttributedString? {
        (textElement as? NSTextParagraph)?.attributedString
    }

    private var blockKind: String? {
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
        let theme = Theme.standard
        // 容器左边缘在本次绘制坐标系里的 x（fragment 可能有段落缩进）。
        let left = point.x - layoutFragmentFrame.minX
        let height = layoutFragmentFrame.height

        context.saveGState()
        switch kind {
        case BlockVisual.quote.rawValue:
            // 整行通宽背景 + 左侧竖线（Typora 引用块视觉）。
            context.setFillColor(theme.quoteBackground.cgColor)
            context.fill(CGRect(x: left, y: point.y, width: width, height: height))
            context.setFillColor(theme.markerText.cgColor)
            context.fill(CGRect(x: left, y: point.y, width: 3, height: height))

        case BlockVisual.codeFence.rawValue:
            // 代码块通宽背景（含开/闭栏行）。
            context.setFillColor(theme.codeBackground.cgColor)
            context.fill(CGRect(x: left, y: point.y, width: width, height: height))

        case BlockVisual.rule.rawValue:
            // 隐形的分隔线行：在间隙中央画真实横线。
            context.setFillColor(theme.borderColor.cgColor)
            context.fill(CGRect(x: left, y: point.y + height / 2 - 0.75, width: width, height: 1.5))

        default:
            break
        }
        context.restoreGState()
    }

    /// 列表图形符号：源码 marker 处于 ghost（隐形但保留宽度）时，在 marker 位置画圆点/序号/复选框。
    /// marker 回显（光标行）时不画——源码标记本体可见。
    private func drawListMarker(kind: String, at point: CGPoint, in context: CGContext) {
        guard let string = elementString, let info = ListMarkerInfo(string) else { return }

        // ghost = 正常字号 + 透明；revealed = 正常字号 + 有颜色；折叠 = 近零字号
        let markerIndex = info.leadingCharacterCount
        guard markerIndex < string.length else { return }
        let font = string.attribute(.font, at: markerIndex, effectiveRange: nil) as? NSFont
        guard (font?.pointSize ?? 0) >= 1 else { return }
        if let color = string.attribute(.foregroundColor, at: markerIndex, effectiveRange: nil) as? NSColor,
           color.cgColor.alpha > 0 {
            return // 已回显，不画
        }

        let theme = Theme.standard
        let bandWidth = (info.markerText as NSString)
            .size(withAttributes: [.font: theme.revealedMarkerFont()]).width
        let glyph = glyphText(kind: kind, info: info) as NSString
        let glyphFont: NSFont = kind.hasSuffix(":t")
            ? NSFont.systemFont(ofSize: 14)
            : NSFont.systemFont(ofSize: 15)
        let glyphSize = glyph.size(withAttributes: [.font: glyphFont])

        let x = point.x + info.leadingWidth + (bandWidth - glyphSize.width) / 2
        let y = point.y + (layoutFragmentFrame.height - glyphSize.height) / 2

        // fragment 的 CGContext 是左上原点（与文本视图同向）；NSString 绘制需要
        // 一个声明为 flipped 的 NSGraphicsContext，否则字形上下颠倒。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        glyph.draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: glyphFont,
            .foregroundColor: theme.markerText,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func glyphText(kind: String, info: ListMarkerInfo) -> String {
        if kind.hasSuffix(":t") { return info.checked ? "☑" : "☐" }
        if kind.hasSuffix(":o") {
            // 序号：取源码数字（"12. " → "12."）
            return String(info.markerText.prefix { $0.isNumber }) + "."
        }
        // 无序：按层级（每 2 个缩进单位一级；tab 按 4 个空格计）。
        let level = info.indentationUnits / 2
        return ["•", "◦", "▪"][min(level, 2)]
    }
}

/// 供 NSTextLayoutManager 生产自定义 fragment（编辑视图装配时挂上）。
nonisolated final class MuseLayoutFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
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
    }
}
