import AppKit

/// 块级视觉标记：渲染引擎把它作为自定义属性写入整行/整块范围，
/// 布局层的 MuseLayoutFragment 据此决定绘制内容（引用竖线、通宽背景、分隔线横线）。
/// 与样式状态严格一致（随属性应用写、随脏带重置清）。
public enum BlockVisual: String {
    case quote
    case codeFence
    case rule
    /// 列表（含任务）：值带后缀 ":u"（无序）/":o"（有序）/":t"（任务）。
    case list
}

extension NSAttributedString.Key {
    /// nonisolated：块视觉的 fragment（MuseLayoutFragment）在 nonisolated 的
    /// 度量路径（renderingSurfaceBounds）里也要读它。Key 本身是 Sendable。
    public nonisolated static let museBlock = NSAttributedString.Key("museBlock")
    /// AST-provided ordered-list number consumed by the custom layout fragment.
    public nonisolated static let museListNumber = NSAttributedString.Key("museListNumber")
    /// AST-provided list depth consumed by the custom layout fragment.
    public nonisolated static let museListDepth = NSAttributedString.Key("museListDepth")
}

/// 主题：字体与配色。亮/暗跟随系统外观（动态 NSColor）。
///
/// nonisolated + Sendable：块视觉在 `NSTextLayoutFragment` 的 nonisolated
/// 绘制/度量接口里取用主题。NSColor / NSFont 都是不可变且线程安全的，
/// 主题本身只读，跨隔离域读取无竞争。
public nonisolated struct Theme: @unchecked Sendable {
    public let text: NSColor
    public let mutedText: NSColor
    public let codeText: NSColor
    public let codeBackground: NSColor
    public let linkColor: NSColor
    public let quoteText: NSColor
    public let quoteBackground: NSColor
    public let markerText: NSColor
    public let borderColor: NSColor

    public let baseSize: CGFloat = 16

    public static let standard = Theme(
        text: adaptive(light: NSColor(calibratedWhite: 0.13, alpha: 1),
                       dark: NSColor(calibratedWhite: 0.93, alpha: 1)),
        mutedText: adaptive(light: NSColor(calibratedWhite: 0.42, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.62, alpha: 1)),
        codeText: adaptive(light: NSColor(calibratedRed: 0.58, green: 0.25, blue: 0.20, alpha: 1),
                           dark: NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.47, alpha: 1)),
        codeBackground: adaptive(light: NSColor(calibratedWhite: 0.955, alpha: 1),
                                 dark: NSColor(calibratedWhite: 0.16, alpha: 1)),
        linkColor: adaptive(light: NSColor(calibratedRed: 0.17, green: 0.40, blue: 0.72, alpha: 1),
                            dark: NSColor(calibratedRed: 0.50, green: 0.68, blue: 0.95, alpha: 1)),
        quoteText: adaptive(light: NSColor(calibratedWhite: 0.38, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.66, alpha: 1)),
        quoteBackground: adaptive(light: NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1),
                                  dark: NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.19, alpha: 1)),
        markerText: adaptive(light: NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.68, alpha: 0.9),
                             dark: NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.76, alpha: 0.9)),
        borderColor: adaptive(light: NSColor(calibratedWhite: 0.88, alpha: 1),
                              dark: NSColor(calibratedWhite: 0.25, alpha: 1))
    )

    // MARK: - 字体

    public func baseFont() -> NSFont { NSFont.systemFont(ofSize: baseSize) }
    public func boldFont() -> NSFont { NSFont.systemFont(ofSize: baseSize, weight: .semibold) }

    /// 在既有字体上合并字形特征（如强调嵌套在粗体内时应得到粗斜体，而不是覆盖成斜体）。
    /// NSFontManager.convert 只能可靠地从"基础 face"出发一次性加特征（从中间态再 convert
    /// 会静默丢失特征，如 RegularItalic→加粗 仍返回 RegularItalic），
    /// 因此先剥离粗/斜特征归一化，再一次性加上目标组合。
    public func derivedFont(from base: NSFont, adding trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        // 目标组合从原始字体计算；归一化后再一次性应用（从中间态 convert 会静默丢特征）。
        let desired = manager.traits(of: base).union(trait)
        let normalized = manager.convert(
            manager.convert(base, toNotHaveTrait: .boldFontMask),
            toNotHaveTrait: .italicFontMask
        )
        return manager.convert(normalized, toHaveTrait: desired)
    }
    public func italicFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: baseSize)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseSize) ?? base
    }
    public func titleFont(level: Int) -> NSFont {
        let sizeByLevel: [CGFloat] = [28, 24, 20, 18, 16.5, 16]
        let size = sizeByLevel[max(0, min(level - 1, 5))]
        return NSFont.systemFont(ofSize: size, weight: .bold)
    }
    public func codeFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }
    /// marker 隐藏用：近零宽 + 透明。M0 验证项：观察是否产生可见留白。
    public func hiddenMarkerFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular) }
    public func revealedMarkerFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }

    // MARK: - 段落

    public func baseParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        p.paragraphSpacing = 6
        return p
    }

    public func headingParagraph(level: Int) -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.paragraphSpacingBefore = level <= 2 ? 12 : 6
        p.paragraphSpacing = 4
        return p
    }

    public func quoteParagraph() -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.firstLineHeadIndent = 18
        p.headIndent = 18
        return p
    }

    public func listParagraph(depth: Int) -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.paragraphSpacing = 3
        // 悬挂缩进（Typora 视觉）：marker 在行首，换行对齐内容列。
        // 每深入一层，marker 带与内容列都向右移动 24pt。
        let level = max(1, depth)
        p.firstLineHeadIndent = CGFloat(level - 1) * 24
        p.headIndent = CGFloat(level) * 24
        return p
    }

    public func ruleParagraph() -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.paragraphSpacingBefore = 10
        p.paragraphSpacing = 10
        return p
    }

    // MARK: - 工具

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        }
    }
}

