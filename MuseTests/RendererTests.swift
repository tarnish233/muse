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

    @Test func headingMarkerRevealedOnCaretLineOnly() {
        // heading 的 # 跟随光标显隐（Typora 行为）：光标在第二行时第一行 # 隐藏
        let source = "## 甲\n## 乙"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 6, length: 0), into: storage)

        #expect(isHidden(0, in: storage))
        #expect(font(at: 5, in: storage) == theme.revealedMarkerFont()) // 第二行 "## " 起点（utf16）
    }

    @Test func structuralMarkersFollowCaret() {
        // Typora 模式：结构标记只在光标所在行/块内回显；列表/任务在光标行外为
        // ghost（保留宽度的透明，图形符号由绘制层画）；引用/围栏折叠隐藏。
        let source = "- 甲\n1. 乙\n- [ ] 丙\n> 引\n```\n代码\n```"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let caret = (source as NSString).range(of: "代码").location // utf16 25
        _ = engine.render(package: package, selection: NSRange(location: caret, length: 0), into: storage)

        func colorAlpha(_ at: Int) -> CGFloat {
            ((storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)?.cgColor.alpha ?? 1)
        }
        // 围栏：光标在块内 → 开栏符回显（有色）
        #expect(font(at: 21, in: storage) == theme.revealedMarkerFont())
        #expect(colorAlpha(21) > 0)
        // 列表/任务：光标不在行上 → ghost（回显字号 + 透明）
        #expect(font(at: 0, in: storage) == theme.revealedMarkerFont())
        #expect(colorAlpha(0) == 0)
        #expect(colorAlpha(9) == 0) // "- [ ] " 起点
        // 引用：折叠隐藏
        #expect(isHidden(17, in: storage))
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
        // CJK 按标点类参与 flanking（有意偏离 CommonMark 词内限制），紧贴汉字可加粗
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

    /// 块级视觉必须经由 TextKit 2 的 fragment 路径产出。
    ///
    /// 这个测试之前直接调用绘制函数往位图里画，于是在真机上一片空白的同时依然全绿：
    /// layer-backed 的 TextKit 2 NSTextView 会把字形渲染进各 fragment 自己的图层，
    /// 视图级 draw/drawBackground 画的内容被整片盖掉。所以断言必须落在
    /// 「layoutManager 真的生产 MuseLayoutFragment」+「该 fragment 的 draw 真的落墨」上。
    @Test func blockVisualsComeFromLayoutFragments() {
        let source = "1. 有序列表\n> 引用块\n```swift\nlet value = 1\n```"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let before = fragmentPixelCount(in: textView)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: storage.length, length: 0), into: storage)
        let after = fragmentPixelCount(in: textView)

        // 委托已挂上：布局管理器生产的是自定义 fragment，而不是系统默认实现。
        #expect(customFragmentCount(in: textView) > 0)
        #expect(before == 0)
        #expect(after > 0)
    }

    @Test func linkLabelStyledWithURL() {
        let source = "[打开](https://apple.com)"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        // 光标在文档末尾（utf16 总长 23）→ 链接标记隐藏
        _ = engine.render(package: package, selection: NSRange(location: 23, length: 0), into: storage)

        let url = storage.attribute(.link, at: 1, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://apple.com")
        #expect(storage.attribute(.underlineStyle, at: 1, effectiveRange: nil) != nil)
        #expect(isHidden(0, in: storage))  // [
        #expect(isHidden(3, in: storage))  // ] 起点（tail）

        // 光标进入标签 → 语法回显
        let coordinator = RenderCoordinator()
        coordinator.adoptPackage(package)
        coordinator.updateMarkerVisibility(selection: NSRange(location: 2, length: 0), into: storage)
        #expect(font(at: 0, in: storage) == theme.revealedMarkerFont())
        #expect(storage.string == source)
    }

    @Test func ruleHiddenWithSpacing() {
        let source = "上一段\n\n---\n\n下一段"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        #expect(isHidden(5, in: storage)) // "---" 起始（utf16：上一段 3 + \n\n 2）
        #expect(storage.string == source)
        let paragraph = storage.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.paragraphSpacing == 10)
        // 块标记随样式写入，绘制层据此画真实横线
        #expect(storage.attribute(.museBlock, at: 5, effectiveRange: nil) as? String == BlockVisual.rule.rawValue)
    }

    // MARK: - 块级视觉标记（MuseLayoutFragment 的驱动属性）

    /// .museBlock 属性必须覆盖到行首字符（绘制层按 line/element 起点读取）。
    @Test func blockMarkersCoverLineStarts() {
        let source = "- 列表\n> 引用\n```\ncode\n```\n\n---"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        func block(_ at: Int) -> String? {
            storage.attribute(.museBlock, at: at, effectiveRange: nil) as? String
        }
        #expect(block(3) == "list:u")                         // 列表行整行带块标记
        #expect(block(5) == BlockVisual.quote.rawValue)      // "> " 行首（utf16 5）
        #expect(block(6) == BlockVisual.quote.rawValue)      // 引用内容
        #expect(block(10) == BlockVisual.codeFence.rawValue) // 开栏行
        #expect(block(14) == BlockVisual.codeFence.rawValue) // 围栏体
        #expect(block(19) == BlockVisual.codeFence.rawValue) // 闭栏行
        #expect(block(24) == BlockVisual.rule.rawValue)      // 分隔线（空白行之后）
    }

    /// 列表悬挂缩进：marker 在行首、换行从 24pt 缩进（Typora 视觉）。
    @Test func listParagraphHasHangingIndent() {
        let source = "- 长列表项内容" + String(repeating: "足够长到可以换行，", count: 20)
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        // 段落样式覆盖整行（含 marker）：NSTextStorage 的段落修复不会把它修回 base
        let paragraph = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.headIndent == 24)
        #expect(paragraph?.firstLineHeadIndent == 0)
    }

    /// 字形特征断言：NSFontManager.convert 产出的字体在 descriptor 里可能不报字重，
    /// 但 traits(of:) 能给出真实特征（Bold+Italic=3）。
    private func hasTrait(_ font: NSFont?, _ trait: NSFontTraitMask) -> Bool {
        guard let font else { return false }
        return NSFontManager.shared.traits(of: font).contains(trait)
    }

    /// layoutManager 实际生产的自定义 fragment 数（验证委托挂接）。
    private func customFragmentCount(in textView: EditorTextView) -> Int {
        guard let layoutManager = textView.textLayoutManager else { return 0 }
        var count = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if fragment is MuseLayoutFragment { count += 1 }
            return true
        }
        return count
    }

    /// 走真实 fragment 绘制路径，统计落墨像素。
    private func fragmentPixelCount(in textView: EditorTextView) -> Int {
        let width = 640
        let height = 360
        guard let layoutManager = textView.textLayoutManager,
              let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return 0
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        // 只画块视觉、不画字形：字形会淹没像素差，无法区分「块视觉有没有落墨」。
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let museFragment = fragment as? MuseLayoutFragment else { return true }
            let frame = museFragment.layoutFragmentFrame
            museFragment.drawBlockVisuals(at: frame.origin, in: context.cgContext)
            return true
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return 0 }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        var count = 0
        for row in 0..<bitmap.pixelsHigh {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let pixelStart = rowStart + column * bytesPerPixel
                let pixel = UnsafeBufferPointer(start: data + pixelStart, count: bytesPerPixel)
                if pixel.contains(where: { $0 != 0xFF }) {
                    count += 1
                }
            }
        }
        return count
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
