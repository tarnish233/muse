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

    /// 临时目录里的一张真 PNG，供块图片测试用真实解析路径。
    /// 用真文件而不是打桩：图片能不能加载正是 M5 坏掉的那一环。
    struct ImageFixture: ~Copyable {
        let directory: URL
        let fileName = "fixture.png"
        let pixelSize = NSSize(width: 120, height: 90)

        var url: URL { directory.appendingPathComponent(fileName) }

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("muse-image-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(pixelSize: pixelSize, color: .red)
        }

        func write(pixelSize: NSSize, color: NSColor) throws {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = pixelSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill()
            NSRect(origin: .zero, size: pixelSize).fill()
            NSGraphicsContext.restoreGraphicsState()
            try #require(rep.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
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

    @Test func crossLineSelectionRevealsEverySelectedBlockMarker() {
        let source = "- first\n> quote\nplain\n1. outside"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let start = (source as NSString).range(of: "first").location
        let endRange = (source as NSString).range(of: "quote")
        let selection = NSRange(location: start, length: endRange.location + endRange.length - start)

        _ = engine.render(package: package, selection: selection, into: storage)

        #expect(!isHidden((source as NSString).range(of: "- ").location, in: storage))
        #expect(!isHidden((source as NSString).range(of: "> ").location, in: storage))
        #expect(isHidden((source as NSString).range(of: "1. ").location, in: storage))
        #expect(storage.string == source)
    }

    @Test func sourceModeShowsLiteralMarkdownWithoutBlockDecorations() {
        let source = "# Title\n- item\n**bold**"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)

        _ = engine.render(
            package: package,
            selection: NSRange(location: storage.length, length: 0),
            mode: .source,
            into: storage
        )

        #expect(storage.string == source)
        #expect(font(at: 0, in: storage) == theme.codeFont())
        #expect(font(at: (source as NSString).range(of: "bold").location, in: storage) == theme.codeFont())
        #expect(storage.attribute(.museBlock, at: (source as NSString).range(of: "- ").location, effectiveRange: nil) == nil)
    }

    @Test func renderedModeRestoresPreviewAfterSourceMode() {
        let source = "正文\n- item"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let selection = NSRange(location: 0, length: 0)

        _ = engine.render(package: package, selection: selection, mode: .source, into: storage)
        _ = engine.render(package: package, selection: selection, mode: .rendered, into: storage)

        let marker = (source as NSString).range(of: "- ").location
        #expect(isHidden(marker, in: storage))
        #expect(storage.attribute(.museBlock, at: marker, effectiveRange: nil) as? String == BlockVisual.list.rawValue + ":u")
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
        #expect(paragraph?.paragraphSpacing == 16) // Typora hr：上下 margin 16px
        // 块标记随样式写入，绘制层据此画真实横线
        #expect(storage.attribute(.museBlock, at: 5, effectiveRange: nil) as? String == BlockVisual.rule.rawValue)
    }

    // MARK: - 图片（块呈现）

    /// 独占一行且能加载的图片：整段折叠、行高撑成图片高度、块角色与解析后的
    /// 路径写进属性，绘制层照着画。
    @Test func blockImageReservesLineHeightAndCarriesPath() throws {
        let asset = try ImageFixture()
        let source = "![截图](\(asset.fileName))"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = ImageResolver.loadLocalImage(url: asset.url)
        _ = engine.render(package: package, selection: nil, into: storage, imageBaseURL: asset.directory)

        #expect(storage.string == source)
        #expect(storage.attribute(.museBlock, at: 0, effectiveRange: nil) as? String
                == BlockVisual.image.rawValue)
        #expect(storage.attribute(.museImagePath, at: 0, effectiveRange: nil) as? String
                == asset.url.standardizedFileURL.path)

        let size = try #require(RenderEngine.imageSize(in: storage, at: 0))
        let expected = ImageResolver.displaySize(for: asset.pixelSize)
        #expect(abs(size.width - expected.width) < 0.5)
        #expect(abs(size.height - expected.height) < 0.5)

        // 行高必须真的被预留出来：这是「不改字符也能放下一张图」的全部机制。
        let paragraph = try #require(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(paragraph.minimumLineHeight >= size.height)

        // 整段语法折叠，一个字符都不该露出来。
        for index in 0..<(source as NSString).length {
            #expect(isHidden(index, in: storage), "index \(index) 未折叠")
        }
    }

    /// `.attachment` 走不通的回归守卫。
    ///
    /// NSTextStorage 的属性修复会把 `.attachment` 从任何非 U+FFFC 字符上抹掉，
    /// 而「只写属性、不改字符」不允许插入 U+FFFC。这一条钉住这个事实，避免有人
    /// 再把行内图片改回附件实现（M5 就是这么坏掉的）。
    @Test func attachmentAttributeIsStrippedFromOrdinaryCharacter() {
        let storage = NSTextStorage(string: "![截图](a.png)")
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 10, height: 10))

        storage.beginEditing()
        storage.addAttribute(.attachment, value: attachment, range: NSRange(location: 0, length: 1))
        #expect(storage.attribute(.attachment, at: 0, effectiveRange: nil) != nil, "编辑会话内还在")
        storage.endEditing()
        #expect(storage.attribute(.attachment, at: 0, effectiveRange: nil) == nil,
                "endEditing 的属性修复应当抹掉非 U+FFFC 上的附件")
    }

    /// 加载不到的图片（文件缺失或远程地址）仍按块呈现：绘制层画带目的地文字的
    /// 占位框，比把源码摊回正文更能说明「这里是一张图」。
    @Test func unloadableBlockImageFallsBackToPlaceholderBox() {
        let source = "![截图](https://example.com/a.png)"
        let storage = NSTextStorage(string: source)
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)

        #expect(storage.attribute(.museBlock, at: 0, effectiveRange: nil) as? String
                == BlockVisual.image.rawValue)
        #expect(storage.attribute(.museImagePath, at: 0, effectiveRange: nil) == nil)
        #expect(RenderEngine.imageSize(in: storage, at: 0) == Theme.imagePlaceholderSize)
        #expect(storage.attribute(.museImageDestination, at: 0, effectiveRange: nil) as? String
                == "https://example.com/a.png")
    }

    /// 夹在正文里的图片保持完整源码呈现（弱化成 marker 色），并且**不**变成块——
    /// 否则这一段会被撑成一张图的高度。
    @Test func inlineImageKeepsSyntaxPresentation() throws {
        let source = "看这张 ![截图](a.png) 很清楚"
        let nsSource = source as NSString
        let storage = NSTextStorage(string: source)
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)

        let markerLocation = nsSource.range(of: "![").location
        let tailLocation = nsSource.range(of: "](a.png)").location
        #expect(storage.attribute(.museBlock, at: markerLocation, effectiveRange: nil) == nil)
        // 整段可见：折叠一半会留下 `![截图` 这种残句，而图并没有画出来。
        #expect(!isHidden(markerLocation, in: storage))
        #expect(!isHidden(nsSource.range(of: "截图").location, in: storage))
        #expect(!isHidden(tailLocation, in: storage))
        // 语法弱化成 marker 色，标签保持正文色。
        #expect(storage.attribute(.foregroundColor, at: markerLocation, effectiveRange: nil) as? NSColor
                == theme.mutedText)
        #expect(storage.attribute(.foregroundColor, at: tailLocation, effectiveRange: nil) as? NSColor
                == theme.mutedText)
        // 点击预览仍然拿得到目的地。
        #expect(storage.attribute(.museImageDestination, at: markerLocation, effectiveRange: nil) as? String
                == "a.png")
        #expect(storage.string == source)
    }

    /// 光标进入块图片所在行：撤掉块角色与撑高的行高，露出源码——这是改图片
    /// 路径的唯一入口。
    @Test func blockImageRevealsSourceUnderCaret() throws {
        let asset = try ImageFixture()
        let source = "![截图](\(asset.fileName))"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(
            package: package,
            selection: NSRange(location: 1, length: 0),
            into: storage,
            imageBaseURL: asset.directory
        )

        #expect(storage.attribute(.museBlock, at: 0, effectiveRange: nil) == nil, "回显时不该再画图")
        #expect(font(at: 0, in: storage) == theme.revealedMarkerFont())
        let paragraph = try #require(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(paragraph.minimumLineHeight == 0, "回显后行高应回到普通段落")
    }

    /// 图片目的地的路径解析（点击预览与块呈现共用同一个解析器）。
    @Test func imageDestinationResolution() {
        let base = URL(fileURLWithPath: "/Users/muse/docs")
        func path(_ url: URL?) -> String? {
            url?.absoluteURL.standardizedFileURL.path
        }
        #expect(
            path(ImageResolver.resolvedURL(destination: "assets/pic.png", baseURL: base))
                == "/Users/muse/docs/assets/pic.png"
        )
        #expect(
            path(ImageResolver.resolvedURL(destination: "~/img/a.png", baseURL: base))?
                .hasPrefix("/Users/") == true
        )
        #expect(
            ImageResolver.resolvedURL(destination: "https://x.com/a.png", baseURL: base)
                == URL(string: "https://x.com/a.png")
        )
        #expect(ImageResolver.resolvedURL(destination: "  ", baseURL: base) == nil)
    }

    @Test func localImagePathsDecodePercentEscapesExactlyOnce() {
        let base = URL(fileURLWithPath: "/Users/muse/docs")
        func path(_ destination: String) -> String? {
            ImageResolver.resolvedURL(destination: destination, baseURL: base)?
                .absoluteURL.standardizedFileURL.path
        }

        #expect(path("assets/my%20photo.png") == "/Users/muse/docs/assets/my photo.png")
        #expect(path("assets/a+b.png") == "/Users/muse/docs/assets/a+b.png")
        #expect(path("assets/literal%2520.png") == "/Users/muse/docs/assets/literal%20.png")
        #expect(path("assets/bad%2G.png") == "/Users/muse/docs/assets/bad%2G.png")
        #expect(
            ImageResolver.resolvedURL(destination: "https://x.com/a%20b.png", baseURL: base)
                == URL(string: "https://x.com/a%20b.png")
        )
    }

    @Test func localImageCacheReloadsReplacementAndForgetsDeletion() throws {
        let asset = try ImageFixture()
        let first = try #require(ImageResolver.loadLocalImage(url: asset.url))
        #expect(first.size == asset.pixelSize)

        let replacementSize = NSSize(width: 64, height: 32)
        try asset.write(pixelSize: replacementSize, color: .blue)
        let replaced = try #require(ImageResolver.loadLocalImage(url: asset.url))
        #expect(replaced.size == replacementSize)

        try FileManager.default.removeItem(at: asset.url)
        #expect(ImageResolver.loadLocalImage(url: asset.url) == nil)
    }

    // MARK: - 代码围栏内边距（M5 排版）

    /// 围栏首行/末行带块角色与撑出垂直内边距的段落样式，内容行行距收紧。
    @Test func codeFenceFirstAndLastLinesCarryRoleAndPadding() {
        let source = "```swift\nlet a = 1\nlet b = 2\n```"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        func paragraph(at location: Int) -> NSParagraphStyle? {
            storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        }
        func role(at location: Int) -> String? {
            storage.attribute(.museBlockRole, at: location, effectiveRange: nil) as? String
        }

        // 行起点：0（```swift）、9（let a）、19（let b）、29（```）
        #expect(role(at: 0) == "open")
        #expect(role(at: 9) == nil)
        #expect(role(at: 19) == nil)
        #expect(role(at: 29) == "close")

        #expect(paragraph(at: 0)?.paragraphSpacingBefore == 14)
        #expect(paragraph(at: 0)?.paragraphSpacing == 0)
        #expect(paragraph(at: 9)?.paragraphSpacing == 0)
        #expect(paragraph(at: 29)?.paragraphSpacing == 14)
        // 整块仍是 codeFence 视觉
        #expect(storage.attribute(.museBlock, at: 9, effectiveRange: nil) as? String == BlockVisual.codeFence.rawValue)
    }

    /// 单行围栏（只有开栏行、无内容）同时承担 open+close 角色。
    @Test func singleLineFenceCarriesBothRoles() {
        let source = "```swift"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        #expect(storage.attribute(.museBlockRole, at: 0, effectiveRange: nil) as? String == "open+close")
    }

    // MARK: - 表格只读呈现（M5）

    /// 表头加粗、分隔行随光标显隐、数据行有块角色。
    @Test func tableRowsStyledWithRolesAndHiddenDelimiter() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        // 行起点：0（表头）、10（分隔行）、20（数据行）
        func role(at location: Int) -> String? {
            storage.attribute(.museBlockRole, at: location, effectiveRange: nil) as? String
        }
        #expect(role(at: 0) == "head")
        #expect(role(at: 10) == "delimiter")
        #expect(role(at: 20) == "close")
        #expect(storage.attribute(.museBlock, at: 20, effectiveRange: nil) as? String == BlockVisual.table.rawValue)
        #expect(font(at: 0, in: storage) != theme.codeFont()) // 表头加粗
        #expect(isHidden(10, in: storage))                    // 分隔行折叠
        #expect(storage.string == source)

        // 光标进表格：仍保持可视化网格，不回显 Markdown 分隔行
        _ = engine.render(
            package: package,
            selection: NSRange(location: 22, length: 0),
            into: storage
        )
        #expect(isHidden(10, in: storage))
        #expect(storage.string == source)
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
        // 表格底色也必须跟随外观：它们是 fragment 里直接取 CGColor 的那一类，
        // 漏掉就会在暗色模式下画成亮色（`NSAppearance.current` 为 nil 时静默回落）。
        #expect(light.tableHeaderBackground.components != dark.tableHeaderBackground.components)
        #expect(light.tableStripeBackground.components != dark.tableStripeBackground.components)
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

    @Test func listMarkerVariantsUseASTAttributes() {
        let source = "* [ ] 星号任务\n+ [x] 加号任务\n\n1) 括号序号"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 220)
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let glyphs = customFragments(in: textView).compactMap(\.listMarkerGlyph)

        #expect(glyphs.contains(.task(checked: false)))
        #expect(glyphs.contains(.task(checked: true)))
        #expect(glyphs.contains(.ordered(number: 1)))
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

    /// 多行引用的**每一行**都要拿到引用块视觉：竖条连续、底色连续、`>` 折叠。
    ///
    /// 曾经的形态：`appendBlockQuote` 只在 BlockQuote 的首行落一个 token，于是
    /// 第二行既没有底色/竖条（绘制层按 fragment 读 `.museBlock`，一段一个 fragment），
    /// 也没人隐藏它的 `> ` —— 视觉上引用块在第一行就断了。
    @Test func everyLineOfMultiLineQuoteCarriesQuoteVisual() {
        let source = "> 第一行\n> 第二行\n> 第三行"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        let ns = source as NSString
        for label in ["第一行", "第二行", "第三行"] {
            let contentAt = ns.range(of: label).location
            let lineStart = contentAt - 2   // "> " 的起点
            #expect(
                storage.attribute(.museBlock, at: lineStart, effectiveRange: nil) as? String
                    == BlockVisual.quote.rawValue,
                "\(label) 行首缺少引用块标记：绘制层画不出竖条"
            )
            #expect(
                storage.attribute(.backgroundColor, at: contentAt, effectiveRange: nil) != nil,
                "\(label) 缺少引用底色"
            )
            #expect(isHidden(lineStart, in: storage), "\(label) 的 \"> \" 没有折叠")
        }
        #expect(storage.string == source)
    }

    /// 光标落在多行引用的某一行时，只有那一行回显 `> `，其余行保持折叠，
    /// 且**整块的竖条与底色不因回显而断开**。
    @Test func revealingOneQuoteLineKeepsTheRestOfTheBlockIntact() {
        let source = "> 第一行\n> 第二行\n> 第三行"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let ns = source as NSString
        let caret = NSRange(location: ns.range(of: "第二行").location, length: 0)
        _ = engine.render(package: package, selection: caret, into: storage)

        #expect(!isHidden(ns.range(of: "第二行").location - 2, in: storage))
        #expect(isHidden(ns.range(of: "第一行").location - 2, in: storage))
        #expect(isHidden(ns.range(of: "第三行").location - 2, in: storage))
        for label in ["第一行", "第二行", "第三行"] {
            #expect(
                storage.attribute(.museBlock, at: ns.range(of: label).location - 2,
                                  effectiveRange: nil) as? String == BlockVisual.quote.rawValue,
                "\(label) 在回显态丢了引用块标记"
            )
        }
        #expect(storage.string == source)
    }

    /// 引用内的空行（只有 `>`）与懒续行（没写 `>`）也属于同一个引用块：
    /// 竖条不能在这两种行上断开。懒续行没有 marker 可折叠，只拿块视觉。
    @Test func quoteBlankAndLazyContinuationLinesStayInTheBlock() {
        let source = "> 第一段\n>\n> 第二段\n懒续行"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        let ns = source as NSString
        func blockAt(_ location: Int) -> String? {
            storage.attribute(.museBlock, at: location, effectiveRange: nil) as? String
        }
        #expect(blockAt(ns.range(of: "第一段").location - 2) == BlockVisual.quote.rawValue)
        // 只有 ">" 的空行：行首那个字符本身要带块标记。
        #expect(blockAt(ns.range(of: "\n>\n").location + 1) == BlockVisual.quote.rawValue)
        #expect(blockAt(ns.range(of: "第二段").location - 2) == BlockVisual.quote.rawValue)
        #expect(blockAt(ns.range(of: "懒续行").location) == BlockVisual.quote.rawValue)
        #expect(storage.string == source)
    }

    /// 「第二行引用没有连续」的像素级守卫。
    ///
    /// 属性断言只能证明 `.museBlock` 落到了每一行；竖条是不是真的画出来了要问绘制层。
    /// 多行引用在 TextKit 2 里是**每行一个 fragment**（元素以 `\n` 分段），所以这里要求
    /// 每一个 fragment 都自报 quote，并且每一个都真的落下了墨。
    @Test func everyLineOfMultiLineQuoteDrawsItsBar() {
        let source = "> 第一行\n> 第二行\n> 第三行"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        textView.textContainer?.containerSize = NSSize(
            width: 640, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        let quoteFragments = customFragments(in: textView).filter {
            $0.blockKind == BlockVisual.quote.rawValue
        }
        #expect(quoteFragments.count == 3, "引用块的三行应各有一个自报 quote 的 fragment")
        for (line, fragment) in quoteFragments.enumerated() {
            #expect(
                markerInkColumns(of: fragment) != nil,
                "引用第 \(line + 1) 行没有落下任何墨：竖条在这一行断了"
            )
        }
    }

    /// 嵌套引用：一行上的两个 `>` 分属内外两层，各自折叠自己那一个。
    ///
    /// 旧实现里内外两层的 marker 都从行首空白之后起算，于是同一段字符被抢两次；
    /// 现在每层只吃自己的 `>` 和紧随的一个空格。
    @Test func nestedQuoteMarkersBelongToTheirOwnLevel() {
        let source = "> 外层\n> > 内层"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        let ns = source as NSString
        let nestedLineStart = ns.range(of: "\n> > ").location + 1
        // 两个 ">" 与它们各自后面的空格都要折叠。
        for offset in 0..<4 {
            #expect(isHidden(nestedLineStart + offset, in: storage),
                    "嵌套引用行第 \(offset) 个字符没有折叠")
        }
        #expect(
            storage.attribute(.museBlock, at: nestedLineStart, effectiveRange: nil) as? String
                == BlockVisual.quote.rawValue
        )
        #expect(!isHidden(ns.range(of: "内层").location, in: storage))
        #expect(storage.string == source)
    }

    /// 列表正文列比普通段落正文列**靠右一个缩进步长**（对标 Typora：
    /// `ul, ol { padding-left: 30px }`），续行与首行正文同列。
    @Test func listParagraphIndentsOneStepBeyondBodyText() {
        let source = "- 长列表项内容" + String(repeating: "足够长到可以换行，", count: 20)
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        // 段落样式覆盖整行（含 marker）：NSTextStorage 的段落修复不会把它修回 base
        let paragraph = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.firstLineHeadIndent == Theme.listIndentStep)
        #expect(paragraph?.headIndent == Theme.listIndentStep)
        #expect(Theme.standard.baseParagraph().firstLineHeadIndent == 0)
    }

    /// marker lane 必须放得进缩进步长里。步长小于 lane 宽会把 marker 推到正文
    /// 左缘之外，列表看起来就比正文更靠左——这正是修复前的形态。
    @Test func listIndentStepContainsMarkerLane() {
        #expect(Theme.listIndentStep >= ListMarkerGeometry.defaultMarkerLaneWidth)
    }

    @Test func listParagraphIndentScalesWithDepth() {
        let source = "- 一层\n  - 二层\n    - 三层"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        let paragraphs = [0, 5, 12].compactMap {
            storage.attribute(.paragraphStyle, at: $0, effectiveRange: nil) as? NSParagraphStyle
        }
        #expect(paragraphs.count == 3)
        // 正文列只由语义深度决定。行首源码缩进（0 / 2 / 4 空格）不折叠，但要从
        // 行起点里扣掉，所以 firstLineHeadIndent 逐层比 headIndent 少一段空白宽度，
        // 「行起点 + 可见空白」这个真正的正文列才落在步长的整数倍上。
        let step = Theme.listIndentStep
        let space = (" " as NSString).size(withAttributes: [.font: Theme.standard.baseFont()]).width
        #expect(paragraphs.map(\.headIndent) == [step, 2 * step, 3 * step])
        for (depth, indent) in [0, 2, 4].enumerated() {
            let visibleColumn = paragraphs[depth].firstLineHeadIndent + CGFloat(indent) * space
            #expect(abs(visibleColumn - CGFloat(depth + 1) * step) < 0.5,
                    "第 \(depth + 1) 层正文列 \(visibleColumn) ≠ \(CGFloat(depth + 1) * step)")
        }
        #expect(paragraphs[0].firstLineHeadIndent < paragraphs[1].firstLineHeadIndent)
        #expect(paragraphs[1].firstLineHeadIndent < paragraphs[2].firstLineHeadIndent)
    }

    /// 同一层的条目无论源码缩进写几个空格都落在同一列——缩进由语义深度决定，
    /// 不由用户的书写习惯决定（Typora 也是这样）。
    @Test func listContentColumnIgnoresSourceIndentWidth() throws {
        func column(_ source: String, at location: Int) throws -> CGFloat {
            let storage = NSTextStorage(string: source)
            let package = engine.prepare(source)
            _ = engine.render(package: package, selection: nil, into: storage)
            let paragraph = try #require(
                storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            )
            return paragraph.headIndent
        }
        // 二层用 2 空格 vs 4 空格（两种写法 GFM 都解析成同一深度）。
        let twoSpaces = try column("- 一层\n  - 二层", at: 5)
        let fourSpaces = try column("- 一层\n    - 二层", at: 7)
        #expect(abs(twoSpaces - fourSpaces) < 0.5)
        #expect(abs(twoSpaces - 2 * Theme.listIndentStep) < 0.5)
    }

    /// 核心版式诉求（对标 Typora）：正文与标题共用左缘，列表整块比它们更靠右一步，
    /// 图形 marker 落在这一步撑出的留白里——既不侵占正文列，也不越到正文左缘之外。
    @Test func listBlockIndentsBeyondParagraphColumnWithMarkerInside() throws {
        let source = "# 标题\n\n- 列表项正文\n\n普通段落正文"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        textView.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        func contentX(of needle: String) throws -> CGFloat {
            let resolvedFragment = try #require(customFragments(in: textView).first { fragment in
                let paragraphString = (fragment.textElement as? NSTextParagraph)?
                    .attributedString.string as NSString?
                return paragraphString?.range(of: needle).location != NSNotFound
            })
            let paragraph = try #require(resolvedFragment.textElement as? NSTextParagraph)
                .attributedString.string as NSString
            let firstLine = try #require(resolvedFragment.textLineFragments.first)
            return resolvedFragment.layoutFragmentFrame.minX
                + firstLine.locationForCharacter(at: paragraph.range(of: needle).location).x
        }

        // 正文与标题同列。
        let paragraphX = try contentX(of: "普通段落正文")
        #expect(abs(try contentX(of: "标题") - paragraphX) < 0.5)
        // 列表正文列比它们靠右整一步。
        let listX = try contentX(of: "列表项正文")
        #expect(abs(listX - (paragraphX + Theme.listIndentStep)) < 0.5)

        let fragment = try #require(customFragments(in: textView).first {
            $0.blockKind == BlockVisual.list.rawValue + ":u"
        })
        let drawPoint = markerDrawPoint(for: fragment)
        let ink = try #require(markerInkBounds(of: fragment, at: drawPoint))
        // marker 墨迹整体落在正文列左侧、宽 defaultMarkerLaneWidth 的预算槽内。
        #expect(ink.maxX <= drawPoint.x - ListMarkerGeometry.markerGap + 0.5)
        #expect(ink.minX >= drawPoint.x - ListMarkerGeometry.defaultMarkerLaneWidth - 0.5)
        // 且这个槽整体在段落正文列**右侧**：marker 不越到正文左缘之外。
        #expect(drawPoint.x - ListMarkerGeometry.defaultMarkerLaneWidth >= paragraphX - 0.5)
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

        let inkColumns = fragments.map(markerInkColumns(of:))
        #expect(inkColumns.allSatisfy { $0 != nil })
        let ink = inkColumns.compactMap { $0 }
        #expect(ink.count == 3)
        guard ink.count == 3 else { return }
        // 每层的 marker 墨迹**右缘**紧贴自己那层的正文列，所以逐层右移正好一个
        // 缩进步长。这里断言右缘而不是左缘：三层用 •/◦/▪ 三个字形，墨迹宽度不同，
        // 左缘的差会带上字形宽度差（实测 •→◦ 差 9pt），右缘才是几何契约。
        // 这条测试量的是**真实绘制的像素**，不是并行的坐标计算。
        let step = Int(Theme.listIndentStep.rounded())
        #expect(abs(ink[1].maxX - ink[0].maxX - step) <= 2)
        #expect(abs(ink[2].maxX - ink[1].maxX - step) <= 2)
        #expect(ink[1].minX > ink[0].minX)
        #expect(ink[2].minX > ink[1].minX)
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
        #expect(abs(markerFrame.midY - (bodyXHeightCenterY - 1.5)) < 0.5)
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
        #expect(abs(markerBaselineY - (contentBaselineY - 1.5)) < 0.5)
    }

    @Test func unorderedMarkerAlignsWithFirstVisibleInlineContent() throws {
        let source = "- **粗体开头** 与普通正文"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 160)
        textView.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let fragment = try #require(customFragments(in: textView).first {
            $0.blockKind == BlockVisual.list.rawValue + ":u"
        })
        let firstLine = try #require(fragment.textLineFragments.first)
        let drawPoint = markerDrawPoint(for: fragment)
        let markerFrame = try #require(fragment.listMarkerFrame(at: drawPoint))
        let visibleContentLocation = (source as NSString).range(of: "粗").location
        let visibleBodyFont = try #require(font(at: visibleContentLocation, in: storage))
        let expectedCenterY = drawPoint.y + firstLine.glyphOrigin.y - visibleBodyFont.xHeight / 2

        // The first source characters after "- " are hidden Markdown markers.
        // Their 0.1pt font must not pull the replacement bullet down toward
        // the baseline; align against the first visible inline run instead.
        #expect(abs(markerFrame.midY - (expectedCenterY - 1.5)) < 0.5)
    }

    private func listFragment(
        containing needle: String,
        in textView: EditorTextView
    ) throws -> (fragment: MuseLayoutFragment, paragraph: NSString, location: Int) {
        let fragment = try #require(customFragments(in: textView).first { fragment in
            guard fragment.blockKind?.hasPrefix(BlockVisual.list.rawValue + ":") == true,
                  let paragraph = fragment.textElement as? NSTextParagraph else { return false }
            return (paragraph.attributedString.string as NSString).range(of: needle).location != NSNotFound
        })
        let paragraph = try #require(fragment.textElement as? NSTextParagraph).attributedString.string as NSString
        let location = paragraph.range(of: needle).location
        #expect(location != NSNotFound)
        return (fragment, paragraph, location)
    }

    private func listContentX(
        containing needle: String,
        in textView: EditorTextView
    ) throws -> CGFloat {
        let resolved = try listFragment(containing: needle, in: textView)
        let firstLine = try #require(resolved.fragment.textLineFragments.first)
        return resolved.fragment.layoutFragmentFrame.minX
            + firstLine.locationForCharacter(at: resolved.location).x
    }

    /// 完成的任务项**不改文字颜色**。
    ///
    /// 实测 Typora 默认主题的截图：勾选行与未勾选行的文字色完全相同。变化只在
    /// 复选框本身（描边框 → 蓝色实心块 + 白勾）。压暗、删除线都是别的编辑器的
    /// 做法，这里不引入——这条测试就是防它被顺手加回来。
    @Test func completedTaskItemKeepsBodyTextColorAndHasNoStrikethrough() {
        let source = "- [ ] 未完成\n- [x] 已完成"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)

        let ns = source as NSString
        func attribute(_ key: NSAttributedString.Key, at label: String) -> Any? {
            storage.attribute(key, at: ns.range(of: label).location, effectiveRange: nil)
        }
        #expect(attribute(.foregroundColor, at: "已完成") as? NSColor == Theme.standard.text)
        #expect(
            attribute(.foregroundColor, at: "已完成") as? NSColor
                == attribute(.foregroundColor, at: "未完成") as? NSColor
        )
        #expect(attribute(.strikethroughStyle, at: "已完成") == nil)
        #expect(storage.string == source)
    }


    /// 复选框的两种状态**画出来**必须不同：勾选是强调色实心块，未勾选是中性描边框。
    ///
    /// 属性断言在这里帮不上忙——`museTaskChecked` 只是个布尔，方框是绘制层画的。
    /// 这条量方框范围内的均色：勾选偏蓝（强调色填充占了整块），未勾选中性。
    @Test func checkedAndUncheckedCheckboxesDrawDifferently() throws {
        func meanColor(checked: Bool) throws -> [CGFloat] {
            let source = checked ? "- [x] 任务" : "- [ ] 任务"
            let storage = NSTextStorage(string: source)
            let textView = EditorTextView.make(textStorage: storage)
            textView.frame = NSRect(x: 0, y: 0, width: 480, height: 160)
            textView.textContainer?.containerSize = NSSize(
                width: 480, height: CGFloat.greatestFiniteMagnitude)
            let package = engine.prepare(source)
            _ = engine.render(package: package, selection: nil, into: storage)

            let fragment = try #require(customFragments(in: textView).first {
                $0.blockKind == BlockVisual.list.rawValue + ":t"
            })
            return try #require(markerMeanColor(of: fragment))
        }

        let checked = try meanColor(checked: true)
        let unchecked = try meanColor(checked: false)
        #expect(checked != unchecked)
        #expect(checked[2] - checked[0] > 0.1, "勾选态应偏蓝（强调色填充）：\(checked)")
        #expect(abs(unchecked[2] - unchecked[0]) < 0.03, "未勾选态应中性：\(unchecked)")
    }

    /// 小手光标的范围必须**恒等于**真正能点中的范围。
    ///
    /// 两者分开算过一次就会漂：显示可点却点不动，或者反过来。这里断言每个光标矩形
    /// 的中心都被点击命中判定接受，且数量与任务项数一致。
    @Test func taskCheckboxCursorRectsMatchTheClickableRegion() throws {
        let source = "- [ ] 待办一\n- [x] 完成\n普通段落\n- [ ] 待办二"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        textView.textContainer?.containerSize = NSSize(
            width: 480, height: CGFloat.greatestFiniteMagnitude)

        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        let rects = textView.taskCheckboxCursorRects()
        #expect(rects.count == 3, "三个任务项应各有一块小手区域，实得 \(rects.count)")
        for rect in rects {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            #expect(
                textView.taskCheckboxToggleRange(at: center) != nil,
                "光标矩形 \(rect) 的中心点击不中复选框"
            )
        }
    }

    /// 复选框始终是复选框：光标落在任务行、甚至整行被拖选，都不把 `- [ ] `
    /// 变回源码（对标 Typora）。
    ///
    /// 它是可点击的控件，不是装饰：回显源码会让控件在编辑时消失，「点一下切换」
    /// 也就失去落点。只有源码模式才逐字显示——那条路与光标无关。
    @Test func taskCheckboxNeverRevealsSourceUnderCaretOrSelection() {
        for source in ["- [ ] 待办", "- [x] 完成", "  - [ ] 嵌套待办"] {
            let ns = source as NSString
            let markerStart = ns.range(of: "-").location
            let contentStart = ns.range(of: "待办").location != NSNotFound
                ? ns.range(of: "待办").location
                : ns.range(of: "完成").location

            for selection in [
                NSRange(location: contentStart, length: 0),        // 光标在正文里
                NSRange(location: markerStart, length: 0),         // 光标贴在 marker 前
                NSRange(location: 0, length: ns.length),           // 整行拖选
            ] {
                let storage = NSTextStorage(string: source)
                let package = engine.prepare(source)
                _ = engine.render(package: package, selection: selection, into: storage)
                #expect(
                    isHidden(markerStart, in: storage),
                    "选区 \(selection) 下 \"\(source)\" 的复选框回显成了源码"
                )
                #expect(storage.string == source)
            }
        }
    }

    /// 源码模式仍然逐字显示 `- [ ] `：不回显是「跟随光标」这条规则的例外，
    /// 不是把任务标记从源码模式里也藏起来。
    @Test func taskCheckboxShowsLiteralSourceInSourceMode() {
        let source = "- [x] 完成"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, mode: .source, into: storage)

        #expect(!isHidden((source as NSString).range(of: "-").location, in: storage))
        #expect(storage.string == source)
    }

    @Test func revealedListSourceMarkerKeepsEveryContentColumnStable() throws {
        let sources = [
            "- 目标", "* 目标", "+ 目标",
            "1. 目标", "10. 目标", "100. 目标", "10000. 目标",
            "- 一级\n  - 目标",
            "- 一级\n  - 二级\n    - 目标",
            "1. 一级\n   1. 目标",
            "1. 一级\n   1. 二级\n      1. 目标",
        ]

        func snapshot(_ source: String, selection: NSRange?) throws -> (contentX: CGFloat, markerX: CGFloat, prefixWidth: CGFloat) {
            let storage = NSTextStorage(string: source)
            let textView = EditorTextView.make(textStorage: storage)
            textView.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
            textView.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)

            let package = engine.prepare(source)
            _ = engine.render(package: package, selection: selection, into: storage)
            let resolved = try listFragment(containing: "目标", in: textView)
            let firstLine = try #require(resolved.fragment.textLineFragments.first)
            let markerX = resolved.fragment.layoutFragmentFrame.minX
                + firstLine.locationForCharacter(at: 0).x
            let contentX = resolved.fragment.layoutFragmentFrame.minX
                + firstLine.locationForCharacter(at: resolved.location).x
            // 行首到内容之间的可见前缀宽度：缩进按正文字体（两种状态一致），
            // marker 源码按回显等宽字体。
            let visiblePrefix = resolved.paragraph.substring(to: resolved.location)
            let indentPart = visiblePrefix.prefix { $0 == " " || $0 == "\t" }
            let markerPart = visiblePrefix.drop { $0 == " " || $0 == "\t" }
            let prefixWidth = ((String(indentPart)) as NSString)
                .size(withAttributes: [.font: Theme.standard.baseFont()]).width
                + ((String(markerPart)) as NSString)
                    .size(withAttributes: [.font: Theme.standard.revealedMarkerFont()]).width
            if selection != nil {
                let caretXs = (0...resolved.location).map {
                    firstLine.locationForCharacter(at: $0).x
                }
                #expect(contentX > markerX, "source marker has no visible lane: \(source)")
                #expect(zip(caretXs, caretXs.dropFirst()).allSatisfy { $0 <= $1 }, "caret order: \(source)")
            }
            #expect(storage.string == source)
            return (contentX, markerX, prefixWidth)
        }

        for source in sources {
            let contentLocation = (source as NSString).range(of: "目标").location
            let hidden = try snapshot(source, selection: nil)
            let revealed = try snapshot(
                source,
                selection: NSRange(location: contentLocation, length: 0)
            )
            let hiddenAgain = try snapshot(source, selection: nil)

            // 回显正文列：优先保持隐藏列；前缀放不下时右移（TextKit 2 不接受负行起点），
            // 收起后必须精确回到原列。
            let expectedRevealedContentX = max(hidden.contentX, revealed.markerX + revealed.prefixWidth)
            #expect(abs(revealed.contentX - expectedRevealedContentX) < 0.5, "source: \(source)")
            #expect(abs(hiddenAgain.contentX - hidden.contentX) < 0.5, "source: \(source)")
            #expect(revealed.markerX >= -0.5, "source marker clipped: \(source)")
        }
    }

    /// 点进列表行不该让正文横向跳动。
    ///
    /// 修复前一级列表的内容列在 0，回显 `- ` 需要 18pt 却没有余量，TextKit 2 钳掉
    /// 负行起点后整行右移 18pt——每次点进/点出列表都跳一下。内容列改成一步缩进
    /// （28pt）之后常见前缀都放得下，位移为零。任务项从不回显源码（复选框始终
    /// 是复选框），所以 `- [ ] ` 这个 6 字符前缀也不再有位移可言。
    @Test func caretEnteringCommonListItemDoesNotShiftContent() throws {
        for source in [
            "- 目标", "* 目标", "+ 目标", "1. 目标", "- 一级\n  - 目标",
            "- [ ] 目标", "- [x] 目标",
        ] {
            func contentX(selection: NSRange?) throws -> CGFloat {
                let storage = NSTextStorage(string: source)
                let textView = EditorTextView.make(textStorage: storage)
                textView.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
                textView.textContainer?.containerSize = NSSize(
                    width: 480, height: CGFloat.greatestFiniteMagnitude
                )
                let package = engine.prepare(source)
                _ = engine.render(package: package, selection: selection, into: storage)
                let resolved = try listFragment(containing: "目标", in: textView)
                let firstLine = try #require(resolved.fragment.textLineFragments.first)
                return resolved.fragment.layoutFragmentFrame.minX
                    + firstLine.locationForCharacter(at: resolved.location).x
            }
            let caret = NSRange(location: (source as NSString).range(of: "目标").location, length: 0)
            let revealed = try contentX(selection: caret)
            let hidden = try contentX(selection: nil)
            #expect(abs(revealed - hidden) < 0.5, "点进 \"\(source)\" 时正文列跳动了")
        }
    }

    @Test func coordinatorRevealAndHideKeepEveryListContentColumnStable() throws {
        let listSources = [
            "- 目标", "10. 目标", "100. 目标",
            "- [ ] 目标", "- [x] 目标",
            "- 一级\n  - 二级\n    - 目标",
            "1. 一级\n   1. 目标",
        ]

        for listSource in listSources {
            let source = listSource + "\n\n普通段落"
            let storage = NSTextStorage(string: source)
            let textView = EditorTextView.make(textStorage: storage)
            textView.frame = NSRect(x: 0, y: 0, width: 480, height: 260)
            textView.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
            let package = engine.prepare(source)
            let plainLocation = (source as NSString).range(of: "普通段落").location
            _ = engine.render(
                package: package,
                selection: NSRange(location: plainLocation, length: 0),
                into: storage
            )

            let hiddenX = try listContentX(containing: "目标", in: textView)
            let coordinator = RenderCoordinator()
            coordinator.adoptPackage(package)
            let contentLocation = (source as NSString).range(of: "目标").location
            coordinator.updateMarkerVisibility(
                selection: NSRange(location: contentLocation, length: 0),
                into: storage
            )
            let revealedX = try listContentX(containing: "目标", in: textView)
            // 回显允许右移（前缀放不下时），但不允许左移。
            #expect(revealedX >= hiddenX - 0.5, "source: \(source)")

            coordinator.updateMarkerVisibility(
                selection: NSRange(location: plainLocation, length: 0),
                into: storage
            )
            let hiddenAgainX = try listContentX(containing: "目标", in: textView)
            #expect(abs(hiddenAgainX - hiddenX) < 0.5, "source: \(source)")
            #expect(storage.string == source)
        }
    }

    @Test func revealedListSourceKeepsSoftWrapContinuationStable() throws {
        let source = "- [ ] 目标" + String(repeating: " 很长的列表正文", count: 24)
        let target = (source as NSString).range(of: "目标").location

        func positions(selection: NSRange?) throws -> (content: CGFloat, continuation: CGFloat) {
            let storage = NSTextStorage(string: source)
            let textView = EditorTextView.make(textStorage: storage)
            textView.frame = NSRect(x: 0, y: 0, width: 260, height: 520)
            textView.textContainer?.containerSize = NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude)
            let package = engine.prepare(source)
            _ = engine.render(package: package, selection: selection, into: storage)
            let resolved = try listFragment(containing: "目标", in: textView)
            #expect(resolved.fragment.textLineFragments.count >= 2)
            let first = try #require(resolved.fragment.textLineFragments.first)
            let second = try #require(resolved.fragment.textLineFragments.dropFirst().first)
            return (
                resolved.fragment.layoutFragmentFrame.minX + first.locationForCharacter(at: resolved.location).x,
                resolved.fragment.layoutFragmentFrame.minX + second.typographicBounds.minX
            )
        }

        let hidden = try positions(selection: nil)
        let revealed = try positions(selection: NSRange(location: target, length: 0))
        // 任务前缀宽于正文列时回显右移；收起后回到原列（回归由
        // revealedListSourceMarkerKeepsEveryContentColumnStable 覆盖）。
        #expect(revealed.content >= hidden.content - 0.5)
        #expect(abs(revealed.continuation - hidden.continuation) < 0.5)
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
        let inkBounds = try fragments.enumerated().map { index, fragment in
            try #require(markerInkBounds(of: fragment, at: points[index]))
        }
        // 预算槽的左缘对 1. 和 2. 稳定（槽只决定缩不缩字号，不决定落点）。
        let lanes = try fragments.enumerated().map { index, fragment in
            try #require(fragment.listMarkerLaneFrame(at: points[index]))
        }
        #expect(abs(lanes[0].minX - lanes[1].minX) < 0.01)
        // 落点契约是墨迹**右缘**贴正文列：所以 1. 和 2. 的句点对齐（浏览器/Typora
        // 的 `list-style-position: outside` 就是这样），而不是数字起笔对齐——实测
        // 系统字体的 1 比 2 窄 2pt，强行对齐起笔就会让句点参差。
        #expect(abs(inkBounds[0].maxX - inkBounds[1].maxX) < 1)

        // 98./99./100. 不许把正文列推走：墨迹留在正文列左侧的预算槽内，
        // 需要时缩字号。
        for index in 0..<5 {
            #expect(inkBounds[index].maxX <= points[index].x - ListMarkerGeometry.markerGap + 0.5)
            #expect(inkBounds[index].minX
                    >= points[index].x - ListMarkerGeometry.defaultMarkerLaneWidth - 0.5)
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
        let orderedLane = try #require(ordered.listMarkerLaneFrame(at: orderedPoint))
        let unorderedLane = try #require(unordered.listMarkerLaneFrame(at: unorderedPoint))
        #expect(abs(orderedLane.minX - unorderedLane.minX) < 0.01)
        let orderedInk = try #require(markerInkBounds(of: ordered, at: orderedPoint))
        let unorderedInk = try #require(markerInkBounds(of: unordered, at: unorderedPoint))
        // 有序与无序共用同一条正文列，且墨迹右缘都贴在它左侧 markerGap 处。
        // 宽度不同的 `1.` 与 `•` 因此右缘对齐、左缘不对齐——这是 Typora /
        // 浏览器 `list-style-position: outside` 的模型，也让窄 marker 不会离正文
        // 空出一大截（左对齐在预算槽里就会）。
        #expect(abs(orderedInk.maxX - unorderedInk.maxX) < 1)
        // `1.` 的墨迹比 `•` 宽，右缘对齐后它自然向左伸得更远。
        #expect(orderedInk.minX < unorderedInk.minX)

        // Convert each line-local location into the same draw coordinate space
        // used by the marker frame and bitmap assertions.
        let orderedContentX = orderedPoint.x + orderedLine.locationForCharacter(at: 3).x
        let unorderedContentX = unorderedPoint.x + unorderedLine.locationForCharacter(at: 2).x
        #expect(abs(orderedContentX - unorderedContentX) < 0.5)
        #expect(orderedInk.maxX <= orderedPoint.x - ListMarkerGeometry.markerGap + 0.5)
        #expect(unorderedInk.maxX <= unorderedPoint.x - ListMarkerGeometry.markerGap + 0.5)
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
    private func markerInkColumns(of fragment: MuseLayoutFragment) -> (minX: Int, maxX: Int)? {
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
        return (minX, maxX)
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

    /// 走真实 fragment 绘制路径，量 marker 方框范围内的**均色**。
    ///
    /// 复选框的两种状态在属性层看不出区别（`museTaskChecked` 只是个布尔），方框由
    /// 绘制层画，只能量像素。刻意取均色而不是单点：方框正中会落在白勾上，单点读到
    /// 的是白与蓝的混合，阈值就得贴着某个系统版本的具体绘制去调；均色对整块填充
    /// 敏感、对勾的粗细不敏感。
    private func markerMeanColor(of fragment: MuseLayoutFragment) -> [CGFloat]? {
        let width = 480
        let height = 160
        // marker 悬挂在 fragment 原点左侧，直接按原点绘制会画到画布外——整体右移一段。
        let drawOrigin = CGPoint(x: fragment.layoutFragmentFrame.origin.x + 60, y: 20)
        guard let markerFrame = fragment.listMarkerFrame(at: drawOrigin),
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
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.setFillColor(NSColor.white.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        fragment.drawBlockVisuals(at: drawOrigin, in: context.cgContext)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // 绘制坐标是左上原点，`colorAt` 也按位图行自顶向下寻址，但 CGContext 的位图
        // 是左下原点——所以采样行要镜像一次。
        var sum = [CGFloat](repeating: 0, count: 3)
        var count = 0
        for drawX in Int(markerFrame.minX.rounded())..<Int(markerFrame.maxX.rounded()) {
            for drawY in Int(markerFrame.minY.rounded())..<Int(markerFrame.maxY.rounded()) {
                let x = min(width - 1, max(0, drawX))
                let y = min(height - 1, max(0, height - 1 - drawY))
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                sum[0] += c.redComponent
                sum[1] += c.greenComponent
                sum[2] += c.blueComponent
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / CGFloat(count) }
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
