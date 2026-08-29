import AppKit
import Combine

/// 文档级渲染协调器（v0.2 §03 两条更新流 + §4.6 并发与性能）：
///
/// 编辑流：textStorage 编辑回调 → revision+1 → 主线程抓不可变 String 快照 →
/// 后台解析（扫描+索引，可取消）→ 主线程核对 revision → 只对"脏行带"应用属性。
/// 光标流：选区变化 → 现 package 上重算显隐 → 仅写入状态实际翻转的 marker。
///
/// 属性修改全程包在 undo 抑制中（v0.2 4.5：渲染属性不进入撤销栈，
/// 文本撤销后由编辑回调自动重算渲染）。
@MainActor
public final class RenderCoordinator: NSObject, ObservableObject, NSTextStorageDelegate {
    @Published public private(set) var statusText = "尚未渲染"
    @Published public private(set) var presentationMode: RenderEngine.PresentationMode = .rendered
    /// 文档大纲（heading 层级），供侧边栏导航使用；随每次渲染应用刷新。
    @Published public private(set) var outline: [OutlineHeading] = []

    /// 文档目录条目。UTF-16 范围可以直接交给 AppKit 选区/滚动 API。
    public struct OutlineHeading: Sendable, Identifiable, Equatable {
        public let id: Int
        public let level: Int
        public let title: String
        public let line: Int
        /// 标题行的 UTF-16 范围（marker + 内容），供滚动到位使用。
        public let lineRange: NSRange
    }

    public override init() {
        super.init()
    }

    private let engine = RenderEngine()
    private var revision = 0
    private var parseTask: Task<Void, Never>?
    public private(set) var lastPackage: RenderEngine.Package?
    private var isApplyingAttributes = false
    /// 尚未由 `lastPackage` 覆盖的字符编辑范围，始终维护在**当前正文的 UTF-16 坐标系**。
    /// 非 nil 时 `lastPackage` 已过期，光标流与模式切换都必须等待最新 package 落地。
    private var pendingDirtyRange: NSRange?
    private var revealCache: [RevealKey: RenderEngine.MarkerState] = [:]
    /// 已经写入 NSTextStorage 的呈现模式。与 `presentationMode` 分开记录，
    /// 这样在输入法 marked text 期间收到切换请求时，可以延后到组合输入结束再应用。
    private var appliedPresentationMode: RenderEngine.PresentationMode = .rendered
    private let clock = ContinuousClock()

    /// 最近一次已应用渲染对应的文本 revision（测试与状态展示用）。
    public private(set) var appliedRevision = 0
    /// 最近一次显隐 reconcile 实际写入的 marker 数（测试插桩：验证"只写翻转项"）。
    public private(set) var lastReconcileWriteCount = 0
    /// 最近一次成功应用时请求给 RenderEngine 的原始 dirty UTF-16 范围。
    /// 这是输入热路径的范围插桩；结构扩张后的行带由 `lastAppliedDirtyLines` 记录。
    public private(set) var lastAppliedDirtyRange: NSRange?
    public private(set) var lastAppliedDirtyLines: ClosedRange<Int>?
    /// 实际进入 `RenderEngine.prepare` 的次数；被输入 burst 在 debounce 内取消的任务不计入。
    public private(set) var parsePreparationCount = 0

