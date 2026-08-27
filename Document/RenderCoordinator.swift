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

    public override init() {
        super.init()
    }

    private let engine = RenderEngine()
    private var revision = 0
    private var parseTask: Task<Void, Never>?
    public private(set) var lastPackage: RenderEngine.Package?
    private var isApplyingAttributes = false
    /// 自上一次属性应用以来累计的字符编辑数。
    /// 为 0 时 lastPackage 与正文一致，光标流可安全使用；>0 时包已过期，只做增量。
    private var editsSinceApply = 0
    private var revealCache: [RevealKey: RenderEngine.MarkerState] = [:]
    private let clock = ContinuousClock()

    /// 最近一次已应用渲染对应的文本 revision（测试与状态展示用）。
    public private(set) var appliedRevision = 0
    /// 最近一次显隐 reconcile 实际写入的 marker 数（测试插桩：验证"只写翻转项"）。
    public private(set) var lastReconcileWriteCount = 0

    /// 编辑面（弱引用，用于读取选区与 marked text 状态）。
    public weak var textView: NSTextView?
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
        editsSinceApply += 1
        scheduleParse(storage: textStorage, editedRange: editedRange)
    }

    // MARK: - 编辑流

    private func scheduleParse(storage: NSTextStorage, editedRange: NSRange) {
        revision += 1
        let rev = revision
        parseTask?.cancel()

        // 连续编辑会取消旧任务：本轮解析的快照已包含全部修改，
        // 但上一次编辑的 dirty 范围可能已经丢失（复审 P1-1）。
        // 策略：一次编辑对应一个 pending 任务时携带该范围；若在应用前已有多次编辑，
        // 无法安全合并（文本坐标随编辑漂移）→ 回退整篇应用，保证正确性。
        let dirtyNS = editsSinceApply > 1
            ? NSRange(location: 0, length: storage.length)
            : editedRange

        // 不可变快照（v0.2：解析运行在不可变字符串上）；闭包只传递 Sendable 值。
        let snapshot = storage.string
        let engine = self.engine

        // 输入回路是编辑器的交互预算；让最新快照在系统负载下优先于已取消的
        // 低优先级解析，避免后台任务互相争抢时把单键延迟推过端到端门槛。
        parseTask = Task.detached(priority: .high) { [weak self] in
            let package = engine.prepare(snapshot)
            guard !Task.isCancelled else { return }
            await self?.applyParsed(package: package, rev: rev, dirtyNS: dirtyNS)
        }
    }

    private func applyParsed(package: RenderEngine.Package, rev: Int, dirtyNS: NSRange) {
        guard rev == revision, !isApplyingAttributes else { return } // 过期结果直接丢弃
        guard textView?.hasMarkedText() != true else { return }     // 候选态上屏后重排
        guard let storage = textStorage else { return }
        apply(package: package, dirtyNS: dirtyNS, into: storage)
    }

    private func apply(package: RenderEngine.Package, dirtyNS: NSRange, into storage: NSTextStorage) {
        let start = clock.now
        isApplyingAttributes = true
        suppressUndo {
            let previousPackage = lastPackage // 结构变更的陈旧样式判定需要旧 package
            let dirtyLines = engine.applyDirty(package: package, previousPackage: previousPackage,
                                               utf16Range: dirtyNS, into: storage)
            reconcileVisibility(package: package, selection: textView?.selectedRange(),
                                into: storage, forceLines: dirtyLines)
            textView?.needsDisplay = true
        }
        isApplyingAttributes = false

        lastPackage = package
        editsSinceApply = 0
        appliedRevision = revision

        let elapsed = start.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        statusText = "tokens: \(package.tokens.count) · 增量渲染: \(String(format: "%.1f", ms)) ms"
    }

    // MARK: - 光标流（marker 显隐 diff）

    /// 选区变化时调用：只写入显隐状态实际翻转的 marker，不重解析。
    /// 字符编辑后、后台解析应用前，lastPackage 对应旧文本（复审 P1-2）——
    /// 此时跳过光标流，避免用旧区间向新存储写属性；应用落地时已按最新选区重算。
    public func updateMarkerVisibility(selection: NSRange?, into storage: NSTextStorage) {
        guard !isApplyingAttributes, editsSinceApply == 0 else { return }
        guard let package = lastPackage else { return }
        suppressUndo {
            reconcileVisibility(package: package, selection: selection, into: storage, forceLines: nil)
            textView?.needsDisplay = true
        }
    }

    /// 编辑视图挂接后调用：用真实选区补齐首次显隐（初始渲染发生在 textView 存在之前）。
    public func refreshMarkerVisibility(into storage: NSTextStorage) {
        guard !isApplyingAttributes, editsSinceApply == 0 else { return }
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

    // MARK: - 内部

    private func reconcileVisibility(
        package: RenderEngine.Package,
        selection: NSRange?,
        into storage: NSTextStorage,
        forceLines: ClosedRange<Int>?
    ) {
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
                storage.addAttributes(RenderEngine.markerVisibilityAttributes(state: entry.state),
                                      range: entry.markerNS)
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

    private func suppressUndo(_ body: () -> Void) {
        let undoManager = textView?.undoManager
        undoManager?.disableUndoRegistration()
        body()
        undoManager?.enableUndoRegistration()
    }
}
