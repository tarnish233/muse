import AppKit

/// 块级视觉绘制（对标 Typora 的块呈现）。
///
/// 文本属性只能把背景画到字形宽度——引用/代码块要"整行通宽"、引用要有左侧竖线、
/// 分隔线要画真实横线、列表要画图形符号（圆点/序号/复选框）。做法：编辑视图 `draw`
/// 时先于字形绘制块视觉元素，行属于哪个块由存储上的 `.museBlock` 属性决定
/// （渲染引擎写入，见 RenderEngine.applyStyle），与样式状态严格一致。
/// 只枚举"已排版"的 fragment（= 可视区），不强迫全文档排版；
/// 全路径主线程（AppKit 绘制），缓存无锁。
private var museBlockCache: [Int: String?] = [:]
private var museListInfoCache: [Int: ListMarkerInfo] = [:]
private var museBlockSignature = 0
private var museBlockHasMarkup: Bool?

enum BlockBackgroundPainter {
    /// 绘制 dirtyRect 内所有块行视觉元素。必须在 super.draw（字形）之前调用。
    static func drawBlockBackgrounds(in dirtyRect: NSRect, textView: NSTextView) {
        guard let layoutManager = textView.textLayoutManager,
              let container = layoutManager.textContainer,
              hasBlockMarkup(textView.textStorage) else { return }

        let origin = textView.textContainerOrigin
        let fullWidth = container.size.width
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout] // 首次绘制时视图尚未为可视区排版：边走边排版；
                                      // 早停条件保证只排到 dirtyRect 底部，不会全文档排版
        ) { fragment in
            let viewFrame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if viewFrame.minY > dirtyRect.maxY {
                return false // fragment 按文档序枚举：已越过可视区下界
            }
            guard viewFrame.intersects(dirtyRect) else { return true }
            guard let kind = blockKind(of: fragment) else { return true }
            if kind.hasPrefix(BlockVisual.list.rawValue + ":") {
                drawListMarker(kind: kind, fragment: fragment, viewFrame: viewFrame, textView: textView)
                return true
            }
            paint(kind: kind, frame: viewFrame, fullWidth: fullWidth)
            return true
        }
    }

    // MARK: - 绘制

    private static func paint(kind: String, frame: NSRect, fullWidth: CGFloat) {
        let theme = Theme.standard
        switch kind {
        case BlockVisual.quote.rawValue:
            // 整行通宽背景 + 左侧竖线（Typora 引用块视觉）。
            theme.quoteBackground.setFill()
            NSBezierPath(rect: NSRect(x: frame.minX, y: frame.minY, width: fullWidth, height: frame.height)).fill()
            theme.markerText.setFill()
            NSBezierPath(rect: NSRect(x: frame.minX, y: frame.minY, width: 3, height: frame.height)).fill()

        case BlockVisual.codeFence.rawValue:
            // 代码块通宽背景（含开/闭栏行）。
            theme.codeBackground.setFill()
            NSBezierPath(rect: NSRect(x: frame.minX, y: frame.minY, width: fullWidth, height: frame.height)).fill()

        case BlockVisual.rule.rawValue:
            // 隐形的分隔线行：在间隙中央画真实横线。
            theme.borderColor.setFill()
            NSBezierPath(rect: NSRect(x: frame.minX,
                                      y: frame.midY - 0.75,
                                      width: fullWidth,
                                      height: 1.5)).fill()

        default:
            break
        }
    }

    /// 列表图形符号：源码 marker 处于 ghost（隐形但保留宽度）时，在 marker 位置画圆点/序号/复选框。
    /// marker 回显（光标行）时不画——源码标记本体可见。
    private static func drawListMarker(kind: String, fragment: NSTextLayoutFragment, viewFrame: NSRect, textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        guard let info = listInfo(for: fragment, textStorage: textStorage) else { return }
        let markerStart = info.offset + info.leadingSpaces
        let font = textStorage.attribute(.font, at: markerStart, effectiveRange: nil) as? NSFont
        // ghost = 正常字号 + 透明；revealed = 正常字号 + 有颜色；折叠 = 近零字号
        guard (font?.pointSize ?? 0) >= 1 else { return }
        let color = textStorage.attribute(.foregroundColor, at: markerStart, effectiveRange: nil) as? NSColor
        if let color, color.cgColor.alpha > 0 { return } // 已回显，不画

        let theme = Theme.standard
        let markerFont = theme.revealedMarkerFont()
        let bandStartX = viewFrame.minX + info.leadingWidth
        let bandWidth = (info.markerText as NSString).size(withAttributes: [.font: markerFont]).width
        let glyph = glyphText(kind: kind, info: info)
        let glyphFont: NSFont = kind.hasSuffix(":t") ? NSFont.systemFont(ofSize: 14) : NSFont.systemFont(ofSize: 15)
        let glyphSize = (glyph as NSString).size(withAttributes: [.font: glyphFont])
        let x = bandStartX + (bandWidth - glyphSize.width) / 2
        let y = viewFrame.minY + (viewFrame.height - glyphSize.height) / 2
        (glyph as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: glyphFont,
            .foregroundColor: theme.markerText,
        ])
    }

    private static func glyphText(kind: String, info: ListMarkerInfo) -> String {
        if kind.hasSuffix(":t") { return info.checked ? "☑" : "☐" }
        if kind.hasSuffix(":o") {
            // 序号：取源码数字（"12. " → "12."）
            let digits = info.markerText.prefix { $0.isNumber }
            return String(digits) + "."
        }
        // 无序：按层级（每 2 空格一级）
        let level = info.leadingSpaces / 2
        return ["•", "◦", "▪"][min(level, 2)]
    }

    // MARK: - 块种类与列表信息（存储属性驱动，按元素缓存）

    private static func blockKind(of fragment: NSTextLayoutFragment) -> String? {
        guard let element = fragment.textElement,
              let content = element.textContentManager as? NSTextContentStorage,
              let textStorage = content.textStorage,
              let elementRange = element.elementRange,
              let offset = elementOffset(content: content, range: elementRange) else { return nil }

        resetIfNeeded(storage: textStorage)
        if let cached = museBlockCache[offset] {
            return cached
        }
        let kind = textStorage.attribute(.museBlock, at: offset, effectiveRange: nil) as? String
        museBlockCache[offset] = kind
        return kind
    }

    private static func listInfo(for fragment: NSTextLayoutFragment, textStorage: NSTextStorage) -> ListMarkerInfo? {
        guard let element = fragment.textElement,
              let content = element.textContentManager as? NSTextContentStorage,
              let elementRange = element.elementRange,
              let elementStart = elementOffset(content: content, range: elementRange) else { return nil }
        // 只处理元素首行（软换行段落只有一个图形符号）
        let fragStart = offset(of: fragment.rangeInElement.location, content: content)
        guard fragStart == elementStart else { return nil }

        resetIfNeeded(storage: textStorage)
        if let cached = museListInfoCache[elementStart] {
            return cached
        }
        guard elementStart < textStorage.length else { return nil }
        let full = textStorage.string as NSString
        let newline = full.range(of: "\n", options: [],
                                 range: NSRange(location: elementStart, length: full.length - elementStart))
        let lineEnd = newline.location == NSNotFound ? full.length : newline.location
        let line = full.substring(with: NSRange(location: elementStart, length: lineEnd - elementStart))

        var spaces = 0
        while spaces < line.count, line[line.index(line.startIndex, offsetBy: spaces)] == " " {
            spaces += 1
        }
        let rest = line[line.index(line.startIndex, offsetBy: spaces)...]
        let markerText: String
        let checked: Bool
        if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") {
            markerText = "- [x] "
            checked = true
        } else if rest.hasPrefix("- [ ] ") {
            markerText = "- [ ] "
            checked = false
        } else if rest.hasPrefix("- ") {
            markerText = "- "
            checked = false
        } else {
            // 有序 "1. "：数字 + ". " 前的整段
            let digits = rest.prefix { $0.isNumber }
            if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
                markerText = String(digits) + ". "
                checked = false
            } else {
                return nil
            }
        }
        let baseFont = Theme.standard.baseFont()
        let leadingWidth = (String(repeating: " ", count: spaces) as NSString)
            .size(withAttributes: [.font: baseFont]).width
        let info = ListMarkerInfo(offset: elementStart, leadingSpaces: spaces, leadingWidth: leadingWidth,
                                  markerText: markerText, checked: checked)
        museListInfoCache[elementStart] = info
        return info
    }

    /// 快速探测：文档含任何块标记的引入子串（行首语法；允许假阳性，不允许假阴性）。
    /// 无块标记的文档完全跳过属性读取与 fragment 枚举。
    private static func hasBlockMarkup(_ textStorage: NSTextStorage?) -> Bool {
        guard let textStorage else { return false }
        resetIfNeeded(storage: textStorage)
        if let museBlockHasMarkup {
            return museBlockHasMarkup
        }
        let s = textStorage.string
        let found = s.contains(">") || s.contains("```") || s.contains("---")
            || s.contains("***") || s.contains("___")
            || s.contains("- [") || s.contains("- ")
        museBlockHasMarkup = found
        return found
    }

    private static func resetIfNeeded(storage: NSTextStorage) {
        guard storage.length != museBlockSignature else { return }
        museBlockSignature = storage.length
        museBlockCache.removeAll()
        museListInfoCache.removeAll()
        museBlockHasMarkup = nil
    }

    private static func elementOffset(content: NSTextContentStorage, range: NSTextRange) -> Int? {
        offset(of: range.location, content: content)
    }

    private static func offset(of location: NSTextLocation, content: NSTextContentStorage) -> Int? {
        let start = content.documentRange.location
        let value = content.offset(from: start, to: location)
        return value == NSNotFound ? nil : value
    }
}

/// 列表行的源码标记信息（供图形符号绘制；按元素偏移缓存）。
private struct ListMarkerInfo {
    let offset: Int
    let leadingSpaces: Int
    let leadingWidth: CGFloat
    let markerText: String
    let checked: Bool
}