    /// 编辑面（弱引用，用于读取选区与 marked text 状态）。
    public weak var textView: NSTextView?
    /// 相对路径图片的解析基准（文档所在目录）。
    ///
    /// 必须每次渲染都传给引擎：块图片的呈现尺寸决定行高，是**属性**的一部分，
    /// 不能等到绘制时才解析路径。文档另存/首次保存后由文档层更新。
    public var imageBaseURL: URL? {
        didSet {
            guard imageBaseURL != oldValue, let storage = textStorage, let package = lastPackage else { return }
            // 基准变了，原先解析失败的相对路径可能变得可解析（反之亦然）：
            // 整篇重排一次属性，让图片的行高与块角色跟上。
            isApplyingAttributes = true
            suppressUndo {
                _ = engine.render(
                    package: package,
                    selection: textView?.selectedRange(),
                    mode: presentationMode,
                    into: storage,
                    imageBaseURL: imageBaseURL
                )
                textView?.needsDisplay = true
            }
            isApplyingAttributes = false
            revealCache.removeAll(keepingCapacity: true)
        }
    }
    /// 唯一正文存储（弱引用；由文档装配）。
    public private(set) weak var textStorage: NSTextStorage?
    /// 文本被编辑后回调（文档层用它 updateChangeCount）。
    public var onTextEdited: (() -> Void)?

    public func attach(storage: NSTextStorage) {
        textStorage = storage
        // 生产路径由 MuseDocument 设置；这里兜底保证管线挂上（测试与文档装配都走 attach）。
        storage.delegate = self
    }

    /// marker 显隐的稳定身份：行号 + 行内相对字节偏移。
    /// 不用绝对偏移——文档前部插入字符会让后续所有 marker 的绝对位置变化，cache 全 miss。
    private struct RevealKey: Hashable {
        let line: Int
        let relOffset: Int
    }

    // MARK: - NSTextStorageDelegate

