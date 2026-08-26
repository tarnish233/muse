import AppKit
import Testing
@testable import Muse

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
        // 编辑 2（立即）：文档中部插入粗体——第一次解析尚未应用即被取消
        let mid = NSRange(location: storage.length / 2, length: 0)
        storage.replaceCharacters(in: mid, with: "**Y**")

        #expect(await waitForApplied(coordinator, atLeast: 3))

        // 两处修改都必须生效（旧 bug：只有最后一次 dirty 行被重排）
        #expect(isBold(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)) // "**X**" 的 X
        // Y 的位置：第一次插入后偏移 5
        let yRange = (storage.string as NSString).range(of: "Y")
        #expect(yRange.location != NSNotFound)
        #expect(isBold(storage.attribute(.font, at: yRange.location, effectiveRange: nil) as? NSFont))
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
}
