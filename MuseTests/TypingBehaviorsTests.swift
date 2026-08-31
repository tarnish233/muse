import AppKit
import Testing
@testable import MuseKit

@Suite @MainActor struct TypingBehaviorsTests {
    struct NewlineCase: Sendable {
        let source: String
        let caret: Int
        let expectedSource: String
        let expectedCaret: Int
    }

    struct LineEndingTransferCase: Sendable {
        let source: String
        let expected: String
    }

    private func host(_ textView: EditorTextView, size: NSSize = NSSize(width: 320, height: 160)) -> NSWindow {
        textView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        window.makeFirstResponder(textView)
        return window
    }

    private func markerInkBounds(of fragment: MuseLayoutFragment) -> CGRect? {
        let scale: CGFloat = 4
        let width = 320
        let height = 120
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
        // 悬挂式 marker 画在 fragment 原点左侧一个 lane 的位置，孤立位图要先
        // 垫出这块引导空间；返回值再平移回去，与生产容器坐标保持一致。
        let lane = ListMarkerGeometry.defaultMarkerLaneWidth
        let origin = fragment.layoutFragmentFrame.origin
        fragment.drawBlockVisuals(
            at: CGPoint(x: origin.x + lane, y: origin.y),
            in: context.cgContext
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        var minColumn: Int?
        var maxColumn: Int?
        var minRow: Int?
        var maxRow: Int?
        for row in 0..<bitmap.pixelsHigh {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let pixelStart = rowStart + column * bytesPerPixel
                let pixel = UnsafeBufferPointer(start: data + pixelStart, count: bytesPerPixel)
                guard pixel.prefix(3).contains(where: { $0 < 245 }) else { continue }
                minColumn = min(minColumn ?? column, column)
                maxColumn = max(maxColumn ?? column, column)
                minRow = min(minRow ?? row, row)
                maxRow = max(maxRow ?? row, row)
            }
        }
        guard let minColumn, let maxColumn, let minRow, let maxRow else { return nil }
        return CGRect(
            x: CGFloat(minColumn) / scale - lane,
            y: CGFloat(bitmap.pixelsHigh - maxRow - 1) / scale,
            width: CGFloat(maxColumn - minColumn + 1) / scale,
            height: CGFloat(maxRow - minRow + 1) / scale
        )
    }

    private func typeAcrossRunLoopTurns(_ input: String, in textView: EditorTextView) {
        for character in input {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }

    private func temporaryDocumentURL() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusePasteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return (directory, directory.appendingPathComponent("note.md"))
    }