/// Fragment 绘制使用的、已经按具体外观解析的颜色。
///
/// `NSTextLayoutFragment` 的绘制回调不保证建立了正确的
/// `NSAppearance.current`，而 TextKit 还可能缓存并复用 fragment。颜色不能在
/// fragment 内直接从动态 `NSColor` 取 `cgColor`，否则外观切换后可能静默回落亮色。
public nonisolated struct BlockVisualPaletteSnapshot: @unchecked Sendable {
    public let quoteBackground: CGColor
    public let codeBackground: CGColor
    public let marker: CGColor
    public let border: CGColor
    /// Accent used for checked task markers.
    public let checkboxChecked: CGColor
    /// Contrasting label color used for the unchecked checkbox outline.
    public let checkboxUnchecked: CGColor
}

/// 块视觉调色板的唯一共享实例。
///
/// fragment 的接口是 nonisolated，读写不能依赖 MainActor；外观变化时替换快照
/// 内容，所有存活 fragment 都会在下一次绘制时读取当前外观的颜色。
public nonisolated final class BlockVisualPalette: @unchecked Sendable {
    public static let shared = BlockVisualPalette()

    private let lock = NSLock()
    private var current: BlockVisualPaletteSnapshot

    private init() {
        let appearance = NSAppearance(named: .aqua)!
        current = Self.snapshot(for: appearance)
    }

    public func snapshot() -> BlockVisualPaletteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func update(for appearance: NSAppearance) {
        let next = Self.snapshot(for: appearance)
        lock.lock()
        current = next
        lock.unlock()
    }

    private static func snapshot(for appearance: NSAppearance) -> BlockVisualPaletteSnapshot {
        let theme = Theme.standard
        return BlockVisualPaletteSnapshot(
            quoteBackground: resolvedCGColor(theme.quoteBackground, for: appearance),
            codeBackground: resolvedCGColor(theme.codeBackground, for: appearance),
            marker: resolvedCGColor(theme.markerText, for: appearance),
            border: resolvedCGColor(theme.borderColor, for: appearance),
            checkboxChecked: resolvedCGColor(NSColor.controlAccentColor, for: appearance),
            checkboxUnchecked: resolvedCGColor(NSColor.secondaryLabelColor, for: appearance)
        )
    }

    private static func resolvedCGColor(_ color: NSColor, for appearance: NSAppearance) -> CGColor {
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved ?? NSColor.black.cgColor
    }
}
