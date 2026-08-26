import AppKit

/// 块级视觉标记：渲染引擎把它作为自定义属性写入整行/整块范围，
/// 布局层的 MuseLayoutFragment 据此决定绘制内容（引用竖线、通宽背景、分隔线横线）。
/// 与样式状态严格一致（随属性应用写、随脏带重置清）。
enum BlockVisual: String {
    case quote
    case codeFence
    case rule
    /// 列表（含任务）：值带后缀 ":u"（无序）/":o"（有序）/":t"（任务）。
    case list
}

extension NSAttributedString.Key {
    static let museBlock = NSAttributedString.Key("museBlock")
}

/// 主题：字体与配色。亮/暗跟随系统外观（动态 NSColor）。
struct Theme {
    let text: NSColor
    let mutedText: NSColor
    let codeText: NSColor
    let codeBackground: NSColor
    let linkColor: NSColor
    let quoteText: NSColor
    let quoteBackground: NSColor
    let markerText: NSColor
    let borderColor: NSColor

    let baseSize: CGFloat = 16

    static let standard = Theme(
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

    func baseFont() -> NSFont { NSFont.systemFont(ofSize: baseSize) }
    func boldFont() -> NSFont { NSFont.systemFont(ofSize: baseSize, weight: .semibold) }

    /// 在既有字体上合并字形特征（如强调嵌套在粗体内时应得到粗斜体，而不是覆盖成斜体）。
    /// NSFontManager.convert 只能可靠地从"基础 face"出发一次性加特征（从中间态再 convert
    /// 会静默丢失特征，如 RegularItalic→加粗 仍返回 RegularItalic），
    /// 因此先剥离粗/斜特征归一化，再一次性加上目标组合。
    func derivedFont(from base: NSFont, adding trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        // 目标组合从原始字体计算；归一化后再一次性应用（从中间态 convert 会静默丢特征）。
        let desired = manager.traits(of: base).union(trait)
        let normalized = manager.convert(
            manager.convert(base, toNotHaveTrait: .boldFontMask),
            toNotHaveTrait: .italicFontMask
        )
        return manager.convert(normalized, toHaveTrait: desired)
    }
    func italicFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: baseSize)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseSize) ?? base
    }
    func titleFont(level: Int) -> NSFont {
        let sizeByLevel: [CGFloat] = [28, 24, 20, 18, 16.5, 16]
        let size = sizeByLevel[max(0, min(level - 1, 5))]
        return NSFont.systemFont(ofSize: size, weight: .bold)
    }
    func codeFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }
    /// marker 隐藏用：近零宽 + 透明。M0 验证项：观察是否产生可见留白。
    func hiddenMarkerFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular) }
    func revealedMarkerFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }

    // MARK: - 段落

    func baseParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        p.paragraphSpacing = 6
        return p
    }

    func headingParagraph(level: Int) -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.paragraphSpacingBefore = level <= 2 ? 12 : 6
        p.paragraphSpacing = 4
        return p
    }

    func quoteParagraph() -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.firstLineHeadIndent = 18
        p.headIndent = 18
        return p
    }

    func listParagraph() -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.paragraphSpacing = 3
        // 悬挂缩进（Typora 视觉）：marker 在行首，换行对齐内容列。
        // 首行从 0 开始（"- " 占据行首），后续行从 24pt 缩进。
        p.firstLineHeadIndent = 0
        p.headIndent = 24
        return p
    }

    func ruleParagraph() -> NSMutableParagraphStyle {
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