    private func autosave(_ document: MuseDocument, to url: URL) async throws {
        document.fileURL = url
        document.fileType = "net.daringfireball.markdown"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.autosave(withImplicitCancellability: false) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @Test(arguments: [
        LineEndingTransferCase(source: "alpha\r\nbeta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\rbeta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\u{0085}beta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\u{2028}beta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\u{2029}beta", expected: "alpha\nbeta"),
    ])
    func pastedTextUsesOnlyLF(testCase: LineEndingTransferCase) {
        let storage = NSTextStorage()
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer {
            window.contentView = nil
            NSPasteboard.general.clearContents()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(testCase.source, forType: .string)

        textView.paste(nil)

        #expect(storage.string == testCase.expected)
    }

    @Test func pastedCRLFUndoIsExactlyOneSafeStep() throws {
        let storage = NSTextStorage(string: "start")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer {
            window.contentView = nil
            NSPasteboard.general.clearContents()
        }
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("a\r\nb", forType: .string)

        textView.paste(nil)

        let undoManager = try #require(textView.undoManager)
        #expect(storage.string == "starta\nb")
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(storage.string == "start")
        #expect(undoManager.canUndo == false)
    }

    @Test func pastingExistingLFKeepsLineBreak() {
        let storage = NSTextStorage()
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer {
            window.contentView = nil
            NSPasteboard.general.clearContents()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("alpha\nbeta", forType: .string)

        textView.paste(nil)

        #expect(storage.string == "alpha\nbeta")
    }

    @Test(arguments: [
        LineEndingTransferCase(source: "alpha\r\nbeta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\rbeta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\u{0085}beta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\u{2028}beta", expected: "alpha\nbeta"),
        LineEndingTransferCase(source: "alpha\u{2029}beta", expected: "alpha\nbeta"),
    ])
    func droppedTextUsesOnlyLF(testCase: LineEndingTransferCase) {
        let pasteboard = NSPasteboard(name: .init("MuseTests.Drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(testCase.source, forType: .string)
        let storage = NSTextStorage()
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }

        let accepted = textView.readSelection(from: pasteboard, type: .string)

        #expect(accepted)
        #expect(storage.string == testCase.expected)
    }

    @Test func pastedCRLFDoesNotBecomeDoubleCarriageReturnOnCRLFSave() async throws {
        let paths = try temporaryDocumentURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }

        let document = MuseDocument()
        try document.read(
            from: Data("first\r\n".utf8),
            ofType: "net.daringfireball.markdown"
        )
        let textView = EditorTextView.make(textStorage: document.buffer.textStorage)
        let window = host(textView)
        defer {
            window.contentView = nil
            NSPasteboard.general.clearContents()
        }
        textView.setSelectedRange(NSRange(location: document.buffer.textStorage.length, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("second\r\nthird", forType: .string)

        textView.paste(nil)
        try await autosave(document, to: paths.file)

        let bytes = try Data(contentsOf: paths.file)
        #expect(bytes == Data("first\r\nsecond\r\nthird".utf8))
        #expect(bytes.range(of: Data([0x0D, 0x0D, 0x0A])) == nil)
    }

    @Test(
        "List Enter continues the recognized marker",
        arguments: [
            NewlineCase(source: "- item", caret: 6, expectedSource: "- item\n- ", expectedCaret: 9),
            NewlineCase(source: "  + item", caret: 8, expectedSource: "  + item\n  + ", expectedCaret: 13),
            NewlineCase(source: "9. item", caret: 7, expectedSource: "9. item\n9. ", expectedCaret: 11),
            NewlineCase(source: "99) item", caret: 8, expectedSource: "99) item\n99) ", expectedCaret: 13),
            NewlineCase(source: "1. a\n2. b", caret: 4, expectedSource: "1. a\n1. \n2. b", expectedCaret: 8),
            NewlineCase(source: "01. a", caret: 5, expectedSource: "01. a\n01. ", expectedCaret: 10),
            NewlineCase(source: "- [x] done", caret: 10, expectedSource: "- [x] done\n- [x] ", expectedCaret: 17),
            NewlineCase(source: "- [x] buy milk", caret: 6, expectedSource: "- [x] \n- [x] buy milk", expectedCaret: 13),
            NewlineCase(source: "- [X] done", caret: 6, expectedSource: "- [X] \n- [X] done", expectedCaret: 13),
            NewlineCase(source: "- alpha beta", caret: 8, expectedSource: "- alpha \n- beta", expectedCaret: 11),
            NewlineCase(source: "- item   ", caret: 9, expectedSource: "- item   \n- ", expectedCaret: 12),
            NewlineCase(source: "- line one  ", caret: 12, expectedSource: "- line one  \n- ", expectedCaret: 15),
            NewlineCase(source: "    07) nested", caret: 14, expectedSource: "    07) nested\n    07) ", expectedCaret: 23),
            NewlineCase(source: ">   - [X] child", caret: 15, expectedSource: ">   - [X] child\n>   - [X] ", expectedCaret: 26),
        ]
    )
    func listContinuation(testCase: NewlineCase) throws {
        let source = testCase.source as NSString
        let edit = try #require(TypingBehaviors.newlineEdit(
            in: source,
            selection: NSRange(location: testCase.caret, length: 0),
            blockContext: .list(depth: 1)
        ))
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)

        #expect(mutable as String == testCase.expectedSource)
        #expect(edit.selectionAfter == NSRange(location: testCase.expectedCaret, length: 0))
    }

    @Test(
        "Empty list item exits in one replacement",
        arguments: ["- ", "  +   ", "3. ", "- [ ] ", "\t- [x]\t"]
    )
    func emptyListExit(source: String) throws {
        let edit = try #require(TypingBehaviors.newlineEdit(
            in: source as NSString,
            selection: NSRange(location: (source as NSString).length, length: 0),
            blockContext: .list(depth: 1)
        ))
        #expect(edit.range == NSRange(location: 0, length: (source as NSString).length))
        #expect(edit.replacement == "")
        #expect(edit.selectionAfter == NSRange(location: 0, length: 0))
    }

