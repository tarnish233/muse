import AppKit
import Testing
@testable import MuseKit

/// 协调器管线：并发编辑、结构变更与陈旧样式（第二轮复审 P1 项的回归测试）。
/// 这些场景不直接操作引擎层，而是走"编辑回调 → 后台解析 → 应用"的真实路径。
@Suite @MainActor struct CoordinatorPipelineTests {
    let engine = RenderEngine()

    private func weight(_ font: NSFont?) -> Double {
        let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
    }

    private func isBold(_ font: NSFont?) -> Bool {
        NSFontManager.shared.traits(of: font ?? .systemFont(ofSize: 16)).contains(.boldFontMask)
    }

    /// 轮询等待协调器把指定 revision 应用到存储。
    private func waitForApplied(_ coordinator: RenderCoordinator, atLeast rev: Int, timeoutMs: Int = 10_000) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while coordinator.appliedRevision < rev {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    @Test func statusReportsCharactersAndRenderDuration() async {
        let source = "A😀中"
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        #expect(await waitForApplied(coordinator, atLeast: 1))
        #expect(coordinator.statusText.hasPrefix("字符: \(source.count)  渲染: "))
        #expect(coordinator.statusText.hasSuffix("ms"))
        #expect(!coordinator.statusText.contains("tokens"))
    }

    @Test func editsRemainLiteralWhileSourceModeIsActive() async {
        let source = "# title\nplain"
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        #expect(await waitForApplied(coordinator, atLeast: 1))
        coordinator.setPresentationMode(.source)

        let insertion = "\n- literal"
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: insertion)
        #expect(await waitForApplied(coordinator, atLeast: 2))

        let marker = (storage.string as NSString).range(of: "- literal").location
        #expect(coordinator.presentationMode == .source)
        #expect(storage.attribute(.font, at: marker, effectiveRange: nil) as? NSFont == Theme.standard.codeFont())
        #expect(storage.attribute(.museBlock, at: marker, effectiveRange: nil) == nil)
        #expect(storage.string == source + insertion)
    }

    /// 快速连续编辑（第二次编辑在第一次的解析落地前到达）：脏区必须合并/回退，
    /// 第一次修改的行也必须在同一次应用中被重排（复审 P1-1）。
    @Test func rapidEditsCoalesceDirtyRanges() async {
        let source = String(repeating: "段落行示例内容 paragraph line\n\n", count: 60)
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source) // 触发初始渲染
        #expect(await waitForApplied(coordinator, atLeast: 1))

