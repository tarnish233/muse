import AppKit
import Testing
@testable import MuseKit

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
        // Typora 模式：结构标记只在光标所在行/块内回显；列表/任务在光标行外
        // 近零宽隐藏，图形符号由绘制层画；引用/围栏折叠隐藏。
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
        // 列表/任务：光标不在行上 → hidden（近零字号 + 透明）
        #expect(isHidden(0, in: storage))
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
        // CJK 的成对语义由 AST 提供，紧贴汉字的 marker 仍能精确定位。
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

    @Test func closingFenceAtEndOfDocumentGetsBlockAttribute() {
        let source = "```swift\nlet a = 1\n```"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: storage.length, length: 0), into: storage)

        let closingStart = storage.length - 3
        #expect(storage.attribute(.museBlock, at: closingStart, effectiveRange: nil) as? String == BlockVisual.codeFence.rawValue)
    }

    @Test func unclosedFenceGetsBlockAttributeToDocumentEnd() {
        let source = "```swift\nlet a = 1\n未闭合"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: storage.length, length: 0), into: storage)

        #expect(storage.attribute(.museBlock, at: storage.length - 1, effectiveRange: nil) as? String == BlockVisual.codeFence.rawValue)
    }

    @Test func fenceInfoStringAndCloserHiddenWhenCaretOutside() {
        let source = "段落\n\n```swift\nlet a = 1\n```\n\n尾段"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: storage.length, length: 0), into: storage)

        let opening = (source as NSString).range(of: "```swift")
        for location in opening.location..<(opening.location + opening.length) {
            #expect(isHidden(location, in: storage))
        }
        let closing = (source as NSString).range(of: "```", options: .backwards)
        for location in closing.location..<(closing.location + closing.length) {
            #expect(isHidden(location, in: storage))
        }
    }

    @Test func fenceMarkersRevealedWhenCaretInside() {
        let source = "段落\n\n```swift\nlet a = 1\n```\n\n尾段"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let caret = (source as NSString).range(of: "let a = 1").location
        _ = engine.render(package: package, selection: NSRange(location: caret, length: 0), into: storage)

        let opening = (source as NSString).range(of: "```swift")
        for location in opening.location..<(opening.location + opening.length) {
            #expect(!isHidden(location, in: storage))
        }
        let closing = (source as NSString).range(of: "```", options: .backwards)
        for location in closing.location..<(closing.location + closing.length) {
            #expect(!isHidden(location, in: storage))
        }
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

    @Test func blockVisualsRenderForEachBlockKind() {
        let source = "- 无序\n1. 有序\n- [ ] 待办\n- [x] 完成\n> 引用\n```swift\nlet value = 1\n```\n---"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: storage.length, length: 0), into: storage)
        let fragments = customFragments(in: textView)

        let listFragments = fragments.filter {
            $0.blockKind?.hasPrefix(BlockVisual.list.rawValue + ":") == true
        }
        #expect(listFragments.contains { $0.blockKind == BlockVisual.list.rawValue + ":u" })
        #expect(listFragments.contains { $0.blockKind == BlockVisual.list.rawValue + ":o" })
        #expect(listFragments.filter { $0.blockKind == BlockVisual.list.rawValue + ":t" }.count >= 2)
        #expect(listFragments.allSatisfy { blockPixelCount(of: $0) > 0 })

        for kind in [BlockVisual.quote.rawValue, BlockVisual.codeFence.rawValue, BlockVisual.rule.rawValue] {
            guard let fragment = fragments.first(where: { $0.blockKind == kind }) else {
                #expect(Bool(false), "missing fragment for \(kind)")
                continue
            }
            #expect(blockPixelCount(of: fragment) > 0)
        }
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

    @Test func paletteUpdatesOnAppearanceChange() {
        let aqua = NSAppearance(named: .aqua)!
        let darkAqua = NSAppearance(named: .darkAqua)!
        defer { BlockVisualPalette.shared.update(for: aqua) }

        BlockVisualPalette.shared.update(for: aqua)
        let light = BlockVisualPalette.shared.snapshot()
        BlockVisualPalette.shared.update(for: darkAqua)
        let dark = BlockVisualPalette.shared.snapshot()

        #expect(light.quoteBackground.components != dark.quoteBackground.components)
        #expect(light.codeBackground.components != dark.codeBackground.components)
        #expect(light.marker.components != dark.marker.components)
        #expect(light.border.components != dark.border.components)
        // The system accent may intentionally remain the same in both
        // appearances; the palette still resolves it through NSColor so
        // custom/system accent changes are reflected in the marker.
        #expect(light.checkboxUnchecked.components != dark.checkboxUnchecked.components)
    }

    @Test func taskMarkersUseAccentAndContrastingColors() throws {
        let source = "- [ ] 待办\n- [x] 完成"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 180)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let taskFragments = customFragments(in: textView).filter {
            $0.blockKind == BlockVisual.list.rawValue + ":t"
        }
        #expect(taskFragments.count == 2)
        guard taskFragments.count == 2 else { return }

        let unchecked = try #require(taskFragments.first {
            if case .task(checked: false) = $0.listMarkerGlyph { return true }
            return false
        })
        let checked = try #require(taskFragments.first {
            if case .task(checked: true) = $0.listMarkerGlyph { return true }
            return false
        })
        let palette = BlockVisualPalette.shared.snapshot()
        #expect(unchecked.listMarkerColor?.components == palette.checkboxUnchecked.components)
        #expect(checked.listMarkerColor?.components == palette.checkboxChecked.components)
        #expect(unchecked.listMarkerColor?.components != palette.marker.components)
        #expect(checked.listMarkerColor?.components != palette.marker.components)
    }

    @Test func blockVisualsFollowAppearance() {
        let aqua = NSAppearance(named: .aqua)!
        let darkAqua = NSAppearance(named: .darkAqua)!
        defer { BlockVisualPalette.shared.update(for: aqua) }

        let source = "> 引用块"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 160)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: storage.length, length: 0), into: storage)
        guard let fragment = customFragments(in: textView).first(where: {
            $0.blockKind == BlockVisual.quote.rawValue
        }) else {
            #expect(Bool(false), "missing quote fragment")
            return
        }

        let lightPixel = quoteBackgroundPixel(of: fragment, in: aqua)
        let darkPixel = quoteBackgroundPixel(of: fragment, in: darkAqua)
        #expect(lightPixel != darkPixel)
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

    /// 列表悬挂缩进：depth 1 的 marker 在行首、换行从 24pt 缩进（Typora 视觉）。
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

    @Test func listParagraphIndentScalesWithDepth() {
        let source = "- 一层\n  - 二层\n    - 三层"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: NSRange(location: storage.length, length: 0), into: storage)

        let paragraphs = [0, 5, 12].compactMap {
            storage.attribute(.paragraphStyle, at: $0, effectiveRange: nil) as? NSParagraphStyle
        }
        #expect(paragraphs.count == 3)
        #expect(paragraphs.map(\.firstLineHeadIndent) == [0, 24, 48])
        #expect(paragraphs.map(\.headIndent) == [24, 48, 72])
        #expect(paragraphs[0].firstLineHeadIndent < paragraphs[1].firstLineHeadIndent)
        #expect(paragraphs[1].firstLineHeadIndent < paragraphs[2].firstLineHeadIndent)
    }

    @Test func nestedListMarkersAlignWithIndent() {
        let source = "- 一层\n  - 二层\n    - 三层"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        // No caret selection keeps all three list markers hidden so the
        // custom fragment draws each visual marker.
        _ = engine.render(package: package, selection: nil, into: storage)
        let fragments = customFragments(in: textView).filter {
            $0.blockKind == BlockVisual.list.rawValue + ":u"
        }
        #expect(fragments.count == 3)

        let markerX = fragments.map(markerInkMinX(of:))
        #expect(markerX.allSatisfy { $0 != nil })
        let x = markerX.compactMap { $0 }
        #expect(x.count == 3)
        guard x.count == 3 else { return }
        #expect(x[1] > x[0])
        #expect(x[2] > x[1])
        // The marker band itself advances by the theme's 24pt depth step;
        // allow antialiasing and glyph-width differences at the edge.
        #expect(x[1] - x[0] >= 20)
        #expect(x[2] - x[1] >= 20)
    }

    @Test func unorderedMarkerGlyphsUseSemanticDepth() {
        #expect(ListMarkerGlyph.unordered(depth: 1).text == "•")
        #expect(ListMarkerGlyph.unordered(depth: 2).text == "◦")
        #expect(ListMarkerGlyph.unordered(depth: 3).text == "▪")
        // Depth is clamped for a deeper AST list; it is never inferred from
        // source indentation by the drawing layer.
        #expect(ListMarkerGlyph.unordered(depth: 99).text == "▪")
    }

    /// The marker pixels come from the real TextKit 2 fragments.  This catches
    /// a font fallback that paints U+25E6 as a filled dot even though the glyph
    /// string itself is correct.
    @Test func unorderedMarkerPixelsDistinguishFilledAndHollow() throws {
        let source = "- 一级\n  - 二级"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let fragments = customFragments(in: textView).filter {
            $0.blockKind == BlockVisual.list.rawValue + ":u"
        }
        #expect(fragments.count == 2)
        guard fragments.count == 2 else { return }

        let glyphs = fragments.compactMap { $0.listMarkerGlyph?.text }
        #expect(glyphs == ["•", "◦"])

        let filledLuma = try #require(markerCenterLuma(of: fragments[0]))
        let hollowLuma = try #require(markerCenterLuma(of: fragments[1]))
        // The bitmap is white, so a filled center is dark while a hollow
        // center remains the background (allowing a small antialiasing margin).
        #expect(filledLuma < 2.8)
        #expect(hollowLuma > 2.95)
    }

    @Test func listMarkersAlignWithFirstVisualLineMetrics() throws {
        let source = "- " + String(repeating: "可换行的列表内容 ", count: 24) + "\n1. 有序列表"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 240, height: 640)
        textView.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let fragments = customFragments(in: textView)
        let fragment = try #require(fragments.first {
            $0.blockKind == BlockVisual.list.rawValue + ":u"
        })
        let firstLine = try #require(fragment.textLineFragments.first)
        #expect(fragment.textLineFragments.count > 1)

        let drawPoint = CGPoint(x: fragment.layoutFragmentFrame.origin.x + 24, y: 20)
        let markerFrame = try #require(fragment.listMarkerFrame(at: drawPoint))
        let bodyFont = try #require(font(at: 2, in: storage))
        let bodyXHeightCenterY = drawPoint.y + firstLine.glyphOrigin.y - bodyFont.xHeight / 2
        #expect(abs(markerFrame.midY - bodyXHeightCenterY) < 0.5)
        // A paragraph fragment can be much taller than its first line; the
        // marker must stay near the first line instead of paragraph-center.
        #expect(abs(markerFrame.midY - (drawPoint.y + fragment.layoutFragmentFrame.height / 2)) > 20)

        let ordered = try #require(fragments.first {
            $0.blockKind == BlockVisual.list.rawValue + ":o"
        })
        let orderedLine = try #require(ordered.textLineFragments.first)
        let orderedPoint = CGPoint(x: ordered.layoutFragmentFrame.origin.x + 24, y: 20)
        let orderedFrame = try #require(ordered.listMarkerFrame(at: orderedPoint))
        let orderedFont = NSFont.systemFont(ofSize: try #require(ordered.listMarkerGlyph).fontSize)
        let markerBaselineY = orderedFrame.minY + orderedFont.ascender
        let contentBaselineY = orderedPoint.y + orderedLine.glyphOrigin.y
        #expect(abs(markerBaselineY - contentBaselineY) < 0.5)
    }

    @Test func orderedMarkersUseStableLaneAndFitLargeNumbers() throws {
        let source = "1. one\n2. two\n\nseparator\n\n98. ninety-eight\n99. ninety-nine\n100. hundred"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 320, height: 260)
        textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let fragments = customFragments(in: textView).filter {
            $0.blockKind == BlockVisual.list.rawValue + ":o"
        }
        #expect(fragments.count == 5)
        guard fragments.count == 5 else { return }
        #expect(fragments.compactMap { $0.listMarkerGlyph?.text } == ["1.", "2.", "98.", "99.", "100."])

        let points = fragments.map(markerDrawPoint(for:))
        let frames = try fragments.enumerated().map { index, fragment in
            try #require(fragment.listMarkerFrame(at: points[index]))
        }
        // The fixed lane left edge is stable for 1. and 2.; compare visible
        // bitmap ink as well as the lane geometry returned by real fragments.
        let lanes = try fragments.enumerated().map { index, fragment in
            try #require(fragment.listMarkerLaneFrame(at: points[index]))
        }
        #expect(abs(lanes[0].minX - lanes[1].minX) < 0.01)
        let inkBounds = try fragments.enumerated().map { index, fragment in
            try #require(markerInkBounds(of: fragment, at: points[index]))
        }
        #expect(abs(inkBounds[0].minX - inkBounds[1].minX) < 1)

        // 98., 99., and 100. stay inside the same lane instead of pushing the body
        // column. The draw point is the content-column anchor in fragment space.
        for index in 2..<5 {
            #expect(frames[index].maxX <= points[index].x - ListMarkerGeometry.markerGap + 0.5)
            #expect(frames[index].width <= ListMarkerGeometry.defaultMarkerLaneWidth - ListMarkerGeometry.markerGap + 0.5)
            #expect(inkBounds[index].maxX <= points[index].x - ListMarkerGeometry.markerGap + 0.5)
        }
    }

    @Test func orderedAndUnorderedMarkersShareDepthLaneWithoutMovingContent() throws {
        let source = "1. 有序\n- 无序"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let fragments = customFragments(in: textView)
        let ordered = try #require(fragments.first { $0.blockKind == BlockVisual.list.rawValue + ":o" })
        let unordered = try #require(fragments.first { $0.blockKind == BlockVisual.list.rawValue + ":u" })
        let orderedLine = try #require(ordered.textLineFragments.first)
        let unorderedLine = try #require(unordered.textLineFragments.first)
        let orderedPoint = markerDrawPoint(for: ordered)
        let unorderedPoint = markerDrawPoint(for: unordered)
        let orderedFrame = try #require(ordered.listMarkerFrame(at: orderedPoint))
        let unorderedFrame = try #require(unordered.listMarkerFrame(at: unorderedPoint))
        let orderedLane = try #require(ordered.listMarkerLaneFrame(at: orderedPoint))
        let unorderedLane = try #require(unordered.listMarkerLaneFrame(at: unorderedPoint))
        #expect(abs(orderedLane.minX - unorderedLane.minX) < 0.01)
        let orderedInk = try #require(markerInkBounds(of: ordered, at: orderedPoint))
        let unorderedInk = try #require(markerInkBounds(of: unordered, at: unorderedPoint))
        #expect(abs(orderedInk.minX - unorderedInk.minX) < 2)

        // Convert each line-local location into the same draw coordinate space
        // used by the marker frame and bitmap assertions.
        let orderedContentX = orderedPoint.x + orderedLine.locationForCharacter(at: 3).x
        let unorderedContentX = unorderedPoint.x + unorderedLine.locationForCharacter(at: 2).x
        #expect(abs(orderedContentX - unorderedContentX) < 0.5)
        #expect(orderedFrame.maxX <= orderedPoint.x - ListMarkerGeometry.markerGap + 0.5)
        #expect(unorderedFrame.maxX <= unorderedPoint.x - ListMarkerGeometry.markerGap + 0.5)
    }

    @Test func taskAndBulletMarkersAlignToSameContentColumn() {
        let source = "- 普通项目\n- [ ] 任务项目"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let fragments = customFragments(in: textView)
        guard let bullet = fragments.first(where: { $0.blockKind == BlockVisual.list.rawValue + ":u" }),
              let task = fragments.first(where: { $0.blockKind == BlockVisual.list.rawValue + ":t" }),
              let bulletLine = bullet.textLineFragments.first,
              let taskLine = task.textLineFragments.first else {
            #expect(Bool(false), "missing real list fragments or line fragments")
            return
        }

        // The hidden marker ranges have different source lengths (2 vs 6 UTF-16
        // code units), so compare the actual content character positions reported
        // by the real TextKit 2 line fragments.
        let bulletContentX = bulletLine.locationForCharacter(at: 2).x
        let taskContentX = taskLine.locationForCharacter(at: 6).x
        #expect(abs(bulletContentX - taskContentX) < 0.5)
        #expect(isHidden(0, in: storage))
        #expect(isHidden((source as NSString).range(of: "- [ ]").location, in: storage))
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

    /// 从框架实际枚举结果中收集自定义 fragment；不构造替代 fragment 参与断言。
    private func customFragments(in textView: EditorTextView) -> [MuseLayoutFragment] {
        guard let layoutManager = textView.textLayoutManager else { return [] }
        var fragments: [MuseLayoutFragment] = []
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let museFragment = fragment as? MuseLayoutFragment {
                fragments.append(museFragment)
            }
            return true
        }
        return fragments
    }

    /// 只对已经由 TextKit 2 枚举得到的 fragment 调用其块视觉入口，避免字形像素掩盖结果。
    private func blockPixelCount(of fragment: MuseLayoutFragment) -> Int {
        let width = 640
        let height = 160
        guard let bitmap = NSBitmapImageRep(
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
        let frame = fragment.layoutFragmentFrame
        // Hidden list markers are intentionally drawn just before the
        // fragment origin. Give this isolated bitmap the same leading room
        // that the real text view's inset provides.
        let drawX = fragment.blockKind?.hasPrefix(BlockVisual.list.rawValue + ":") == true
            ? frame.origin.x + 24
            : frame.origin.x
        fragment.drawBlockVisuals(
            at: CGPoint(x: drawX, y: 20),
            in: context.cgContext
        )
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

    /// Return the left-most ink from a real list fragment's block-visual draw.
    /// The fragment is obtained through TextKit 2 enumeration; this measures the
    /// actual marker placement rather than a parallel coordinate calculation.
    private func markerInkMinX(of fragment: MuseLayoutFragment) -> Int? {
        let width = 640
        let height = 160
        guard let bitmap = NSBitmapImageRep(
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
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let frame = fragment.layoutFragmentFrame
        let drawX = fragment.blockKind?.hasPrefix(BlockVisual.list.rawValue + ":") == true
            ? frame.origin.x + 24
            : frame.origin.x
        fragment.drawBlockVisuals(at: CGPoint(x: drawX, y: frame.origin.y), in: context.cgContext)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        var minX: Int?
        for row in 0..<bitmap.pixelsHigh {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let pixelStart = rowStart + column * bytesPerPixel
                let pixel = UnsafeBufferPointer(start: data + pixelStart, count: bytesPerPixel)
                if pixel.prefix(3).contains(where: { $0 < 245 }) {
                    minX = min(minX ?? column, column)
                }
            }
        }
        return minX
    }

    /// Return the visible ink bounds from the real fragment's marker draw.
    /// Only block visuals are drawn, so body glyphs cannot mask lane overlap.
    private func markerDrawPoint(for fragment: MuseLayoutFragment) -> CGPoint {
        CGPoint(
            x: fragment.layoutFragmentFrame.origin.x + ListMarkerGeometry.defaultMarkerLaneWidth,
            y: 20
        )
    }

    private func markerInkBounds(
        of fragment: MuseLayoutFragment,
        at drawPoint: CGPoint
    ) -> (minX: CGFloat, maxX: CGFloat)? {
        let scale: CGFloat = 4
        let width = 160
        let height = 160
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(CGFloat(width) * scale),
            pixelsHigh: Int(CGFloat(height) * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        fragment.drawBlockVisuals(at: drawPoint, in: context.cgContext)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        var minX: Int?
        var maxX: Int?
        for row in 0..<bitmap.pixelsHigh {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let pixelStart = rowStart + column * bytesPerPixel
                let pixel = UnsafeBufferPointer(start: data + pixelStart, count: bytesPerPixel)
                if pixel.prefix(3).contains(where: { $0 < 245 }) {
                    minX = min(minX ?? column, column)
                    maxX = max(maxX ?? column, column)
                }
            }
        }
        guard let minX, let maxX else { return nil }
        return (CGFloat(minX) / scale, CGFloat(maxX) / scale)
    }

    /// 在指定外观上下文中经真实 fragment 绘制引用背景，采样远离竖线与字形的像素。
    private func quoteBackgroundPixel(of fragment: MuseLayoutFragment, in appearance: NSAppearance) -> [CGFloat] {
        let width = 640
        let height = 160
        guard let bitmap = NSBitmapImageRep(
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
            return []
        }

        let frame = fragment.layoutFragmentFrame
        appearance.performAsCurrentDrawingAppearance {
            BlockVisualPalette.shared.update(for: appearance)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.setFillColor(NSColor.white.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
            fragment.drawBlockVisuals(
                at: CGPoint(x: frame.origin.x, y: 20),
                in: context.cgContext
            )
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        // CGContext uses a bottom-left origin while `colorAt` addresses bitmap rows
        // from the top, so mirror the sample row before reading it back.
        let drawY = 20 + Int(frame.height / 2)
        let y = min(height - 1, max(0, height - 1 - drawY))
        let color = bitmap.colorAt(x: 12, y: y)?.usingColorSpace(.deviceRGB)
        return [color?.redComponent ?? -1, color?.greenComponent ?? -1, color?.blueComponent ?? -1]
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

    /// Render one already-laid-out fragment into an isolated bitmap and sample
    /// the marker's center.  TextKit's bitmap coordinate orientation differs
    /// from the flipped NSString drawing context, so sample both vertical
    /// orientations and use the darker one.
    private func markerCenterLuma(of fragment: MuseLayoutFragment) -> CGFloat? {
        let width = 120
        let height = 100
        guard let bitmap = NSBitmapImageRep(
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
            return nil
        }

        let drawPoint = CGPoint(x: fragment.layoutFragmentFrame.origin.x + 24, y: 20)
        guard let markerFrame = fragment.listMarkerFrame(at: drawPoint) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        fragment.drawBlockVisuals(at: drawPoint, in: context.cgContext)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let x = min(width - 1, max(0, Int(markerFrame.midX.rounded())))
        let y = Int(markerFrame.midY.rounded())
        let candidates = [y, height - 1 - y].map { min(height - 1, max(0, $0)) }
        return candidates.compactMap { row in
            bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB).map {
                $0.redComponent + $0.greenComponent + $0.blueComponent
            }
        }.min()
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

        // 反向（斜体包粗体）由 AST 的嵌套结构提供，避免渲染层复制 delimiter 匹配。
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
