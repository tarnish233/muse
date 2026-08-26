import AppKit
import Testing

/// 渲染层契约：只写属性不改字符；marker 隐藏/回显规则；中文/emoji 区间正确性。
@Suite @MainActor struct RendererTests {
    let engine = RenderEngine()
    let theme = Theme.standard

    private func font(at location: Int, in storage: NSTextStorage) -> NSFont? {
        storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func isHidden(_ location: Int, in storage: NSTextStorage) -> Bool {
        (font(at: location, in: storage)?.pointSize ?? 100) < 1
    }

    /// 字重数值（NSFont.Weight rawValue：regular=0，semibold≈0.3）。
    /// CJK 文本上 AppKit 会把系统字体解析成 PingFang 回退字体（实例不同），
    /// 因此中文位置的断言用字重/字号而不是字体实例相等。
    private func weight(_ font: NSFont?) -> Double {
        let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
    }

    @Test func renderNeverChangesCharacters() {
        let source = "**你好** 与 `code`\n\n- 列表\n"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)
        #expect(storage.string == source)
    }

    @Test func markersHiddenWhenCaretOutside() {
        let source = "**粗**"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        // 光标在文档末尾（内容之外）→ 标记隐藏
        _ = engine.render(package: package, selection: NSRange(location: 5, length: 0), into: storage)

        #expect(isHidden(0, in: storage))
        #expect(isHidden(3, in: storage)) // 闭合标记在 utf16 3..<5
        // 内容为 CJK：AppKit 解析为 PingFang 回退字体，按字重断言
        #expect(font(at: 2, in: storage)?.pointSize == 16)
        #expect(weight(font(at: 2, in: storage)) > 0.1)
    }

    @Test func markersRevealedOnCaretInContent() {
        let source = "**粗**"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        // 光标位于内容中间 → 两个分隔符都回显
        _ = engine.render(package: package, selection: NSRange(location: 2, length: 0), into: storage)

        #expect(font(at: 0, in: storage) == theme.revealedMarkerFont())
        #expect(font(at: 3, in: storage) == theme.revealedMarkerFont()) // 闭合标记在 utf16 3..<5
        #expect(font(at: 2, in: storage)?.pointSize == 16)
        #expect(weight(font(at: 2, in: storage)) > 0.1)
    }

    @Test func blockMarkerRevealedOnCaretLineOnly() {
        let source = "- 第一项\n- 第二项"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        // 光标在第 2 行 → 第二行 marker 显示，第一行隐藏
        _ = engine.render(package: package, selection: NSRange(location: 6, length: 0), into: storage)

        #expect(isHidden(0, in: storage))
        #expect(font(at: 6, in: storage) == theme.revealedMarkerFont()) // 第二行 "- " 起点（utf16）
    }

    @Test func markerVisibilityFollowsSelection() {
        let source = "**粗**\n**另一个**"
        let storage = NSTextStorage(string: source)
        let engine2 = engine
        let package = engine2.prepare(source)
        // 初始：光标在文档末尾（第 2 行）→ 第一行 marker 隐藏
        _ = engine2.render(package: package, selection: NSRange(location: 13, length: 0), into: storage)
        #expect(isHidden(0, in: storage))

        // 选区移到第一行内容 → 只更新显隐，不改字符
        let coordinator = RenderCoordinator()
        coordinator.adoptPackage(package)
        coordinator.updateMarkerVisibility(selection: NSRange(location: 3, length: 0), into: storage)
        #expect(font(at: 0, in: storage) == theme.revealedMarkerFont())
        #expect(storage.string == source)
    }

    @Test func chinesePositionsInRenderedStorage() {
        let source = "你好**世界**"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        // strong token：marker 在 utf8 6..<8 → utf16 2..<4；内容 utf8 8..<14 → utf16 4..<10
        let strong = package.tokens.first { $0.kind == .strong }
        #expect(strong?.markerRange == 6..<8)
        #expect(strong?.contentRange == 8..<14)
        _ = engine.render(package: package, selection: NSRange(location: 6, length: 0), into: storage)

        // 中文前缀没让区间错位：内容（世界）加粗、正文（你好）常规
        #expect(weight(font(at: 4, in: storage)) > 0.1)
        #expect(weight(font(at: 0, in: storage)) < 0.05)
        #expect(isHidden(2, in: storage) == false) // 光标在内容内 → marker 回显
    }

    @Test func headingStyleApplied() {
        let source = "# 一级标题"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        // 标题内容为 CJK → PingFang 回退；按字号 + 字重断言
        let headingFont = font(at: 2, in: storage)
        #expect(headingFont?.pointSize == 28)
        #expect(weight(headingFont) > 0.1)
    }

    @Test func inlineCodeStyled() {
        let source = "`let x = 1`"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        #expect(font(at: 1, in: storage) == theme.codeFont())
        #expect(storage.attribute(.backgroundColor, at: 1, effectiveRange: nil) != nil)
    }

    @Test func codeFenceContentStyled() {
        let source = "```swift\nlet a = 1\n```"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        #expect(font(at: 9, in: storage) == theme.codeFont()) // 第二行（utf16）
        #expect(storage.attribute(.backgroundColor, at: 9, effectiveRange: nil) != nil)
    }

    /// 字形特征断言：NSFontManager.convert 产出的字体在 descriptor 里可能不报字重，
    /// 但 traits(of:) 能给出真实特征（Bold+Italic=3）。
    private func hasTrait(_ font: NSFont?, _ trait: NSFontTraitMask) -> Bool {
        guard let font else { return false }
        return NSFontManager.shared.traits(of: font).contains(trait)
    }

    @Test func nestedEmphasisCombinesTraits() {
        // **a *b* c**：b 应同时是粗体与斜体（审查 P2：字体 traits 合并而非覆盖）
        let source = "**a *b* c**"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        let b = font(at: 5, in: storage)
        #expect(hasTrait(b, .boldFontMask))
        #expect(hasTrait(b, .italicFontMask))

        // 反向（斜体包粗体）依赖扫描器能做 delimiter-run 分析（M2 明确项），
        // 当前 *a **b** c* 解析为三段单星强调，见 TokenScannerTests.singleStarEmphasisDoesNotSeeThroughStrong。
    }

    @Test func dirtyApplyRestylesOnlyChangedLines() {
        let source = "- **列表** 第一行\n\n正文段落\n\n- 第二行"
        let storage = NSTextStorage(string: source)
        let engine2 = engine
        let package = engine2.prepare(source)
        // 首渲：光标在文档末尾 → 除第 5 行外 marker 全隐藏
        _ = engine2.render(package: package, selection: NSRange(location: 25, length: 0), into: storage)

        // 模拟在"正文段落"（第 3 行）输入一个字符
        let dirty = NSRange(location: 15, length: 1)
        let lines = engine2.applyDirty(package: package, previousPackage: nil, utf16Range: dirty, into: storage)
        #expect(lines == 2...3) // 受影响行 + 1 邻居行（换行拆分的保险区）

        // 第 1 行的样式与 marker 显隐不受影响
        #expect(isHidden(2, in: storage))          // "**" 处仍为隐藏字号
        #expect(weight(font(at: 4, in: storage)) > 0.1) // 列表内容仍加粗
        #expect(storage.string == source)          // 字符不变
        // 脏行本身恢复基础样式（CJK → PingFang 回退，按字号+字重断言）
        #expect(font(at: 15, in: storage)?.pointSize == 16)
        #expect(weight(font(at: 15, in: storage)) < 0.05)
    }
}