    @Test func headingContentStartCreatesPlainLineBeforeHeading() throws {
        let source = "# Heading" as NSString
        let edit = try #require(TypingBehaviors.newlineEdit(
            in: source,
            selection: NSRange(location: 2, length: 0),
            blockContext: .heading
        ))
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)

        #expect(mutable as String == "\n# Heading")
        #expect(edit.selectionAfter == NSRange(location: 0, length: 0))
    }

    @Test func emptyHeadingExitsHeading() throws {
        let source = "### " as NSString
        let edit = try #require(TypingBehaviors.newlineEdit(
            in: source,
            selection: NSRange(location: source.length, length: 0),
            blockContext: .heading
        ))
        #expect(edit.range == NSRange(location: 0, length: source.length))
        #expect(edit.replacement == "")
    }

    @Test(
        "Non-ASCII whitespace remains list content",
        arguments: ["\u{3000}", "\u{00A0}"]
    )
    func nonASCIIWhitespaceDoesNotExitList(character: String) throws {
        let source = "- " + character
        let edit = try #require(TypingBehaviors.newlineEdit(
            in: source as NSString,
            selection: NSRange(location: (source as NSString).length, length: 0),
            blockContext: .list(depth: 1)
        ))
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)

        #expect(mutable as String == source + "\n- ")
    }

    @Test func fullWidthSpaceDoesNotExitHeading() throws {
        let source = "# \u{3000}" as NSString
        let edit = try #require(TypingBehaviors.newlineEdit(
            in: source,
            selection: NSRange(location: 2, length: 0),
            blockContext: .heading
        ))
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)

        #expect(mutable as String == "\n# \u{3000}")
    }

    @Test func nativeNewlineIsPreservedOutsideConservativeContexts() {
        #expect(TypingBehaviors.newlineEdit(
            in: "paragraph" as NSString,
            selection: NSRange(location: 9, length: 0),
            blockContext: .other
        ) == nil)
        #expect(TypingBehaviors.newlineEdit(
            in: "- item" as NSString,
            selection: NSRange(location: 0, length: 2),
            blockContext: .list(depth: 1)
        ) == nil)
        #expect(TypingBehaviors.newlineEdit(
            in: "# Heading" as NSString,
            selection: NSRange(location: 5, length: 0),
            blockContext: .heading
        ) == nil)
    }

    @Test(
        "Smart newline follows AST-backed block context",
        arguments: [
            NewlineCase(
                source: "```\n- item\n```",
                caret: 10,
                expectedSource: "```\n- item\n```",
                expectedCaret: 10
            ),
            NewlineCase(
                source: "    - item",
                caret: 10,
                expectedSource: "    - item",
                expectedCaret: 10
            ),
            NewlineCase(
                source: "- - -",
                caret: 5,
                expectedSource: "- - -",
                expectedCaret: 5
            ),
            NewlineCase(
                source: "* * *",
                caret: 5,
                expectedSource: "* * *",
                expectedCaret: 5
            ),
        ]
    )
    func nonListBlocksDoNotContinueListMarkers(testCase: NewlineCase) {
        let storage = NSTextStorage(string: testCase.source)
        let engine = RenderEngine()
        let package = engine.prepare(testCase.source)
        _ = engine.render(
            package: package,
            selection: nil,
            into: storage
        )
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: testCase.caret, length: 0))

        #expect(textView.performSmartNewline() == false)
        #expect(storage.string == testCase.expectedSource)
        #expect(textView.selectedRange() == NSRange(location: testCase.expectedCaret, length: 0))
    }

    @Test(
        "Lists continue at nested depths and inside block quotes",
        arguments: [
            NewlineCase(
                source: "- parent\n  - nested",
                caret: 19,
                expectedSource: "- parent\n  - nested\n  - ",
                expectedCaret: 24
            ),
            NewlineCase(
                source: "> - item",
                caret: 8,
                expectedSource: "> - item\n> - ",
                expectedCaret: 13
            ),
        ]
    )
    func contextualListsContinue(testCase: NewlineCase) {
        let storage = NSTextStorage(string: testCase.source)
        let engine = RenderEngine()
        let package = engine.prepare(testCase.source)
        _ = engine.render(
            package: package,
            selection: nil,
            into: storage
        )
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: testCase.caret, length: 0))

        #expect(textView.performSmartNewline())
        #expect(storage.string == testCase.expectedSource)
        #expect(textView.selectedRange() == NSRange(location: testCase.expectedCaret, length: 0))
    }

    // MARK: - 渲染滞后窗口（缺陷 17）
    //
    // 以下测试都**不**提供 renderPackageProvider，且在输入之后**不**重新渲染，
    // 以此复现真实的渲染滞后窗口：实测从最后一次按键到 `.museBlock` 落地是
    // 20KB 37.9ms、200KB 343.3ms、1MB 1828.4ms，而人按 Enter 只隔 100–200ms。
    // 上面那些用例都预渲染并交出一个等长的包，所以测不到这个窗口。

    /// 情形 1+2：段落后新起一行输入列表项，渲染尚未追上。
    /// 新输入的 `- ` 继承的是段落属性，所以属性层给不出块上下文。
    @Test func newListAfterParagraphContinuesBeforeRenderCatchesUp() {
        let source = "正文段落\n"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        typeAcrossRunLoopTurns("- item", in: textView)

        #expect(textView.performSmartNewline())
        #expect(storage.string == "正文段落\n- item\n- ")
    }

    /// 情形 4：光标停在行终止符上。列表的 `.museBlock` 不覆盖 `\n`，
    /// 所以读到的是**下一个**块的属性。与时序无关，稳定复现。
    @Test func listContinuesWithCaretOnLineTerminator() {
        let source = "- item\nnext"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        #expect(textView.performSmartNewline())
        #expect(storage.string == "- item\n- \nnext")
    }

    /// 情形 3：引用内的列表。列表是更具体的交互语义，所以 `.museBlock` 最终
    /// 保留 list；引用的背景/前景属性仍叠在同一行，容器视觉没有丢失。
    @Test func quotedListContinuesFromSurvivingMarkerAttributes() {
        let source = "> - item"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        #expect(
            storage.attribute(.museBlock, at: 7, effectiveRange: nil) as? String
                == BlockVisual.list.rawValue + ":u",
            "引用内列表应保留可供续行读取的具体列表语义"
        )
        #expect(storage.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? NSColor
                == Theme.standard.quoteBackground,
                "列表语义覆盖 .museBlock 时，引用容器视觉仍应保留")
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        #expect(textView.performSmartNewline())
        #expect(storage.string == "> - item\n> - ")
    }

    /// 缺陷 8 的否决必须在没有新鲜包时依然成立：围栏的 `.museBlock` 覆盖整个块
    /// （含行终止符），新输入靠 typingAttributes 继承，所以围栏内一定读得到。
    @Test func fencedCodeRefusesContinuationWithoutFreshPackage() {
        let source = "```\ncode\n```\n"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        typeAcrossRunLoopTurns("\n- item", in: textView)
        let before = storage.string

        #expect(textView.performSmartNewline() == false)
        #expect(storage.string == before)
    }

    /// 分隔线与缩进代码块都没有可继承的 `.museBlock`，所以回退层必须自己拦住。
    /// 这两条都是行内局部判定，不需要块上下文。
    @Test(arguments: [
        "````\n- item\n````",
        "```swift\n- item\n```",
        "~~~~ markdown\n- item\n~~~~",
    ])
    func arbitraryLengthFencesRefuseListContinuation(source: String) throws {
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let itemRange = (source as NSString).range(of: "- item")
        textView.setSelectedRange(NSRange(location: NSMaxRange(itemRange), length: 0))

        #expect(textView.performSmartNewline() == false)
        #expect(storage.string == source)
    }

    @Test(arguments: ["- - -", "* * *", "___", "    - item", "\t- item"])
    func lineLocalBlocksRefuseContinuationWithoutRender(source: String) {
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

        #expect(textView.performSmartNewline() == false)
        #expect(storage.string == source)
    }

    /// 2 空格嵌套（Markdown 常见风格）在滞后窗口里仍要能续行——
    /// 缩进代码块的守卫不能顺手把它也拦掉。
    @Test func twoSpaceNestedListContinuesWithoutRender() {
        let source = "- parent\n  - nested"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

        #expect(textView.performSmartNewline())
        #expect(storage.string == "- parent\n  - nested\n  - ")
    }

    /// 属性层与 `lineContentIndex` 的独立价值：4 空格缩进的嵌套项，AST 判定为
    /// depth 2 的列表，但行形状回退层会因为缩进守卫拒绝它。只有「按行内下标读到
    /// 权威属性」这条路能让它续行——光标停在该行终止符上时尤其如此。
    @Test func fourSpaceNestedListContinuesFromAttributesAtLineTerminator() {
        let source = "- parent\n    - nested\nnext"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        #expect(
            (storage.attribute(.museListDepth, at: 20, effectiveRange: nil) as? NSNumber)?.intValue == 2,
            "前提：AST 把 4 空格缩进项判定为 depth 2 的列表"
        )
        // 光标落在 `    - nested` 的行终止符上（下标 21）。
        textView.setSelectedRange(NSRange(location: 21, length: 0))

        #expect(textView.performSmartNewline())
        #expect(storage.string == "- parent\n    - nested\n    - \nnext")
    }

    // MARK: - 换行入口与引用前缀（阶段 B）

    /// `> # Heading` 的空行必须带上 `>`，否则一条引用被劈成两条。
    @Test func quotedHeadingKeepsQuoteMarkerOnInsertedBlankLine() throws {
        let source = "> # Heading" as NSString
        let edit = try #require(TypingBehaviors.newlineEdit(
            in: source,
            selection: NSRange(location: 4, length: 0),
            blockContext: .heading
        ))
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)

        #expect(mutable as String == "> \n> # Heading")
        #expect(edit.selectionAfter == NSRange(location: 2, length: 0))
    }

    /// 生产入口。智能续行以前挂在 delegate 的 `doCommandBy` 上，测试全都绕过它
    /// 直接调 `performSmartNewline`，所以真实按键路径零覆盖。
    @Test func insertNewlineDrivesSmartContinuation() {
        let source = "- item"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        textView.insertNewline(nil)
        #expect(storage.string == "- item\n- ")
    }

    /// ⌃Return。`NSTextView` 原生实现插入的是 U+2028（已实测），cmark 不认它是换行，
    /// 而且会原样写进磁盘。必须改成普通 `\n`，且不做续行（逃生舱语义）。
    @Test func controlReturnInsertsPlainNewlineWithoutContinuation() {
        let source = "- item"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        textView.insertLineBreak(nil)
        #expect(storage.string == "- item\n")
        #expect(storage.string.unicodeScalars.contains("\u{2028}") == false)
    }

    // MARK: - 复选框点击门禁（缺陷 9）

    /// 不可编辑的视图不得被点击改掉正文。
    @Test func checkboxToggleIsRefusedWhenNotEditable() throws {
        let source = "- [ ] task"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let point = try #require(checkboxInkCenter(in: textView))

        #expect(textView.toggleTaskCheckbox(at: point), "前提：可编辑时点得动")
        #expect(storage.string == "- [x] task")

        textView.isEditable = false
        #expect(textView.toggleTaskCheckbox(at: point) == false)
        #expect(storage.string == "- [x] task")
    }

    /// Caps Lock 会在 `deviceIndependentFlagsMask` 里置位（已实测），
    /// 原来的 `flags.isEmpty` 因此静默吞掉所有复选框点击。
    ///
    /// 这里测的是纯谓词而不是整个 `mouseDown`：被拒绝的事件会落到
    /// `super.mouseDown`，那里 AppKit 会进入鼠标跟踪循环等一个测试永远不会
    /// 发出的 mouse-up，整个测试进程就挂住了（本轮实测踩过）。
    @Test(arguments: [
        (NSEvent.ModifierFlags(), true),
        (.capsLock, true),
        (.function, true),
        (.numericPad, true),
        (.shift, false),
        (.command, false),
        (.option, false),
        (.control, false),
    ] as [(NSEvent.ModifierFlags, Bool)])
    func checkboxClickEligibilityIgnoresNonChordModifiers(
        flags: NSEvent.ModifierFlags,
        expected: Bool
    ) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        #expect(EditorTextView.isPlainPrimaryClick(event) == expected)
    }

    /// 双击不应该被当成切换（一个手势变成一次源码编辑）。
    @Test func checkboxClickEligibilityRejectsMultiClick() throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        #expect(EditorTextView.isPlainPrimaryClick(event) == false)
    }

    /// 端到端：命中复选框的点击会提前返回、不进入 `super.mouseDown`，所以这条
    /// 可以安全地驱动真实的 `mouseDown`。
    @Test func capsLockClickStillTogglesCheckboxEndToEnd() throws {
        let source = "- [ ] task"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let point = try #require(checkboxInkCenter(in: textView))
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: textView.convert(point, to: nil),
            modifierFlags: .capsLock,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.mouseDown(with: event)
        #expect(storage.string == "- [x] task")
    }

    // MARK: - 图片点击命中（缺陷 8）

    @Test func imageHitTestingUsesViewCoordinatesAndOrdinaryClicksReachNSTextView() throws {
        let destination = "https://example.com/end.png"
        let source = "正文区域文字\n\n结尾是 ![图片](\(destination))"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView, size: NSSize(width: 560, height: 220))
        defer { window.contentView = nil }
        textView.textContainer?.containerSize = NSSize(
            width: 560,
            height: CGFloat.greatestFiniteMagnitude
        )

        let layoutManager = try #require(textView.textLayoutManager)
        let contentManager = try #require(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        func point(at documentLocation: Int) -> CGPoint? {
            var result: CGPoint?
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                let elementStart = contentManager.offset(
                    from: contentManager.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                guard let paragraph = fragment.textElement as? NSTextParagraph else { return true }
                let local = documentLocation - elementStart
                guard local >= 0, local < paragraph.attributedString.length,
                      let line = fragment.textLineFragments.first(where: {
                          NSLocationInRange(local, $0.characterRange)
                      })
                else { return true }
                let localPoint = line.locationForCharacter(at: local)
                result = CGPoint(
                    x: fragment.layoutFragmentFrame.minX
                        + line.typographicBounds.minX + localPoint.x + 1,
                    y: fragment.layoutFragmentFrame.minY + line.typographicBounds.midY
                )
                result?.x += textView.textContainerOrigin.x
                result?.y += textView.textContainerOrigin.y
                return false
            }
            return result
        }

        let bodyRange = (source as NSString).range(of: "正文区域")
        let imageRange = (source as NSString).range(of: "![图片]")
        let bodyPoint = try #require(point(at: bodyRange.location))
        let imagePoint = try #require(point(at: imageRange.location + 1))

        #expect(textView.imageDestination(at: bodyPoint) == nil)
        #expect(textView.imageDestination(at: imagePoint) == destination)

        // 文档末尾仍带图片属性时，正文普通点击必须落到 super.mouseDown。
        // 预先投递 mouse-up，避免 AppKit 的跟踪循环在单测里等待真实硬件事件。
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        let windowPoint = textView.convert(bodyPoint, to: nil)
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        NSApplication.shared.postEvent(mouseUp, atStart: false)
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        textView.mouseDown(with: mouseDown)
        #expect(bodyRange.contains(textView.selectedRange().location))
    }

    /// 真实绘制墨迹的中心，供点击测试使用（不复用被测 API 自己算的坐标）。
    private func checkboxInkCenter(in textView: EditorTextView) -> CGPoint? {
        guard let layoutManager = textView.textLayoutManager else { return nil }
        var result: CGPoint?
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MuseLayoutFragment,
                  fragment.taskCheckboxHitTarget() != nil,
                  let ink = markerInkBounds(of: fragment)
            else { return true }
            result = CGPoint(
                x: ink.midX + textView.textContainerOrigin.x,
                y: ink.midY + textView.textContainerOrigin.y
            )
            return false
        }
        return result
    }

    /// 引用内的列表在**渲染滞后窗口**里也要能续行——此时属性层给不出答案，
    /// 只能靠回退层下钻 BlockQuote 找到内层的 list。
    @Test func quotedListContinuesWithoutRender() {
        let source = "> - item"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

        #expect(textView.performSmartNewline())
        #expect(storage.string == "> - item\n> - ")
    }

    /// 引用里的 4 空格缩进是缩进代码块，不是嵌套列表——手写正则会判错，
    /// 交给 swift-markdown 才对。
    @Test func indentedCodeInsideQuoteDoesNotContinue() {
        let source = ">     - item"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

        #expect(textView.performSmartNewline() == false)
        #expect(storage.string == source)
    }

    @Test func nestedOrderedListKeepsItsSourceNumberAndFollowingSibling() {
        let source = "1. parent\n   7. child\n2. sibling"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let childRange = (source as NSString).range(of: "   7. child")
        textView.setSelectedRange(NSRange(location: NSMaxRange(childRange), length: 0))

        #expect(textView.performSmartNewline())
        #expect(storage.string == "1. parent\n   7. child\n   7. \n2. sibling")
    }

    // MARK: - 词边界判定的字符簇正确性

    /// 星际平面的**字母/数字**必须和 BMP 字母同样阻止开配对。
    ///
    /// 旧实现按单个 UTF-16 code unit 判定，而 `UnicodeScalar(unichar)` 对代理码元
    /// 返回 nil → 一律答「非词字符」，于是 CJK 扩展 B、数学字母这些字母后面反而
    /// 会开配对，方向正好和 BMP 字母相反。
    @Test(arguments: [
        ("\u{20000}", false),  // CJK 扩展 B，Lo 字母 → 不开
        ("\u{1D400}", false),  // 数学粗体 A，Lu 字母 → 不开
        ("\u{1D7CE}", false),  // 数学粗体数字 0，Nd → 不开
        ("a", false),          // BMP 字母，对照
        ("中", false),          // BMP 中日韩，对照
        ("\u{1F600}", true),   // 😀 是 So 符号，不是词字符 → 照旧开配对
        ("(", true),           // 标点 → 开
    ] as [(String, Bool)])
    func wordBoundaryUsesWholeCharacterCluster(preceding: String, opensPair: Bool) {
        let source = preceding + "x"
        let caret = (preceding as NSString).length
        let edit = TypingBehaviors.pairEdit(
            in: source as NSString,
            input: "*",
            selection: NSRange(location: caret, length: 0)
        )
        #expect((edit != nil) == opensPair)
    }

    /// 组合附加符号：`e` + U+0301 的字符簇首标量是 `e`，是词字符。
    /// 按裸 code unit 判定会看到 U+0301（Mn），错答「非词字符」并开配对。
    @Test func combiningMarkCountsAsPartOfItsBaseLetter() {
        let source = "e\u{0301}x"
        #expect(TypingBehaviors.pairEdit(
            in: source as NSString,
            input: "*",
            selection: NSRange(location: 2, length: 0)
        ) == nil)
    }

    @Test func smartNewlineFallsBackForMultipleSelections() {
        let source = "- one\n- two"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let ranges = [
            NSValue(range: NSRange(location: 5, length: 0)),
            NSValue(range: NSRange(location: 11, length: 0)),
        ]

        #expect(textView.performSmartNewline(selectedRanges: ranges) == false)
        #expect(storage.string == source)
    }

    @Test func pairWrapsSelectionAndKeepsItSelected() throws {
        let source = "alpha" as NSString
        let edit = try #require(TypingBehaviors.pairEdit(
            in: source,
            input: "**",
            selection: NSRange(location: 0, length: source.length)
        ))
        #expect(edit.replacement == "**alpha**")
        #expect(edit.selectionAfter == NSRange(location: 2, length: 5))
    }

    @Test(arguments: [
        ("a`b", "``a`b``", 2),
        ("a``b", "```a``b```", 3),
        ("a```b", "````a```b````", 4),
    ] as [(String, String, Int)])
    func backtickSelectionUsesASafeDelimiter(
        selected: String,
        expected: String,
        delimiterLength: Int
    ) throws {
        let source = selected as NSString
        let edit = try #require(TypingBehaviors.pairEdit(
            in: source,
            input: "`",
            selection: NSRange(location: 0, length: source.length)
        ))

        #expect(edit.replacement == expected)
        #expect(edit.selectionAfter == NSRange(location: delimiterLength, length: source.length))
    }

    @Test func pairOpensSkipsCloserAndUpgradesBold() throws {
        let opened = try #require(TypingBehaviors.pairEdit(
            in: "emphasis" as NSString,
            input: "*",
            selection: NSRange(location: 0, length: 0)
        ))
        #expect(opened.replacement == "**")
        #expect(opened.selectionAfter.location == 1)

        let bold = try #require(TypingBehaviors.pairEdit(
            in: "**" as NSString,
            input: "*",
            selection: NSRange(location: 1, length: 0),
            allowMarkerUpgrade: true
        ))
        #expect(bold.replacement == "**")
        #expect(bold.selectionAfter.location == 2)

        let closer = try #require(TypingBehaviors.pairEdit(
            in: "*text*" as NSString,
            input: "*",
            selection: NSRange(location: 5, length: 0),
            allowCloserSkip: true
        ))
        #expect(closer.replacement == "")
        #expect(closer.selectionAfter.location == 6)
    }

    @Test(
        "Literal Markdown input does not gain an automatic closer",
        arguments: ["* item", "2 * 3", "```swift", "````swift"]
    )
    func literalInputDoesNotGainAutomaticCloser(input: String) {
        let storage = NSTextStorage()
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }

        typeAcrossRunLoopTurns(input, in: textView)

        #expect(storage.string == input)
    }

    @Test func pairDefersEscapedAndWordAdjacentInputToAppKit() {
        #expect(TypingBehaviors.pairEdit(
            in: #"\"# as NSString,
            input: "*",
            selection: NSRange(location: 1, length: 0)
        ) == nil)
        #expect(TypingBehaviors.pairEdit(
            in: "word" as NSString,
            input: "*",
            selection: NSRange(location: 4, length: 0)
        ) == nil)
        #expect(TypingBehaviors.pairEdit(
            in: "word" as NSString,
            input: "`",
            selection: NSRange(location: 2, length: 0)
        ) == nil)
        #expect(TypingBehaviors.pairEdit(
            in: "*emphasis*" as NSString,
            input: "*",
            selection: NSRange(location: 0, length: 0)
        ) == nil)
    }

    @Test func editorTextViewAppliesListEditAndUndoAsOneStep() throws {
        let storage = NSTextStorage(string: "- item")
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(storage.string), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))

        #expect(textView.performSmartNewline())
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        typeAcrossRunLoopTurns("two", in: textView)
        #expect(storage.string == "- item\n- two")

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(storage.string == "- item\n- ")

        undoManager.undo()
        #expect(storage.string == "- item")

        undoManager.redo()
        #expect(storage.string == "- item\n- ")
        undoManager.redo()
        #expect(storage.string == "- item\n- two")
    }

    @Test func editorTextViewInsertsAndUndoesUnownedCloser() throws {
        let source = "*emphasis*"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(storage.string == "**emphasis*")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(storage.string == source)
    }

    @Test func editorTextViewAppliesPairAndUndoAsOneStep() throws {
        let storage = NSTextStorage(string: "a")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(storage.string == "**a")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(storage.string == "a")
        undoManager.redo()
        #expect(storage.string == "**a")
    }

    @Test func editorTextViewUpgradesThenSkipsBothBoldClosers() {
        let storage = NSTextStorage(string: "a")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let insertionRange = NSRange(location: NSNotFound, length: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("*", replacementRange: insertionRange)
        textView.insertText("*", replacementRange: insertionRange)
        #expect(storage.string == "****a")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))

        textView.insertText("b", replacementRange: insertionRange)
        textView.insertText("*", replacementRange: insertionRange)
        textView.insertText("*", replacementRange: insertionRange)
        #expect(storage.string == "**b**a")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func editorUpgradesAndConsumesATripleBacktickPair() {
        let storage = NSTextStorage(string: "code")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let insertionRange = NSRange(location: NSNotFound, length: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("`", replacementRange: insertionRange)
        textView.insertText("`", replacementRange: insertionRange)
        textView.insertText("`", replacementRange: insertionRange)
        #expect(storage.string == "``````code")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))

        textView.insertText("value", replacementRange: insertionRange)
        for _ in 0..<3 {
            textView.insertText("`", replacementRange: insertionRange)
        }
        #expect(storage.string == "```value```code")
        #expect(textView.selectedRange() == NSRange(location: 11, length: 0))
    }

    @Test func editorDeletesOwnedTripleBacktickPairAsOneStep() throws {
        let storage = NSTextStorage(string: "code")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let insertionRange = NSRange(location: NSNotFound, length: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        for _ in 0..<3 {
            textView.insertText("`", replacementRange: insertionRange)
        }
        #expect(storage.string == "``````code")

        textView.deleteBackward(nil)
        #expect(storage.string == "code")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(storage.string == "``````code")
    }

    @Test func editorDeletesOwnedSingleMarkerPairAsOneStep() throws {
        let storage = NSTextStorage(string: "a")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(storage.string == "**a")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))

        textView.deleteBackward(nil)
        #expect(storage.string == "a")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(storage.string == "**a")
    }

    @Test func editorDeletesOwnedBoldMarkerPairAsOneStep() throws {
        let storage = NSTextStorage(string: "a")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        let insertionRange = NSRange(location: NSNotFound, length: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("*", replacementRange: insertionRange)
        textView.insertText("*", replacementRange: insertionRange)
        #expect(storage.string == "****a")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))

        textView.deleteBackward(nil)
        #expect(storage.string == "a")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(storage.string == "****a")
    }

    @Test func editorDoesNotPairDeleteUnownedMarkers() {
        let storage = NSTextStorage(string: "**")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.deleteBackward(nil)

        #expect(storage.string == "*")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func taskCheckboxUsesRealFragmentHitFrameAndUndo() throws {
        let source = "前😀文\n\n- [ ] task"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView, size: NSSize(width: 320, height: 120))
        defer { window.contentView = nil }
        textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)

        let engine = RenderEngine()
        _ = engine.render(
            package: engine.prepare(source),
            selection: nil,
            into: storage
        )

        let layoutManager = try #require(textView.textLayoutManager)
        var target: (frame: CGRect, inkBounds: CGRect, bodyStartX: CGFloat)?
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MuseLayoutFragment,
                  let hit = fragment.taskCheckboxHitTarget(),
                  let inkBounds = markerInkBounds(of: fragment),
                  let firstLine = fragment.textLineFragments.first
            else { return true }
            target = (
                frame: hit.frame,
                inkBounds: inkBounds,
                bodyStartX: fragment.layoutFragmentFrame.minX + firstLine.typographicBounds.minX
            )
            return false
        }
        let resolvedTarget = try #require(target)

        #expect(resolvedTarget.frame.minX <= resolvedTarget.inkBounds.minX)
        #expect(resolvedTarget.frame.maxX >= resolvedTarget.inkBounds.maxX)
        #expect(resolvedTarget.frame.minY <= resolvedTarget.inkBounds.minY)
        #expect(resolvedTarget.frame.maxY >= resolvedTarget.inkBounds.maxY)

        let inkCenter = CGPoint(
            x: resolvedTarget.inkBounds.midX + textView.textContainerOrigin.x,
            y: resolvedTarget.inkBounds.midY + textView.textContainerOrigin.y
        )

        #expect(textView.taskCheckboxToggleRange(at: CGPoint(x: 2, y: 2)) == nil)
        #expect(textView.taskCheckboxToggleRange(at: CGPoint(
            x: resolvedTarget.bodyStartX + 4 + textView.textContainerOrigin.x,
            y: inkCenter.y
        )) == nil)
        #expect(textView.taskCheckboxToggleRange(at: inkCenter) == NSRange(location: 9, length: 1))
        #expect(textView.toggleTaskCheckbox(at: inkCenter))
        #expect(storage.string == "前😀文\n\n- [x] task")

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(storage.string == source)
        undoManager.redo()
        #expect(storage.string == "前😀文\n\n- [x] task")
    }

    @Test func firstCheckedTaskAfterHeadingCanBeUnchecked() throws {
        let source = "# 任务列表\n\n- [x] 已完成：勾选态由 AST 提供，绘制层不重新解析 `[x]`\n- [ ] 未完成"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView, size: NSSize(width: 720, height: 300))
        defer { window.contentView = nil }
        textView.textContainer?.containerSize = NSSize(
            width: 720,
            height: CGFloat.greatestFiniteMagnitude
        )

        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)

        // Use independently scanned drawing pixels, not the hit target itself,
        // so a shared coordinate bug cannot make this test prove itself.
        let point = try #require(checkboxInkCenter(in: textView))
        let stateLocation = (source as NSString).range(of: "[x]").location + 1
        #expect(textView.taskCheckboxToggleRange(at: point) == NSRange(location: stateLocation, length: 1))
        #expect(textView.toggleTaskCheckbox(at: point))
        #expect((storage.string as NSString).substring(with: NSRange(location: stateLocation, length: 1)) == " ")
    }

    @Test func firstListMarkerClicksResolveToTheirOwnItems() throws {
        for (source, suffix) in [
            ("# 标题\n\n1. 第一项\n2. 第二项", ":o"),
            ("# 标题\n\n- 第一项\n- 第二项", ":u"),
        ] {
            let storage = NSTextStorage(string: source)
            let textView = EditorTextView.make(textStorage: storage)
            let window = host(textView, size: NSSize(width: 480, height: 240))
            textView.textContainer?.containerSize = NSSize(
                width: 480,
                height: CGFloat.greatestFiniteMagnitude
            )

            let engine = RenderEngine()
            _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
            let layoutManager = try #require(textView.textLayoutManager)
            layoutManager.ensureLayout(for: layoutManager.documentRange)

            var markerPoint: CGPoint?
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location,
                options: [.ensuresLayout]
            ) { candidate in
                guard let fragment = candidate as? MuseLayoutFragment,
                      fragment.blockKind == BlockVisual.list.rawValue + suffix,
                      let frame = fragment.listMarkerFrame(at: fragment.layoutFragmentFrame.origin)
                else { return true }
                markerPoint = CGPoint(
                    x: frame.midX + textView.textContainerOrigin.x,
                    y: frame.midY + textView.textContainerOrigin.y
                )
                return false
            }

            let point = try #require(markerPoint)
            let firstBody = (source as NSString).range(of: "第一项").location
            if suffix == ":o" {
                // TextKit's native lookup demonstrates the original failure:
                // the first `1.` resolves to the second item.
                #expect(textView.characterIndex(for: point) != firstBody)
            }
            #expect(textView.listMarkerCaretLocation(at: point) == firstBody)

            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: textView.convert(point, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            textView.mouseDown(with: event)
            #expect(textView.selectedRange() == NSRange(location: firstBody, length: 0))
            window.contentView = nil
        }
    }

    @Test func accessibilityValuePreservesMarkdownSource() throws {
        let source = "# 标题\n\n- [ ] 任务\n\n`代码`"
        let storage = NSTextStorage(string: source)
        let engine = RenderEngine()
        _ = engine.render(package: engine.prepare(source), selection: nil, into: storage)
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)

        let value = try #require(textView.accessibilityValue())
        #expect(value == source)
    }

    @Test func markedTextDefersSmartNewline() {
        let storage = NSTextStorage(string: "- item")
        let textView = EditorTextView.make(textStorage: storage)
        let window = host(textView)
        defer { window.contentView = nil }
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.setMarkedText(
            "拼",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.hasMarkedText())
        let whileComposing = storage.string

        #expect(textView.performSmartNewline() == false)
        #expect(storage.string == whileComposing)
        textView.unmarkText()
    }
}
