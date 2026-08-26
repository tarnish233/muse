import AppKit

/// 块级视觉绘制（对标 Typora 的块呈现）。
///
/// 文本属性只能把背景画到字形宽度——引用/代码块要"整行通宽"、引用要有左侧竖线、
/// 分隔线要画真实横线。做法：编辑视图 `draw` 时先于字形绘制块背景/竖线/横线，
/// 行属于哪个块由存储上的 `.museBlock` 属性决定（渲染引擎写入，见 RenderEngine.applyStyle），
/// 与样式状态严格一致：属性应用后区域失效重画，属性被脏带重置后自动恢复无绘制。
/// 只枚举"已布局"的 fragment（= 可视区），不强迫全文档布局；
/// 全路径主线程（AppKit 绘制），缓存无锁。
private var museBlockCache: [Int: String?] = [:]
private var museBlockSignature = 0
private var museBlockHasMarkup: Bool?

enum BlockBackgroundPainter {
    /// 绘制 dirtyRect 内所有块行背景。必须在 super.draw（字形）之前调用。
    static func drawBlockBackgrounds(in dirtyRect: NSRect, textView: NSTextView) {
        guard let layoutManager = textView.textLayoutManager,
              let container = layoutManager.textContainer,
              hasBlockMarkup(textView.textStorage) else { return }

        let origin = textView.textContainerOrigin
        let fullWidth = container.size.width
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: []
        ) { fragment in
            let viewFrame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if viewFrame.minY > dirtyRect.maxY {
                return false // fragment 按文档序枚举：已越过可视区下界
            }
            guard viewFrame.intersects(dirtyRect) else { return true }
            guard let kind = blockKind(of: fragment) else { return true }
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

    // MARK: - 块种类查询（存储属性驱动）

    private static func blockKind(of fragment: NSTextLayoutFragment) -> String? {
        guard let element = fragment.textElement,
              let content = element.textContentManager as? NSTextContentStorage,
              let textStorage = content.textStorage,
              let elementRange = element.elementRange else { return nil }

        if textStorage.length != museBlockSignature {
            museBlockSignature = textStorage.length
            museBlockCache.removeAll()
            museBlockHasMarkup = nil
        }

        // 元素起点 → 文档偏移（NSTextContentStorage 与底层 textStorage 同坐标系）。
        let start = content.documentRange.location
        let offset = content.offset(from: start, to: elementRange.location)
        guard offset != NSNotFound else { return nil }
        if let cached = museBlockCache[offset] {
            return cached
        }
        let kind = textStorage.attribute(.museBlock, at: offset, effectiveRange: nil) as? String
        museBlockCache[offset] = kind
        return kind
    }

    /// 快速探测：文档含任何块标记的引入子串（行首语法；允许假阳性，不允许假阴性）。
    /// 无块标记的文档完全跳过属性读取与 fragment 枚举。
    private static func hasBlockMarkup(_ textStorage: NSTextStorage?) -> Bool {
        guard let textStorage else { return false }
        if textStorage.length != museBlockSignature {
            museBlockSignature = textStorage.length
            museBlockCache.removeAll()
            museBlockHasMarkup = nil
        }
        if let museBlockHasMarkup {
            return museBlockHasMarkup
        }
        let s = textStorage.string
        let found = s.contains(">") || s.contains("```") || s.contains("---")
            || s.contains("***") || s.contains("___")
        museBlockHasMarkup = found
        return found
    }
}