    /// 字符编辑后：登记脏区并调度后台解析；属性变更（editedAttributes）不重入；
    /// 组合输入（marked text）期间跳过，上屏后的下一次编辑会触发。
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isApplyingAttributes else { return }
        onTextEdited?()
        guard textView?.hasMarkedText() != true else { return }
        pendingDirtyRange = Self.accumulatingDirtyRange(
            pending: pendingDirtyRange,
            editedRange: editedRange,
            changeInLength: delta,
            currentLength: textStorage.length
        )
        scheduleParse(storage: textStorage)
    }

    // MARK: - 编辑流

    private func scheduleParse(storage: NSTextStorage) {
        revision += 1
        let rev = revision
        parseTask?.cancel()

        // `pendingDirtyRange` 已经随每次编辑重基到当前坐标系；本轮快照与范围属于同一 revision。
        // 旧任务即使在取消前完成，也会由 revision guard 丢弃，不能清空这份 pending 状态。
        guard let dirtyNS = pendingDirtyRange else { return }

        // 不可变快照（v0.2：解析运行在不可变字符串上）；闭包只传递 Sendable 值。
        let snapshot = storage.string
        let engine = self.engine

        // swift-markdown 的同步 prepare 不合作检查 Task cancellation。若每个按键立即启动
        // detached 解析，连续输入会留下多个已取消但仍占 CPU 的整篇解析。先等待一个很短的
        // 输入 burst 窗口：被后续按键取消的任务在真正进入 prepare 前退出，只解析最新快照。
        parseTask = Task(priority: .high) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }

            guard let self, !Task.isCancelled, rev == self.revision else { return }
            self.parsePreparationCount += 1
            let package = await Task.detached(priority: .high) {
                engine.prepare(snapshot)
            }.value
            guard !Task.isCancelled else { return }
            self.applyParsed(package: package, rev: rev, dirtyNS: dirtyNS)
        }
    }

    private func applyParsed(package: RenderEngine.Package, rev: Int, dirtyNS: NSRange) {
        guard rev == revision, !isApplyingAttributes else { return } // 过期结果直接丢弃
        guard textView?.hasMarkedText() != true else { return }     // 候选态上屏后重排
        guard let storage = textStorage else { return }
        apply(package: package, rev: rev, dirtyNS: dirtyNS, into: storage)
    }

    private func apply(
        package: RenderEngine.Package,
        rev: Int,
        dirtyNS: NSRange,
        into storage: NSTextStorage
    ) {
        let start = clock.now
        isApplyingAttributes = true
        var appliedLines: ClosedRange<Int>?
        suppressUndo {
            let previousPackage = lastPackage // 结构变更的陈旧样式判定需要旧 package
            let dirtyLines = engine.applyDirty(package: package, previousPackage: previousPackage,
                                               utf16Range: dirtyNS, mode: presentationMode, into: storage,
                                               imageBaseURL: imageBaseURL)
            appliedLines = dirtyLines
            if presentationMode == .rendered {
                reconcileVisibility(package: package, selection: textView?.selectedRange(),
                                    into: storage, forceLines: dirtyLines)
            } else {
                revealCache.removeAll(keepingCapacity: true)
                lastReconcileWriteCount = 0
            }
            appliedPresentationMode = presentationMode
            textView?.needsDisplay = true
        }
        isApplyingAttributes = false

        // `apply` 在 MainActor 上同步完成；没有字符编辑能在这段期间插入。
        // 只有与当前 revision 对应的 package 才能成为 storage 属性与光标流的权威来源。
        lastPackage = package
        pendingDirtyRange = nil
        lastAppliedDirtyRange = dirtyNS
        lastAppliedDirtyLines = appliedLines
        appliedRevision = rev
        outline = Self.makeOutline(from: package, storageString: storage.string)

        let elapsed = start.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let formattedMilliseconds = ms.formatted(.number.precision(.fractionLength(1)))
        statusText = "字符: \(storage.string.count)  渲染: \(formattedMilliseconds)ms"
    }

    /// 把旧 pending 范围穿过本次编辑映射到新正文坐标，再与本次编辑合并。
    /// `didProcessEditing` 给出的 `editedRange` 是编辑后的范围；旧替换长度可由
    /// `editedRange.length - changeInLength` 还原。函数保持纯值，便于精确回归坐标漂移。
    static func accumulatingDirtyRange(
        pending: NSRange?,
        editedRange: NSRange,
        changeInLength delta: Int,
        currentLength: Int
    ) -> NSRange {
        let documentLength = max(0, currentLength)
        guard editedRange.location != NSNotFound else {
            return NSRange(location: 0, length: documentLength)
        }

        let currentEdit = clamped(editedRange, to: documentLength)
        guard let pending else { return currentEdit }

        let previousLength = max(0, documentLength - delta)
        let oldDirty = clamped(pending, to: previousLength)
        let oldEditLength = max(0, currentEdit.length - delta)
        let oldEditStart = min(currentEdit.location, previousLength)
        let oldEditEnd = min(previousLength, oldEditStart + oldEditLength)
        let oldDirtyEnd = oldDirty.location + oldDirty.length

        let rebased: NSRange
        if oldDirtyEnd <= oldEditStart {
            // 旧 dirty 完全在本次编辑之前，坐标不变。
            rebased = oldDirty
        } else if oldDirty.location >= oldEditEnd {
            // 旧 dirty 完全在被替换区之后，整体随长度差平移。
            rebased = NSRange(location: oldDirty.location + delta, length: oldDirty.length)
        } else {
            // 相交（或插入发生在 dirty 内部）：保留替换区两侧仍存活的边界。
            let newEditEnd = currentEdit.location + currentEdit.length
            let mappedStart = oldDirty.location < oldEditStart ? oldDirty.location : currentEdit.location
            let mappedEnd = oldDirtyEnd > oldEditEnd ? oldDirtyEnd + delta : newEditEnd
            rebased = NSRange(location: mappedStart, length: max(0, mappedEnd - mappedStart))
        }

        return union(clamped(rebased, to: documentLength), currentEdit)
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let available = length - location
        return NSRange(location: location, length: min(max(0, range.length), available))
    }

    private static func union(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        let lower = min(lhs.location, rhs.location)
        let upper = max(lhs.location + lhs.length, rhs.location + rhs.length)
        return NSRange(location: lower, length: upper - lower)
    }

    /// 从 tokens 抽取 heading 大纲（供 SwiftUI 侧边栏）。UTF-8 → UTF-16 的转换只做一次。
    private static func makeOutline(from package: RenderEngine.Package, storageString: String) -> [OutlineHeading] {
        let nsSource = storageString as NSString
        var result: [OutlineHeading] = []
        result.reserveCapacity(package.tokens.count / 8)

        for (index, token) in package.tokens.enumerated() {
            guard case .heading(let level) = token.kind else { continue }
            guard let content = token.contentRange else { continue }
            let contentNS = package.index.nsRange(content)
            guard contentNS.location != NSNotFound,
                  contentNS.location + contentNS.length <= nsSource.length else { continue }
            let title = nsSource.substring(with: contentNS)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lineStartByte = package.lineStarts[token.line]
            let lineEndByte: Int
            if token.line + 1 < package.lineStarts.count {
                lineEndByte = package.lineStarts[token.line + 1]
            } else {
                lineEndByte = package.index.utf8Length
            }
            let lineRange = package.index.nsRange(lineStartByte..<lineEndByte)
            result.append(
                OutlineHeading(
                    id: index,
                    level: level,
                    title: title.isEmpty ? "(untitled)" : title,
                    line: token.line,
                    lineRange: lineRange
                )
            )
        }
        return result
    }

    // MARK: - 光标流（marker 显隐 diff）

    /// 选区变化时调用：只写入显隐状态实际翻转的 marker，不重解析。
    /// 字符编辑后、后台解析应用前，lastPackage 对应旧文本（复审 P1-2）——
    /// 此时跳过光标流，避免用旧区间向新存储写属性；应用落地时已按最新选区重算。
    public func updateMarkerVisibility(selection: NSRange?, into storage: NSTextStorage) {
        guard presentationMode == .rendered, !isApplyingAttributes, pendingDirtyRange == nil else { return }
        guard let package = lastPackage else { return }
        suppressUndo {
            reconcileVisibility(package: package, selection: selection, into: storage, forceLines: nil)
            textView?.needsDisplay = true
        }
    }

    /// 编辑视图挂接后调用：用真实选区补齐首次显隐（初始渲染发生在 textView 存在之前）。
    public func refreshMarkerVisibility(into storage: NSTextStorage) {
        guard presentationMode == .rendered, !isApplyingAttributes, pendingDirtyRange == nil else { return }
        guard let package = lastPackage else { return }
        suppressUndo {
            reconcileVisibility(package: package, selection: textView?.selectedRange(), into: storage, forceLines: nil)
            textView?.needsDisplay = true
        }
    }

    /// 供测试直接注入已解析的 package（正常路径由编辑流自动写入）。
    public func adoptPackage(_ package: RenderEngine.Package) {
        lastPackage = package
    }

    /// 在即时渲染与源码模式之间切换。两种模式共享同一份正文，切换只重建
    /// 可丢弃属性，不进入 undo 栈，也不创建第二份 String。
    public func setPresentationMode(_ mode: RenderEngine.PresentationMode) {
        if presentationMode != mode {
            presentationMode = mode
            revealCache.removeAll(keepingCapacity: true)
            lastReconcileWriteCount = 0
        }
        applyPresentationModeIfPossible()
    }

    /// 组合输入结束时由编辑视图重试尚未落地的模式切换。
    /// NSTextView 的 marked text 仍由系统独占，不在候选态上改写属性。
    public func refreshPresentationMode() {
        applyPresentationModeIfPossible()
    }

    private func applyPresentationModeIfPossible() {
        guard appliedPresentationMode != presentationMode,
              textView?.hasMarkedText() != true,
              !isApplyingAttributes,
              pendingDirtyRange == nil,
              let package = lastPackage,
              let storage = textStorage
        else { return }

        isApplyingAttributes = true
        suppressUndo {
            _ = engine.render(
                package: package,
                selection: textView?.selectedRange(),
                mode: presentationMode,
                into: storage,
                imageBaseURL: imageBaseURL
            )
            textView?.needsDisplay = true
        }
        isApplyingAttributes = false
        appliedPresentationMode = presentationMode
    }

    /// 侧边栏点击 heading 时调用：把选区放到标题行首并滚动可见。
    public func reveal(heading: OutlineHeading) {
        guard let textView, let storage = textStorage else { return }
        let length = storage.length
        guard heading.lineRange.location + heading.lineRange.length <= length else { return }
        let caret = NSRange(location: heading.lineRange.location, length: 0)
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(heading.lineRange)
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - 内部

    private func reconcileVisibility(
        package: RenderEngine.Package,
        selection: NSRange?,
        into storage: NSTextStorage,
        forceLines: ClosedRange<Int>?
    ) {
        // With no attached text view there is no caret-derived reveal state:
        // every marker is hidden. Avoid materializing UTF-16 ranges for the
        // entire document on every background package application; only a
        // forced line or a cache transition needs a storage write.
        if selection == nil {
            reconcileHiddenVisibility(package: package, into: storage, forceLines: forceLines)
            return
        }

        let entries = engine.computedVisibility(package: package, selection: selection)
        var newCache: [RevealKey: RenderEngine.MarkerState] = [:]
        var firstWrite = true
        var writeCount = 0

        for entry in entries {
            let key = RevealKey(line: entry.line, relOffset: entry.markerRelOffset)
            let cached = revealCache[key]
            let forced = forceLines?.contains(entry.line) == true
            if forced || cached != entry.state {
                if firstWrite {
                    storage.beginEditing() // 批处理：一次编辑会话内写完全部翻转
                    firstWrite = false
                }
                engine.apply(entry, imageBaseURL: imageBaseURL, into: storage)
                writeCount += 1
            }
            newCache[key] = entry.state
        }
        if !firstWrite {
            storage.endEditing()
        }
        lastReconcileWriteCount = writeCount
        revealCache = newCache
    }

    private func reconcileHiddenVisibility(
        package: RenderEngine.Package,
        into storage: NSTextStorage,
        forceLines: ClosedRange<Int>?
    ) {
        let hiddenAttributes = RenderEngine.markerVisibilityAttributes(state: .hidden)
        var newCache: [RevealKey: RenderEngine.MarkerState] = [:]
        newCache.reserveCapacity(package.tokens.count)
        var firstWrite = true
        var writeCount = 0

        for token in package.tokens {
            let forced = forceLines?.contains(token.line) == true
            // `markerVisibilityRanges`（而不是 allMarkerRanges）：块图片整段折叠，
            // 只隐藏 `![` 与 `](目的地)` 会把标签留在正文里。
            for range in token.markerVisibilityRanges {
                let key = RevealKey(
                    line: token.line,
                    relOffset: range.lowerBound - package.lineStarts[token.line]
                )
                if forced || revealCache[key] != .hidden {
                    if firstWrite {
                        storage.beginEditing()
                        firstWrite = false
                    }
                    let markerNS = package.index.nsRange(range)
                    if token.inlineImageRange != nil {
                        engine.applyInlineImageVisibility(
                            state: .hidden,
                            span: markerNS,
                            markerSubRange: package.index.nsRange(token.markerRange),
                            closingSubRange: token.closingMarkerRange.map(package.index.nsRange),
                            imageBaseURL: imageBaseURL,
                            into: storage
                        )
                    } else if let listDepth = token.listDepth {
                        engine.applyMarkerVisibility(
                            state: .hidden,
                            markerNS: markerNS,
                            listDepth: listDepth,
                            into: storage
                        )
                    } else {
                        storage.addAttributes(hiddenAttributes, range: markerNS)
                    }
                    writeCount += 1
                }
                newCache[key] = .hidden
            }
        }

        if !firstWrite {
            storage.endEditing()
        }
        lastReconcileWriteCount = writeCount
        revealCache = newCache
    }

    private func suppressUndo(_ body: () -> Void) {
        let undoManager = textView?.undoManager
        undoManager?.disableUndoRegistration()
        body()
        undoManager?.enableUndoRegistration()
    }
}