        // 编辑 1：文档开头插入粗体
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "**X**")
        // 编辑 2（立即）：中部某行行首插入粗体——第一次解析尚未应用即被取消。
        // 注意插在行首（紧随换行）：两处编辑都必须走同一 AST 语义管线。
        let half = storage.length / 2
        let beforeNewline = (storage.string as NSString)
            .range(of: "\n", options: .backwards, range: NSRange(location: 0, length: half))
        let yPos = beforeNewline.location + 1
        storage.replaceCharacters(in: NSRange(location: yPos, length: 0), with: "**Y**")

        #expect(await waitForApplied(coordinator, atLeast: 3))

        // 两处修改都必须生效（旧 bug：只有最后一次 dirty 行被重排）
        #expect(isBold(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)) // "**X**" 的 X
        // Y 的位置：第一次插入后偏移 5
        let yRange = (storage.string as NSString).range(of: "Y")
        #expect(yRange.location != NSNotFound)
        #expect(isBold(storage.attribute(.font, at: yRange.location, effectiveRange: nil) as? NSFont))
    }

    @Test func dirtyAccumulatorRebasesPendingRangeAcrossEarlierInsertion() {
        // 旧文档长度 30；已有 dirty = 20..<24。随后在 2 插入 3 个 UTF-16 单元，
        // 旧 dirty 必须平移为 23..<27，再与本次 2..<5 合并。
        let accumulated = RenderCoordinator.accumulatingDirtyRange(
            pending: NSRange(location: 20, length: 4),
            editedRange: NSRange(location: 2, length: 3),
            changeInLength: 3,
            currentLength: 33
        )

        #expect(accumulated == NSRange(location: 2, length: 25))
    }

    @Test func dirtyAccumulatorContractsWhenDeletionOverlapsPendingRange() {
        // 旧 dirty = 10..<18；删除旧文档 13..<17 后，仍存活的 dirty 是 10..<14。
        let accumulated = RenderCoordinator.accumulatingDirtyRange(
            pending: NSRange(location: 10, length: 8),
            editedRange: NSRange(location: 13, length: 0),
            changeInLength: -4,
            currentLength: 26
        )

        #expect(accumulated == NSRange(location: 10, length: 4))
    }

    /// 同一 main-actor turn 内的逐字输入必须只提交连续的小范围，而不是整篇兜底。
    @Test func consecutiveTypingAppliesAccumulatedCurrentCoordinateRange() async {
        let source = "prefix paragraph\nplain target line\nsuffix paragraph"
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        #expect(await waitForApplied(coordinator, atLeast: 1))

        let insertion = (storage.string as NSString).range(of: "target").location
        let typed = "**X**"
        let startRevision = coordinator.appliedRevision
        for (offset, character) in typed.enumerated() {
            storage.replaceCharacters(
                in: NSRange(location: insertion + offset, length: 0),
                with: String(character)
            )
        }

        #expect(await waitForApplied(coordinator, atLeast: startRevision + typed.count))
        #expect(coordinator.lastAppliedDirtyRange == NSRange(location: insertion, length: typed.utf16.count))
        #expect(coordinator.lastAppliedDirtyRange?.length != storage.length)

        let x = (storage.string as NSString).range(of: "X").location
        #expect(isBold(storage.attribute(.font, at: x, effectiveRange: nil) as? NSFont))
    }

    /// 先把后方标成 dirty，再在前方插入：最终范围必须包含重基后的后方端点。
    @Test func earlierInsertionRebasesPendingPipelineRange() async {
        let source = "front\nplain middle\nplain tail"
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        #expect(await waitForApplied(coordinator, atLeast: 1))

        let tail = (storage.string as NSString).range(of: "tail").location
        let startRevision = coordinator.appliedRevision
        storage.replaceCharacters(in: NSRange(location: tail, length: 0), with: "**Y**")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "0123456789")

        #expect(await waitForApplied(coordinator, atLeast: startRevision + 2))
        let expectedEnd = tail + "**Y**".utf16.count + "0123456789".utf16.count
        #expect(coordinator.lastAppliedDirtyRange == NSRange(location: 0, length: expectedEnd))

        let y = (storage.string as NSString).range(of: "Y").location
        #expect(isBold(storage.attribute(.font, at: y, effectiveRange: nil) as? NSFont))
    }

    /// 字符编辑后、解析应用前：光标流不得用旧 package 写属性（复审 P1-2）。
    @Test func stalePackageGuardSkipsCursorFlow() async {
        let storage = NSTextStorage(string: "**粗**\n正文")
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: storage.string)
        #expect(await waitForApplied(coordinator, atLeast: 1))

        // 删除开头两个字符（**，开标记），随即在应用落地前发起光标更新
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        coordinator.updateMarkerVisibility(selection: NSRange(location: 0, length: 0), into: storage)

        #expect(await waitForApplied(coordinator, atLeast: 2))
        #expect(storage.string == "粗**\n正文") // 闭合标记仍在（只删了开标记）
    }

    /// 换行拆分：原行一分为二，被拆出的部分若失去配对标记，旧样式必须清除（复审 P1-3）。
    @Test func dirtyCoversSplitLineAfterNewlineInsert() {
        let old = "aaaa **bbbb** cccc"
        let storage = NSTextStorage(string: old)
        let package0 = engine.prepare(old)
        _ = engine.render(package: package0, selection: NSRange(location: 0, length: 0), into: storage)
        let bOld = (old as NSString).range(of: "bbbb").location
        #expect(weight(storage.attribute(.font, at: bOld, effectiveRange: nil) as? NSFont) > 0.1) // bbbb 加粗

        // 在 "**" 与 "bbbb" 之间插入换行 → "**bbbb" 失去配对（两边都成为未闭合强调）
        let insertAt = (old as NSString).range(of: "bbbb").location
        storage.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: "\n")
        let source = storage.string
        let package1 = engine.prepare(source)

        let lines = engine.applyDirty(package: package1, previousPackage: nil,
                                      utf16Range: NSRange(location: insertAt, length: 1),
                                      into: storage)
        #expect(lines.lowerBound == 0)
        #expect(lines.upperBound == 1) // +1 邻居行覆盖被拆出的部分

        // 原 bbbb 位置（换行后 +1）不再是粗体
        let bRange = (source as NSString).range(of: "bbbb")
        #expect(weight(storage.attribute(.font, at: bRange.location, effectiveRange: nil) as? NSFont) < 0.1)
    }

    /// 删除围栏符：后续行必须清掉旧代码背景（复审 P1-3 的"陈旧样式扫描"）。
    @Test func dirtyClearsStaleCodeBackgroundAfterFenceOpenerRemoved() {
        let old = "```\ncode line\n```"
        let storage = NSTextStorage(string: old)
        let package0 = engine.prepare(old)
        _ = engine.render(package: package0, selection: NSRange(location: 0, length: 0), into: storage)

        // 删除开栏行（连同换行）：剩余 "```" 在语义上成为新的开栏符，
        // 旧围栏体 "code line" 应清掉代码背景。
        let opener = (old as NSString).range(of: "```\n")
        storage.replaceCharacters(in: opener, with: "")
        let source = storage.string
        let package1 = engine.prepare(source)

        let lines = engine.applyDirty(package: package1, previousPackage: nil,
                                      utf16Range: NSRange(location: 0, length: 1),
                                      into: storage)
        // 陈旧代码行被吸收进重排带
        #expect(lines.upperBound >= 0)

        let codeRange = (source as NSString).range(of: "code line")
        #expect(storage.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) == nil)
    }

    /// 结构标记的光标行回显（Typora 模式）：与 App 完全一致的路径——
    /// 编辑回调 → 后台解析 → applyDirty + reconcileVisibility（forceLines）。
    /// 不在光标行的列表/任务标记为 hidden（近零宽），围栏/引用折叠。
    @Test func structuralMarkersFollowCaretThroughCoordinatorPath() async {
        let source = SampleMarkdown.text
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        #expect(await waitForApplied(coordinator, atLeast: 1, timeoutMs: 30_000))

        func font(_ at: Int) -> NSFont? {
            storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        }
        func alpha(_ at: Int) -> CGFloat {
            ((storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)?.cgColor.alpha ?? 1)
        }
        let revealedFont = RenderEngine.markerVisibilityAttributes(revealed: true)[.font] as? NSFont

        // 打开后光标在文档末尾：列表标记 hidden（近零字号 + 透明），围栏折叠
        let ordered = (source as NSString).range(of: "1. 有序列表第一项")
        #expect((font(ordered.location)?.pointSize ?? 100) < 1)
        #expect(alpha(ordered.location) == 0)
        let fence = (source as NSString).range(of: "```swift")
        #expect((font(fence.location)?.pointSize ?? 100) < 1)
        // 标题 # 不随光标（光标在末尾 → 隐藏）
        let heading = (source as NSString).range(of: "# Muse · M0 技术验证")
        let caret = NSRange(location: storage.length - 1, length: 0)
        coordinator.updateMarkerVisibility(selection: caret, into: storage)
        #expect((font(heading.location)?.pointSize ?? 100) < 1)

        // 光标移到有序列表行 → 标记回显（有色）
        coordinator.updateMarkerVisibility(selection: NSRange(location: ordered.location, length: 0), into: storage)
        #expect(font(ordered.location) == revealedFont)
        #expect(alpha(ordered.location) > 0)
    }

    /// 插入围栏闭合符：围栏结束，原"围栏到 EOF"的段落行要清掉旧代码背景（陈旧样式扫描）。
    @Test func dirtyClearsStaleCodeBackgroundAfterCloserInserted() {
        // 旧文档的围栏未闭合（一直到 EOF），paragraph 在旧渲染里是代码背景
        let old = "```\ncode line\n\nparagraph"
        let storage = NSTextStorage(string: old)
        let package0 = engine.prepare(old)
        _ = engine.render(package: package0, selection: NSRange(location: 0, length: 0), into: storage)
        let pRange = (old as NSString).range(of: "paragraph")
        #expect(storage.attribute(.backgroundColor, at: pRange.location, effectiveRange: nil) != nil)

        // 在 paragraph 前插入闭合符
        storage.replaceCharacters(in: NSRange(location: pRange.location, length: 0), with: "```\n")
        let source = storage.string
        let package1 = engine.prepare(source)

        let lines = engine.applyDirty(package: package1, previousPackage: nil,
                                      utf16Range: NSRange(location: pRange.location, length: 1),
                                      into: storage)
        #expect(lines.upperBound == 4) // 扩张到源围栏体末尾（含段落行）

        let newPRange = (source as NSString).range(of: "paragraph")
        #expect(storage.attribute(.backgroundColor, at: newPRange.location, effectiveRange: nil) == nil)
    }

    /// 用户报告场景：在文档末尾（截图之后）输入新的列表/引用/围栏，走完整编辑管线。
    /// 增量应用必须覆盖新输入的块语法行——结构与样式不能被"只重置脏带"漏掉。
    @Test func typedNewBlocksAtEndRenderThroughPipeline() async {
        let source = "正文第一段\n\n末段"
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source) // 初始渲染
        #expect(await waitForApplied(coordinator, atLeast: 1))

        // 用户输入：在文档末尾追加列表/引用/围栏
        let typed = "\n- 新列表项\n> 新引用\n```\nlet x = 1\n```"
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: typed)
        #expect(await waitForApplied(coordinator, atLeast: 2))

        let string = storage.string as NSString
        let hiddenMarkerFont = RenderEngine.markerVisibilityAttributes(state: .hidden)[.font] as? NSFont

        // 新列表行：marker hidden（近零字号 + 透明，图形符号由绘制层画）
        let newList = string.range(of: "- 新列表项")
        #expect(newList.location != NSNotFound)
        #expect(storage.attribute(.font, at: newList.location, effectiveRange: nil) as? NSFont == hiddenMarkerFont)
        let listContent = string.range(of: "新列表项")
        #expect(storage.attribute(.foregroundColor, at: listContent.location, effectiveRange: nil) != nil)

        // 新引用行：引用背景存在；marker 在光标行外折叠
        let quote = string.range(of: "新引用")
        #expect(quote.location != NSNotFound)
        #expect(storage.attribute(.backgroundColor, at: quote.location, effectiveRange: nil) != nil)
        #expect((storage.attribute(.font, at: quote.location - 2, effectiveRange: nil) as? NSFont)?.pointSize ?? 100 < 1)

        // 新围栏：代码字体 + 背景覆盖围栏体
        let code = string.range(of: "let x = 1")
        #expect(code.location != NSNotFound)
        #expect(storage.attribute(.backgroundColor, at: code.location, effectiveRange: nil) != nil)
        // 字符不受渲染影响
        #expect(storage.string == source + typed)
    }

    /// 围栏闭合与紧随其后的行内编辑连续发生时，旧 package 仍须扩张结构脏带。
    @Test func rapidFenceClosureKeepsStructuralExpansion() async {
        let source = "```\ncode line\n\nparagraph"
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        #expect(await waitForApplied(coordinator, atLeast: 1))
        let oldParagraph = (storage.string as NSString).range(of: "paragraph")
        #expect(storage.attribute(.backgroundColor, at: oldParagraph.location, effectiveRange: nil) != nil)

        let startRevision = coordinator.appliedRevision
        storage.replaceCharacters(in: NSRange(location: oldParagraph.location, length: 0), with: "```\n")
        let paragraph = (storage.string as NSString).range(of: "paragraph")
        storage.replaceCharacters(in: NSRange(location: paragraph.location, length: paragraph.length),
                                  with: "**paragraph**")

        #expect(await waitForApplied(coordinator, atLeast: startRevision + 2))
        let content = (storage.string as NSString).range(of: "paragraph")
        #expect(storage.attribute(.backgroundColor, at: content.location, effectiveRange: nil) == nil)
        #expect(isBold(storage.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont))
        #expect(coordinator.lastAppliedDirtyLines?.upperBound ?? 0 >= 3)
    }

    @Test func imageBaseURLChangeDuringPendingDirtyDoesNotRenderStalePackage() async {
        let source = "prefix\n**bold at end**\n![x](missing.png)"
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        #expect(await waitForApplied(coordinator, atLeast: 1))
        let preparationCount = coordinator.parsePreparationCount

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "x")
        coordinator.imageBaseURL = FileManager.default.temporaryDirectory

        #expect(storage.string == "x")
        #expect(await waitForApplied(coordinator, atLeast: 2))
        #expect(coordinator.parsePreparationCount == preparationCount + 1)
        #expect(coordinator.lastAppliedDirtyLines == 0...0)
    }

    @Test func deletingLongFenceOpenerInvalidatesThroughFormerTail() {
        let old = "```\nline 1\nline 2\nline 3\nline 4\n```\nafter"
        let storage = NSTextStorage(string: old)
        let oldPackage = engine.prepare(old)
        _ = engine.render(package: oldPackage, selection: nil, into: storage)
        let lastCodeLine = (old as NSString).range(of: "line 4")
        #expect(storage.attribute(.backgroundColor, at: lastCodeLine.location, effectiveRange: nil) != nil)

        storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "")
        let source = storage.string
        let newPackage = engine.prepare(source)
        let dirtyLines = engine.applyDirty(
            package: newPackage,
            previousPackage: oldPackage,
            utf16Range: NSRange(location: 0, length: 0),
            into: storage
        )

        let newLastCodeLine = (source as NSString).range(of: "line 4")
        #expect(dirtyLines.upperBound >= 5)
        #expect(storage.attribute(.backgroundColor, at: newLastCodeLine.location, effectiveRange: nil) == nil)
    }

    @Test func deletingLongLazyQuoteOpenerInvalidatesEntireFormerQuote() {
        let old = "> first\nlazy 1\nlazy 2\nlazy 3\nlazy 4\nlazy 5\nlazy 6"
        let storage = NSTextStorage(string: old)
        let oldPackage = engine.prepare(old)
        _ = engine.render(package: oldPackage, selection: nil, into: storage)
        let lastLazy = (old as NSString).range(of: "lazy 6")
        #expect(storage.attribute(.backgroundColor, at: lastLazy.location, effectiveRange: nil) != nil)

        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        let source = storage.string
        let newPackage = engine.prepare(source)
        let dirtyLines = engine.applyDirty(
            package: newPackage,
            previousPackage: oldPackage,
            utf16Range: NSRange(location: 0, length: 0),
            into: storage
        )

        let newLastLazy = (source as NSString).range(of: "lazy 6")
        #expect(dirtyLines.upperBound == 6)
        #expect(storage.attribute(.backgroundColor, at: newLastLazy.location, effectiveRange: nil) == nil)
    }

    @Test func multilineStrongReappliesWhenSecondLineChanges() throws {
        let old = "**first\nsecond**\nplain"
        let storage = NSTextStorage(string: old)
        let oldPackage = engine.prepare(old)
        _ = engine.render(package: oldPackage, selection: nil, into: storage)

        let second = (old as NSString).range(of: "second")
        storage.replaceCharacters(in: second, with: "changed")
        let source = storage.string
        let newPackage = engine.prepare(source)
        _ = engine.applyDirty(
            package: newPackage,
            previousPackage: oldPackage,
            utf16Range: NSRange(location: second.location, length: "changed".utf16.count),
            into: storage
        )

        let changed = (source as NSString).range(of: "changed")
        #expect(isBold(storage.attribute(.font, at: changed.location, effectiveRange: nil) as? NSFont))

        let strong = try #require(newPackage.tokens.first { $0.kind == .strong })
        let closing = try #require(strong.closingMarkerRange)
        let closingNS = newPackage.index.nsRange(closing)
        let entry = engine.computedVisibility(package: newPackage, selection: nil)
            .first { $0.markerNS == closingNS }
        #expect(entry?.line == 1)
        #expect(entry?.markerRelOffset == "changed".utf8.count)
    }

    /// P1-4：插入字符不破坏 marker diff 的稳定身份。
    /// 在 200KB 文档开头插入一个字符后，只有受影响行的 marker 被重写。
    @Test func markerDiffStableUnderFrontInsertion() async {
        let source = PerformanceTests.corpus(kb: 200)
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "")
        #expect(await waitForApplied(coordinator, atLeast: 1, timeoutMs: 30_000))

        // 文档开头插入一个字符（所有后续 marker 的绝对偏移都变了）
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x")
        #expect(await waitForApplied(coordinator, atLeast: 2, timeoutMs: 30_000))

        // 行内相对偏移身份：远离编辑行的 marker 几乎全部命中缓存，写入数远小于总量
        let totalMarkers = coordinator.lastPackage?.tokens
            .reduce(0) { $0 + ($1.closingMarkerRange == nil ? 1 : 2) } ?? 0
        #expect(totalMarkers > 5_000) // 语料确认有大量 marker
        #expect(coordinator.lastReconcileWriteCount < totalMarkers / 10)
    }

    // MARK: - 真实管线下的列表续行（缺陷 17）
    //
    // TypingBehaviorsTests 里的用例都用同步预渲染或干脆不渲染来构造两种极端。
    // 这一条挂真实 RenderCoordinator、走真实的 Task.detached 解析与主线程应用，
    // 断言「渲染有没有追上都必须能续行」——这正是手动验收本来要看的东西，
    // 而且可重复。

    @Test func listContinuesWithRealRendererWhetherOrNotStyleHasLanded() async throws {
        let body = PerformanceTests.corpus(kb: 200) + "\n正文段落\n"
        let storage = NSTextStorage(string: body)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        coordinator.textView = textView
        defer { window.contentView = nil }

        // 首轮渲染落地，模拟「打开文档后开始编辑」。
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "")
        #expect(await waitForApplied(coordinator, atLeast: 1, timeoutMs: 60_000))

        // A) 逐字输入后**立刻**回车：200KB 上派生属性还没追上（实测 343ms）。
        textView.setSelectedRange(NSRange(location: (storage.string as NSString).length, length: 0))
        for character in "- alpha" {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let beforeStyleLands = textView.performSmartNewline()
        #expect(beforeStyleLands, "渲染未追上时也必须续行")
        #expect(storage.string.hasSuffix("- alpha\n- "))

        // B) 等派生属性落地后再回车，走的是权威属性那条路。
        textView.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        let revision = coordinator.appliedRevision
        #expect(await waitForApplied(coordinator, atLeast: revision + 1, timeoutMs: 60_000))
        let afterStyleLands = textView.performSmartNewline()
        #expect(afterStyleLands, "属性落地后同样必须续行")
        #expect(storage.string.hasSuffix("- alpha\n- beta\n- "))
    }
}
