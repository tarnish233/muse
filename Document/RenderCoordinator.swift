import AppKit
import Combine

/// swift-markdown 的同步解析运行在独立 actor 上。协调器只维护一个消费循环，新的
/// 快照覆盖尚未开始的旧快照，因此同一文档永远不会并发执行多次整篇解析。
private actor RenderPreparationWorker {
    func prepare(_ source: String) -> RenderEngine.Package {
        RenderEngine().prepare(source)
    }
}

/// Obsidian 表格编辑器的方向导航语义。单元格内部仍由 NSTextView 正常移动，
/// 只有到达边界时才交给 RenderCoordinator 跨格。
public nonisolated enum TableArrowDirection: Sendable {
    case up
    case down
    case left
    case right
}

/// 文档级渲染协调器（v0.2 §03 两条更新流 + §4.6 并发与性能）：
///
/// 编辑流：textStorage 编辑回调 → revision+1 → 主线程抓不可变 String 快照 →
/// 后台解析（扫描+索引，single-flight/latest-wins）→ 主线程核对 revision →
/// 只对"脏行带"应用属性。
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
    /// 当前可视正文所属的最近一个标题，供侧边栏跟随滚动位置高亮。
    @Published public private(set) var visibleHeadingID: Int?

    /// 文档目录条目。UTF-16 范围可以直接交给 AppKit 选区/滚动 API。
    public struct OutlineHeading: Sendable, Identifiable, Equatable {
        public let id: Int
        public let level: Int
        public let title: String
        public let line: Int
        /// 标题行的 UTF-16 范围（marker + 内容），供滚动到位使用。
        public let lineRange: NSRange
    }

    private let imagePreparer: @Sendable (URL) async -> Bool

    public override init() {
        imagePreparer = { url in
            let result = await ImageResolver.prepareImage(url: url)
            return result.cacheChanged
        }
        super.init()
    }

    init(imagePreparer: @escaping @Sendable (URL) async -> Bool) {
        self.imagePreparer = imagePreparer
        super.init()
    }

    private let engine = RenderEngine()
    private let preparationWorker = RenderPreparationWorker()
    private var revision = 0
    private var visibleDocumentLocation: Int?
    private var parseTask: Task<Void, Never>?
    /// 当前 revision 的解析结果若在输入法候选态返回，保留最新请求并暂停消费循环；
    /// 组合输入结束后继续，而不是在主 actor 上忙等或永久遗失 pending dirty。
    private var isParseDeferredForMarkedText = false
    /// 仅供确定性管线测试冻结消费循环；生产路径始终为 false。
    private var isParseLoopPausedForTesting = false
    private struct ParseRequest: Sendable {
        let revision: Int
        let snapshot: String
        let dirtyRange: NSRange
    }
    private var latestParseRequest: ParseRequest?
    public private(set) var lastPackage: RenderEngine.Package?
    private var isApplyingAttributes = false
    /// 尚未由 `lastPackage` 覆盖的字符编辑范围，始终维护在**当前正文的 UTF-16 坐标系**。
    /// 非 nil 时 `lastPackage` 已过期，光标流与模式切换都必须等待最新 package 落地。
    private var pendingDirtyRange: NSRange?
    private var revealCache: [RevealKey: RenderEngine.MarkerState] = [:]
    private var revealsCurrentBlockSource = true
    private var needsImageRefresh = false
    private var imagePreparationTask: Task<Void, Never>?
    private var imagePreparationGeneration = 0
    private var needsMathRefresh = false
    /// 最近一次已把 MathRenderer 当时全部可用产物同步进当前 storage 的缓存代次。
    /// 只比较纯数值，不在输入热路径读取 NSTextStorage 属性。
    private var appliedMathArtifactGeneration: UInt64 = 0
    private var mathPreparationTask: Task<Void, Never>?
    private var mathPreparationGeneration = 0
    /// 渲染尚未追上输入时收到的表格导航命令。等最新 AST 落地后按顺序执行，避免
    /// 用旧的 UTF-16 区间跳到错误单元格；命令本身仍被消费，不会写进 Markdown。
    /// 若某条命令新增了表格行，剩余命令会继续等待下一份 AST，绝不复用旧坐标。
    private var pendingTableNavigations: [TableNavigationDirection] = []
    /// 渲染尚未追上输入时收到的大纲跳转。`OutlineHeading.lineRange` 是 package 派生
    /// 的行区间，脏区未清时它对应的是**编辑前**的行偏移，直接用会跳到错位置。
    /// 存下 id，等最新 outline 重建后按新区间执行。
    private var pendingOutlineReveal: OutlineHeading.ID?
    private struct ActiveTableSelection: Equatable {
        let tableID: Int
        let anchorRow: Int
        let anchorColumn: Int
        let headRow: Int
        let headColumn: Int

        var bounds: TableSelectionBounds {
            TableSelectionBounds(
                minRow: anchorRow, maxRow: headRow,
                minColumn: anchorColumn, maxColumn: headColumn
            )
        }

        init(tableID: Int, bounds: TableSelectionBounds) {
            self.init(
                tableID: tableID,
                anchorRow: bounds.minRow,
                anchorColumn: bounds.minColumn,
                headRow: bounds.maxRow,
                headColumn: bounds.maxColumn
            )
        }

        init(
            tableID: Int,
            anchorRow: Int,
            anchorColumn: Int,
            headRow: Int,
            headColumn: Int
        ) {
            self.tableID = tableID
            self.anchorRow = anchorRow
            self.anchorColumn = anchorColumn
            self.headRow = headRow
            self.headColumn = headColumn
        }
    }
    private var activeTableSelection: ActiveTableSelection?
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
    /// 实际进入 `RenderEngine.prepare` 的次数；尚未开始的旧快照被新输入覆盖，不计入。
    public private(set) var parsePreparationCount = 0
    /// 同一文档同时执行的整篇解析峰值；回归测试保证 single-flight 契约。
    public private(set) var maxConcurrentParsePreparationCount = 0
    private var activeParsePreparationCount = 0

    /// 编辑面（弱引用，用于读取选区与 marked text 状态）。
    public weak var textView: NSTextView?
    /// 相对路径图片的解析基准（文档所在目录）。
    ///
    /// 必须每次渲染都传给引擎：块图片的呈现尺寸决定行高，是**属性**的一部分，
    /// 不能等到绘制时才解析路径。文档另存/首次保存后由文档层更新。
    public var imageBaseURL: URL? {
        didSet {
            guard imageBaseURL != oldValue else { return }
            imagePreparationTask?.cancel()
            needsImageRefresh = true
            applyImageRefreshIfPossible()
            if let package = lastPackage {
                scheduleBlockImagePreparation(package: package, revision: revision)
            }
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

    /// 字符编辑后：无论是否处于输入法 marked text，都先登记脏区、推进 revision
    /// 并更新 latest-wins 快照；属性变更（editedAttributes）不重入。候选态只延后
    /// 属性应用，不能延后记账，否则候选文本变化期间旧 package 仍会被当成权威。
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isApplyingAttributes else { return }
        onTextEdited?()
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
        imagePreparationTask?.cancel()
        mathPreparationTask?.cancel()

        // `pendingDirtyRange` 已经随每次编辑重基到当前坐标系；本轮快照与范围属于同一 revision。
        // 旧解析即使在新输入之后完成，也会由 revision guard 丢弃，不能清空这份 pending 状态。
        enqueueCurrentParse(storage: storage)
        // 部分输入法在最终上屏时会先结束 marked 状态、再送字符编辑；这次编辑本身
        // 就是明确的恢复信号，不必再等待选区变化回调。
        if textView?.hasMarkedText() != true {
            isParseDeferredForMarkedText = false
        }
        startParseLoopIfNeeded()
    }

    private func enqueueCurrentParse(storage: NSTextStorage) {
        guard let dirtyNS = pendingDirtyRange else { return }
        latestParseRequest = ParseRequest(
            revision: revision,
            snapshot: storage.string,
            dirtyRange: dirtyNS
        )
    }

    private func startParseLoopIfNeeded() {
        guard !isParseDeferredForMarkedText,
              !isParseLoopPausedForTesting,
              parseTask == nil,
              latestParseRequest != nil
        else { return }
        parseTask = Task(priority: .high) { [weak self] in
            await self?.runParseLoop()
        }
    }

    private func runParseLoop() async {
        defer {
            parseTask = nil
            startParseLoopIfNeeded()
        }

        while !Task.isCancelled {
            // Yield once so edits delivered in the same main-run-loop turn collapse into one
            // snapshot. A fixed debounce adds guaranteed latency to every keystroke; newer
            // snapshots already replace queued work while the single preparation actor is busy.
            await Task.yield()
            guard let request = latestParseRequest else { return }
            latestParseRequest = nil

            parsePreparationCount += 1
            activeParsePreparationCount += 1
            maxConcurrentParsePreparationCount = max(
                maxConcurrentParsePreparationCount,
                activeParsePreparationCount
            )
            let package = await preparationWorker.prepare(request.snapshot)
            activeParsePreparationCount -= 1

            guard !Task.isCancelled else { return }
            applyParsed(
                package: package,
                rev: request.revision,
                dirtyNS: request.dirtyRange
            )
            guard !isParseDeferredForMarkedText,
                  latestParseRequest != nil
            else { return }
        }
    }

    private func applyParsed(package: RenderEngine.Package, rev: Int, dirtyNS: NSRange) {
        guard rev == revision, !isApplyingAttributes else { return } // 过期结果直接丢弃
        guard let storage = textStorage else { return }

        guard textView?.hasMarkedText() != true else {
            // 当前 package 对应候选态文本，不能改写 marked range 的派生属性；但 dirty
            // 与 revision 都必须保留。暂停 single-flight 循环并重放当前快照，待上屏后
            // 由最终字符编辑或 refreshPresentationMode() 恢复，避免紧循环反复解析。
            enqueueCurrentParse(storage: storage)
            isParseDeferredForMarkedText = true
            return
        }

        // revision 是主防线；长度校验是最后兜底。若外部组件漏报了一次字符编辑，
        // 也不能让旧 package 的 token 范围写进更短的 storage。
        guard package.index.utf16Length == storage.length else {
            if pendingDirtyRange == nil {
                pendingDirtyRange = NSRange(location: 0, length: storage.length)
            }
            enqueueCurrentParse(storage: storage)
            return
        }

        apply(
            package: package,
            rev: rev,
            dirtyNS: Self.clampedDirtyRange(dirtyNS, toLength: storage.length),
            into: storage
        )
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
        let requiresFullImageRefresh = needsImageRefresh
        let requiresMathRefresh = needsMathRefresh && presentationMode == .rendered
        var appliedAllMathArtifacts = false
        suppressUndo {
            if requiresFullImageRefresh {
                _ = engine.render(
                    package: package,
                    selection: textView?.selectedRange(),
                    mode: presentationMode,
                    revealsCurrentBlockSource: revealsCurrentBlockSource,
                    into: storage,
                    imageBaseURL: imageBaseURL
                )
                appliedLines = 0...max(0, package.lineStarts.count - 1)
                revealCache.removeAll(keepingCapacity: true)
                lastReconcileWriteCount = 0
                appliedAllMathArtifacts = presentationMode == .rendered
            } else {
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
                if requiresMathRefresh {
                    _ = engine.refreshMathArtifacts(
                        package: package,
                        selection: textView?.selectedRange(),
                        revealsCurrentBlockSource: revealsCurrentBlockSource,
                        into: storage
                    )
                    appliedAllMathArtifacts = true
                }
            }
            appliedPresentationMode = presentationMode
            textView?.needsDisplay = true
        }
        isApplyingAttributes = false
        if appliedAllMathArtifacts {
            recordMathArtifactsApplied()
        }

        // `apply` 在 MainActor 上同步完成；没有字符编辑能在这段期间插入。
        // 只有与当前 revision 对应的 package 才能成为 storage 属性与光标流的权威来源。
        lastPackage = package
        pendingDirtyRange = nil
        needsImageRefresh = false
        lastAppliedDirtyRange = dirtyNS
        lastAppliedDirtyLines = appliedLines
        appliedRevision = rev
        outline = Self.makeOutline(from: package, storageString: storage.string)
        refreshVisibleHeading()
        reapplyActiveTableSelection(package: package, storage: storage)

        let elapsed = start.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let formattedMilliseconds = ms.formatted(.number.precision(.fractionLength(1)))
        // The package computed grapheme count off the main actor together with the immutable
        // source snapshot, so emoji/combining sequences stay correct without a UI-thread scan.
        statusText = "字符: \(package.characterCount)  渲染: \(formattedMilliseconds)ms"

        if presentationMode == .rendered {
            drainPendingTableNavigations(package: package)
        } else {
            pendingTableNavigations.removeAll(keepingCapacity: true)
        }
        drainPendingOutlineReveal()
        scheduleBlockImagePreparation(package: package, revision: rev)
        scheduleMathPreparation(package: package, revision: rev)
    }

    private func scheduleBlockImagePreparation(
        package: RenderEngine.Package,
        revision requestedRevision: Int
    ) {
        let urls = Set(package.blockImageDestinations.compactMap { destination -> URL? in
            guard let url = ImageResolver.resolvedURL(destination: destination, baseURL: imageBaseURL) else {
                return nil
            }
            return url.isFileURL ? url.standardizedFileURL : url.absoluteURL
        })

        imagePreparationTask?.cancel()
        imagePreparationGeneration += 1
        let generation = imagePreparationGeneration
        guard !urls.isEmpty else {
            imagePreparationTask = nil
            return
        }

        let imagePreparer = imagePreparer
        imagePreparationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.prepareImagesAndRefresh(
                urls,
                maximumConcurrentCount: 4,
                using: imagePreparer,
                generation: generation,
                revision: requestedRevision
            )
        }
    }

    /// 大文档可能引用很多远程图片；限制并发数，避免一次渲染把所有连接同时打满。
    /// 每张图片准备完成就立即重排，不让一个慢请求阻塞同页其他图片的显示。
    private func prepareImagesAndRefresh(
        _ urls: Set<URL>,
        maximumConcurrentCount: Int,
        using imagePreparer: @escaping @Sendable (URL) async -> Bool,
        generation: Int,
        revision requestedRevision: Int
    ) async {
        await withTaskGroup(of: Bool.self) { group in
            var iterator = urls.makeIterator()
            let initialCount = min(max(1, maximumConcurrentCount), urls.count)
            for _ in 0..<initialCount {
                guard let url = iterator.next() else { break }
                group.addTask { await imagePreparer(url) }
            }

            while let changed = await group.next() {
                guard !Task.isCancelled,
                      imagePreparationGeneration == generation,
                      revision == requestedRevision
                else {
                    group.cancelAll()
                    return
                }
                if changed {
                    needsImageRefresh = true
                    applyImageRefreshIfPossible()
                }
                if let url = iterator.next(), Task.isCancelled == false {
                    group.addTask { await imagePreparer(url) }
                }
            }
        }
        guard !Task.isCancelled,
              imagePreparationGeneration == generation,
              revision == requestedRevision
        else { return }
        imagePreparationTask = nil
    }

    private func scheduleMathPreparation(
        package: RenderEngine.Package,
        revision requestedRevision: Int
    ) {
        mathPreparationTask?.cancel()
        mathPreparationGeneration += 1
        let generation = mathPreparationGeneration
        guard presentationMode == .rendered else {
            mathPreparationTask = nil
            return
        }

        // 去重与排序已经随 AST package 在后台完成。这里从输入热路径可达，不能在
        // MainActor 上再扫描整篇 token。
        let requests = package.mathRequests
        guard !requests.isEmpty else {
            mathPreparationTask = nil
            return
        }

        mathPreparationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for request in requests {
                guard !Task.isCancelled,
                      self.mathPreparationGeneration == generation,
                      self.revision == requestedRevision
                else { return }
                if await MathRenderer.shared.prepare(request),
                   self.appliedMathArtifactGeneration != MathRenderer.shared.artifactGeneration {
                    // 产物可用与发起它的 revision 无关。即使该任务刚在 WebKit await 期间
                    // 被新输入取消，也要保留“缓存尚未写入 storage”的事实，交给最新
                    // package 在安全窗口消费。每个公式完成就立即刷新，不能让后面的慢
                    // 请求（最长 10 秒）把本页已经完成的公式一起扣住。
                    self.needsMathRefresh = true
                    self.applyMathRefreshIfPossible()
                }
            }
            guard !Task.isCancelled,
                  self.mathPreparationGeneration == generation,
                  self.revision == requestedRevision
            else { return }
            self.mathPreparationTask = nil
            self.applyMathRefreshIfPossible()
        }
    }

    // MARK: - 表格可视化编辑

    private enum TableNavigationDirection {
        case forward
        case backward
        case returnKey
        case arrow(TableArrowDirection)
    }

    /// Obsidian 风格的表格键盘导航：Tab / Shift-Tab 在可见单元格之间移动，并选中
    /// 目标格的实际内容（不含 `|` 与填充空白）；末格 Tab 追加一行。正文仍只有一份
    /// Markdown，所有操作都走 NSTextView 的标准编辑/撤销管线。
    @discardableResult
    public func navigateTable(backward: Bool) -> Bool {
        guard presentationMode == .rendered,
              let textView,
              let storage = textStorage
        else { return false }

        let direction: TableNavigationDirection = backward ? .backward : .forward
        if pendingDirtyRange != nil {
            guard selectionIsInRenderedTable(textView.selectedRange(), storage: storage) else {
                return false
            }
            pendingTableNavigations.append(direction)
            return true
        }
        guard let package = lastPackage else { return false }
        return performTableNavigation(direction, package: package)
    }

    /// 表格内 Return 始终作为纵向导航键：移动到下一行同列；当前已经是末行时
    /// 追加一行并落到新行同列。这样不会从单元格中间插入换行、破坏 GFM 表格。
    /// 解析落后于输入时与 Tab 共用 pending 机制，绝不拿旧 AST 改正文。
    @discardableResult
    public func insertTableRowOnReturn() -> Bool {
        guard presentationMode == .rendered,
              let textView,
              let storage = textStorage
        else { return false }

        if pendingDirtyRange != nil {
            guard selectionIsInRenderedTable(textView.selectedRange(), storage: storage) else {
                return false
            }
            pendingTableNavigations.append(.returnKey)
            return true
        }
        guard let package = lastPackage else { return false }
        return performTableNavigation(.returnKey, package: package)
    }

    /// Obsidian 风格的方向键边界导航：上下移动到同列，左右只在当前单元格的
    /// 首尾跨格。返回 false 时由 NSTextView 继续处理单元格内部的普通光标移动。
    @discardableResult
    public func navigateTable(arrow direction: TableArrowDirection) -> Bool {
        guard presentationMode == .rendered,
              let textView,
              textStorage != nil,
              textView.selectedRange().length == 0
        else { return false }

        // 方向键与 Enter/Tab 不同：单元格内部必须继续普通逐字移动。AST 尚未追上
        // 输入时无法可靠判断是否已经抵达格边界，因此不消费按键，交还 NSTextView。
        guard pendingDirtyRange == nil else { return false }
        guard let package = lastPackage else { return false }
        return performTableNavigation(.arrow(direction), package: package)
    }

    private func selectionIsInRenderedTable(_ selection: NSRange, storage: NSTextStorage) -> Bool {
        guard storage.length > 0 else { return false }
        let location = min(max(0, selection.location), storage.length - 1)
        return storage.attribute(.museBlock, at: location, effectiveRange: nil) as? String
            == BlockVisual.table.rawValue
    }

    private struct EditableTableCell {
        let table: TableStructure
        let row: Int
        let column: Int
        let content: NSRange
        let ink: NSRange
    }

    private struct SerializedTable {
        let text: String
        /// 各可见行、各列的内容区间（相对 `text`，不含管道和填充空格）。
        let cells: [[NSRange]]
    }

    public var currentTableSelection: (tableID: Int, bounds: TableSelectionBounds)? {
        activeTableSelection.map { ($0.tableID, $0.bounds) }
    }

    public func tableDimensions(tableID: Int) -> (rows: Int, columns: Int)? {
        guard pendingDirtyRange == nil,
              let table = lastPackage?.tables.first(where: { $0.headerLine == tableID })
        else { return nil }
        return (table.rows.count, table.columnCount)
    }

    /// 选择整行、整列或矩形单元格区域。与 Obsidian 一样，这是结构选区，不是
    /// NSTextView 的字符选区；复制、剪切、对齐和删除会优先作用于它。
    @discardableResult
    public func selectTableCells(tableID: Int, bounds: TableSelectionBounds?) -> Bool {
        guard presentationMode == .rendered,
              pendingDirtyRange == nil,
              let package = lastPackage,
              let storage = textStorage
        else { return false }

        clearActiveTableSelectionAttributes(package: package, storage: storage)
        guard let bounds,
              let table = package.tables.first(where: { $0.headerLine == tableID }),
              let validated = validatedSelection(bounds, table: table)
        else {
            activeTableSelection = nil
            textView?.needsDisplay = true
            return true
        }
        activeTableSelection = ActiveTableSelection(tableID: tableID, bounds: validated)
        applyTableSelectionAttributes(table: table, bounds: validated, package: package, storage: storage)
        textView?.needsDisplay = true
        return true
    }

    /// Shift+方向键扩展结构化单元格选区。首次按下时以当前编辑单元格为锚点，
    /// 后续方向键只移动活动端，因此可以向回收缩，而不是不断做不可逆的并集。
    @discardableResult
    public func extendTableSelection(arrow direction: TableArrowDirection) -> Bool {
        guard presentationMode == .rendered,
              pendingDirtyRange == nil,
              let package = lastPackage,
              let storage = textStorage
        else { return false }

        let active: ActiveTableSelection
        let table: TableStructure
        if let current = activeTableSelection,
           let currentTable = package.tables.first(where: { $0.headerLine == current.tableID }) {
            active = current
            table = currentTable
        } else if let cell = editableTableCell(at: textView?.selectedRange(), package: package) {
            table = cell.table
            active = ActiveTableSelection(
                tableID: cell.table.headerLine,
                anchorRow: cell.row,
                anchorColumn: cell.column,
                headRow: cell.row,
                headColumn: cell.column
            )
        } else {
            return false
        }

        var headRow = active.headRow
        var headColumn = active.headColumn
        switch direction {
        case .up: headRow = max(0, headRow - 1)
        case .down: headRow = min(table.rows.count - 1, headRow + 1)
        case .left: headColumn = max(0, headColumn - 1)
        case .right: headColumn = min(table.columnCount - 1, headColumn + 1)
        }

        clearActiveTableSelectionAttributes(package: package, storage: storage)
        let next = ActiveTableSelection(
            tableID: active.tableID,
            anchorRow: active.anchorRow,
            anchorColumn: active.anchorColumn,
            headRow: headRow,
            headColumn: headColumn
        )
        activeTableSelection = next
        applyTableSelectionAttributes(
            table: table, bounds: next.bounds, package: package, storage: storage
        )
        textView?.needsDisplay = true
        return true
    }

    @discardableResult
    public func performTableAction(tableID: Int, action: TableStructureAction) -> Bool {
        guard presentationMode == .rendered,
              pendingDirtyRange == nil,
              let package = lastPackage,
              let table = package.tables.first(where: { $0.headerLine == tableID }),
              let storage = textStorage,
              let textView
        else { return false }

        var rows = tableRows(table, package: package, storage: storage)
        var alignments = (0..<table.columnCount).map { table.alignment(column: $0) }
        guard !rows.isEmpty, !alignments.isEmpty else { return false }

        var selectionRow = 0
        var selectionColumn = 0
        var selectedBounds: TableSelectionBounds?
        var actionName = "编辑表格"

        switch action {
        case let .insertRow(index, copying):
            // 第 0 行是 Markdown 表头；“在上方插入”即使落在表头，也只能
            // 插到首个正文行位置，不能让空行取代表头。
            let insertion = min(max(1, index), rows.count)
            let template = copying.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
                ?? Array(repeating: "", count: alignments.count)
            rows.insert(template, at: insertion)
            selectionRow = insertion
            selectedBounds = TableSelectionBounds(
                minRow: insertion, maxRow: insertion,
                minColumn: 0, maxColumn: alignments.count - 1
            )
            actionName = copying == nil ? "插入表格行" : "复制表格行"

        case let .removeRow(index):
            guard rows.indices.contains(index) else { return false }
            if rows.count == 1 {
                return replaceWholeTable(
                    table: table, package: package, storage: storage, textView: textView,
                    replacement: "", actionName: "删除表格"
                )
            }
            rows.remove(at: index)
            selectionRow = min(index, rows.count - 1)
            selectedBounds = TableSelectionBounds(
                minRow: selectionRow, maxRow: selectionRow,
                minColumn: 0, maxColumn: alignments.count - 1
            )
            actionName = "删除表格行"

        case let .moveRow(from, to):
            guard from >= 1, to >= 1,
                  rows.indices.contains(from), rows.indices.contains(to)
            else { return false }
            let moved = rows.remove(at: from)
            rows.insert(moved, at: to)
            selectionRow = to
            selectedBounds = TableSelectionBounds(
                minRow: to, maxRow: to,
                minColumn: 0, maxColumn: alignments.count - 1
            )
            actionName = "移动表格行"

        case let .insertColumn(index, copying, alignmentFrom):
            let insertion = min(max(0, index), alignments.count)
            let alignmentIndex = alignmentFrom ?? copying
            let alignment = alignmentIndex.flatMap { alignments.indices.contains($0) ? alignments[$0] : nil }
                ?? .leading
            for rowIndex in rows.indices {
                let value = copying.flatMap { rows[rowIndex].indices.contains($0) ? rows[rowIndex][$0] : nil } ?? ""
                rows[rowIndex].insert(value, at: insertion)
            }
            alignments.insert(alignment, at: insertion)
            selectionColumn = insertion
            selectedBounds = TableSelectionBounds(
                minRow: 0, maxRow: rows.count - 1,
                minColumn: insertion, maxColumn: insertion
            )
            actionName = copying == nil ? "插入表格列" : "复制表格列"

        case let .removeColumn(index):
            guard alignments.indices.contains(index) else { return false }
            if alignments.count == 1 {
                return replaceWholeTable(
                    table: table, package: package, storage: storage, textView: textView,
                    replacement: "", actionName: "删除表格"
                )
            }
            for rowIndex in rows.indices { rows[rowIndex].remove(at: index) }
            alignments.remove(at: index)
            selectionColumn = min(index, alignments.count - 1)
            selectedBounds = TableSelectionBounds(
                minRow: 0, maxRow: rows.count - 1,
                minColumn: selectionColumn, maxColumn: selectionColumn
            )
            actionName = "删除表格列"

        case let .moveColumn(from, to):
            guard alignments.indices.contains(from), alignments.indices.contains(to) else { return false }
            for rowIndex in rows.indices {
                let moved = rows[rowIndex].remove(at: from)
                rows[rowIndex].insert(moved, at: to)
            }
            let movedAlignment = alignments.remove(at: from)
            alignments.insert(movedAlignment, at: to)
            selectionColumn = to
            selectedBounds = TableSelectionBounds(
                minRow: 0, maxRow: rows.count - 1,
                minColumn: to, maxColumn: to
            )
            actionName = "移动表格列"

        case let .align(columns, alignment):
            let lower = max(0, columns.lowerBound)
            let upper = min(alignments.count - 1, columns.upperBound)
            guard lower <= upper else { return false }
            for column in lower...upper { alignments[column] = alignment }
            selectionColumn = lower
            selectedBounds = TableSelectionBounds(
                minRow: 0, maxRow: rows.count - 1,
                minColumn: lower, maxColumn: upper
            )
            actionName = "设置表格列对齐"

        case let .sort(column, direction):
            guard alignments.indices.contains(column), rows.count > 1 else { return false }
            let body = rows.dropFirst().enumerated().sorted { lhs, rhs in
                let result = lhs.element[column].localizedStandardCompare(rhs.element[column])
                if result == .orderedSame { return lhs.offset < rhs.offset }
                return direction == .ascending ? result == .orderedAscending : result == .orderedDescending
            }.map(\.element)
            rows = [rows[0]] + body
            selectionColumn = column
            selectedBounds = TableSelectionBounds(
                minRow: 0, maxRow: rows.count - 1,
                minColumn: column, maxColumn: column
            )
            actionName = direction == .ascending ? "表格升序排序" : "表格降序排序"

        case let .clear(bounds):
            guard let bounds = validatedSelection(bounds, rowCount: rows.count, columnCount: alignments.count) else {
                return false
            }
            for row in bounds.minRow...bounds.maxRow {
                for column in bounds.minColumn...bounds.maxColumn { rows[row][column] = "" }
            }
            selectionRow = bounds.minRow
            selectionColumn = bounds.minColumn
            selectedBounds = bounds
            actionName = "清空表格选区"

        case let .delete(bounds):
            guard let bounds = validatedSelection(bounds, rowCount: rows.count, columnCount: alignments.count) else {
                return false
            }
            let coversAllRows = bounds.minRow == 0 && bounds.maxRow == rows.count - 1
            let coversAllColumns = bounds.minColumn == 0 && bounds.maxColumn == alignments.count - 1
            if coversAllRows && coversAllColumns {
                return replaceWholeTable(
                    table: table, package: package, storage: storage, textView: textView,
                    replacement: "", actionName: "删除表格"
                )
            } else if coversAllColumns {
                rows.removeSubrange(bounds.minRow...bounds.maxRow)
                guard !rows.isEmpty else {
                    return replaceWholeTable(
                        table: table, package: package, storage: storage, textView: textView,
                        replacement: "", actionName: "删除表格"
                    )
                }
                selectionRow = min(bounds.minRow, rows.count - 1)
                selectedBounds = TableSelectionBounds(
                    minRow: selectionRow, maxRow: selectionRow,
                    minColumn: 0, maxColumn: alignments.count - 1
                )
                actionName = "删除表格行"
            } else if coversAllRows {
                for rowIndex in rows.indices {
                    rows[rowIndex].removeSubrange(bounds.minColumn...bounds.maxColumn)
                }
                alignments.removeSubrange(bounds.minColumn...bounds.maxColumn)
                guard !alignments.isEmpty else {
                    return replaceWholeTable(
                        table: table, package: package, storage: storage, textView: textView,
                        replacement: "", actionName: "删除表格"
                    )
                }
                selectionColumn = min(bounds.minColumn, alignments.count - 1)
                selectedBounds = TableSelectionBounds(
                    minRow: 0, maxRow: rows.count - 1,
                    minColumn: selectionColumn, maxColumn: selectionColumn
                )
                actionName = "删除表格列"
            } else {
                for row in bounds.minRow...bounds.maxRow {
                    for column in bounds.minColumn...bounds.maxColumn { rows[row][column] = "" }
                }
                selectionRow = bounds.minRow
                selectionColumn = bounds.minColumn
                selectedBounds = bounds
                actionName = "清空表格选区"
            }
        }

        return replaceTable(
            table: table, package: package, storage: storage, textView: textView,
            rows: rows, alignments: alignments,
            selectionRow: selectionRow, selectionColumn: selectionColumn,
            actionName: actionName, selectedBounds: selectedBounds
        )
    }

    @discardableResult
    public func copyTableSelection(to pasteboard: NSPasteboard, cut: Bool = false) -> Bool {
        guard presentationMode == .rendered,
              pendingDirtyRange == nil,
              let active = activeTableSelection,
              let package = lastPackage,
              let table = package.tables.first(where: { $0.headerLine == active.tableID }),
              let storage = textStorage,
              let bounds = validatedSelection(active.bounds, table: table)
        else { return false }

        let allRows = tableRows(table, package: package, storage: storage)
        let rows = (bounds.minRow...bounds.maxRow).map { row in
            Array(allRows[row][bounds.minColumn...bounds.maxColumn])
        }
        let alignments = (bounds.minColumn...bounds.maxColumn).map { table.alignment(column: $0) }
        let markdown = serializeTable(rows: rows, alignments: alignments).text
        if cut,
           !performTableAction(tableID: active.tableID, action: .delete(bounds)) {
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        pasteboard.setString(markdown, forType: NSPasteboard.PasteboardType("com.muse.table"))
        return true
    }

    @discardableResult
    public func pasteTableSelection(from pasteboard: NSPasteboard) -> Bool {
        guard presentationMode == .rendered,
              pendingDirtyRange == nil,
              let source = pasteboard.string(forType: NSPasteboard.PasteboardType("com.muse.table"))
                ?? pasteboard.string(forType: .string),
              let pasted = parsedClipboardTable(source),
              !pasted.rows.isEmpty,
              let package = lastPackage,
              let storage = textStorage,
              let textView,
              let target = tablePasteTarget(package: package)
        else { return false }

        let table = target.table
        var rows = tableRows(table, package: package, storage: storage)
        var alignments = (0..<table.columnCount).map { table.alignment(column: $0) }
        let requiredColumns = target.column + (pasted.rows.map(\.count).max() ?? 0)
        while alignments.count < requiredColumns {
            let pastedIndex = alignments.count - target.column
            alignments.append(pastedIndex >= 0 && pastedIndex < pasted.alignments.count
                              ? pasted.alignments[pastedIndex] : .leading)
            for rowIndex in rows.indices { rows[rowIndex].append("") }
        }
        let requiredRows = target.row + pasted.rows.count
        while rows.count < requiredRows {
            rows.append(Array(repeating: "", count: alignments.count))
        }
        if target.row == 0 {
            for index in pasted.alignments.indices where target.column + index < alignments.count {
                alignments[target.column + index] = pasted.alignments[index]
            }
        }
        for pastedRow in pasted.rows.indices {
            for pastedColumn in pasted.rows[pastedRow].indices {
                rows[target.row + pastedRow][target.column + pastedColumn] = pasted.rows[pastedRow][pastedColumn]
            }
        }
        let bounds = TableSelectionBounds(
            minRow: target.row,
            maxRow: target.row + pasted.rows.count - 1,
            minColumn: target.column,
            maxColumn: target.column + (pasted.rows.map(\.count).max() ?? 1) - 1
        )
        return replaceTable(
            table: table, package: package, storage: storage, textView: textView,
            rows: rows, alignments: alignments,
            selectionRow: target.row, selectionColumn: target.column,
            actionName: "粘贴表格单元格", selectedBounds: bounds
        )
    }

    private func validatedSelection(
        _ bounds: TableSelectionBounds,
        table: TableStructure
    ) -> TableSelectionBounds? {
        validatedSelection(bounds, rowCount: table.rows.count, columnCount: table.columnCount)
    }

    private func validatedSelection(
        _ bounds: TableSelectionBounds,
        rowCount: Int,
        columnCount: Int
    ) -> TableSelectionBounds? {
        guard rowCount > 0, columnCount > 0 else { return nil }
        let minRow = min(max(0, bounds.minRow), rowCount - 1)
        let maxRow = min(max(0, bounds.maxRow), rowCount - 1)
        let minColumn = min(max(0, bounds.minColumn), columnCount - 1)
        let maxColumn = min(max(0, bounds.maxColumn), columnCount - 1)
        guard minRow <= maxRow, minColumn <= maxColumn else { return nil }
        return TableSelectionBounds(
            minRow: minRow, maxRow: maxRow,
            minColumn: minColumn, maxColumn: maxColumn
        )
    }

    private func applyTableSelectionAttributes(
        table: TableStructure,
        bounds: TableSelectionBounds,
        package: RenderEngine.Package,
        storage: NSTextStorage
    ) {
        guard let range = tableSourceRange(table, package: package, storage: storage) else { return }
        suppressUndo {
            storage.addAttribute(
                .museTableCellSelection,
                value: [
                    NSNumber(value: bounds.minRow), NSNumber(value: bounds.maxRow),
                    NSNumber(value: bounds.minColumn), NSNumber(value: bounds.maxColumn),
                ],
                range: range
            )
        }
    }

    private func clearActiveTableSelectionAttributes(
        package: RenderEngine.Package,
        storage: NSTextStorage
    ) {
        guard let active = activeTableSelection,
              let table = package.tables.first(where: { $0.headerLine == active.tableID }),
              let range = tableSourceRange(table, package: package, storage: storage)
        else { return }
        suppressUndo { storage.removeAttribute(.museTableCellSelection, range: range) }
    }

    private func reapplyActiveTableSelection(
        package: RenderEngine.Package,
        storage: NSTextStorage
    ) {
        guard let active = activeTableSelection,
              let table = package.tables.first(where: { $0.headerLine == active.tableID }),
              let bounds = validatedSelection(active.bounds, table: table)
        else {
            activeTableSelection = nil
            return
        }
        let next = ActiveTableSelection(
            tableID: active.tableID,
            anchorRow: min(max(0, active.anchorRow), table.rows.count - 1),
            anchorColumn: min(max(0, active.anchorColumn), table.columnCount - 1),
            headRow: min(max(0, active.headRow), table.rows.count - 1),
            headColumn: min(max(0, active.headColumn), table.columnCount - 1)
        )
        activeTableSelection = next
        applyTableSelectionAttributes(table: table, bounds: bounds, package: package, storage: storage)
    }

    private struct ClipboardTable {
        let rows: [[String]]
        let alignments: [TableStructure.ColumnAlignment]
    }

    private func parsedClipboardTable(_ source: String) -> ClipboardTable? {
        let package = engine.prepare(source)
        if let table = package.tables.first {
            let string = source as NSString
            let rows = table.rows.map { row in
                row.cells.map { cell in
                    string.substring(with: package.index.nsRange(cell.content))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ClipboardTable(
                rows: rows,
                alignments: (0..<table.columnCount).map { table.alignment(column: $0) }
            )
        }
        let lines = source.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return nil }
        let rows = lines.map { $0.components(separatedBy: "\t") }
        let count = rows.map(\.count).max() ?? 0
        guard count > 0 else { return nil }
        return ClipboardTable(rows: rows, alignments: Array(repeating: .leading, count: count))
    }

    private func tablePasteTarget(
        package: RenderEngine.Package
    ) -> (table: TableStructure, row: Int, column: Int)? {
        if let active = activeTableSelection,
           let table = package.tables.first(where: { $0.headerLine == active.tableID }),
           let bounds = validatedSelection(active.bounds, table: table) {
            return (table, bounds.minRow, bounds.minColumn)
        }
        guard let selection = textView?.selectedRange() else { return nil }
        for table in package.tables {
            for (rowIndex, row) in table.rows.enumerated() {
                for (columnIndex, cell) in row.cells.enumerated() {
                    if Self.selection(
                        selection,
                        belongsTo: package.index.nsRange(cell.content),
                        ink: package.index.nsRange(cell.ink)
                    ) {
                        return (table, rowIndex, columnIndex)
                    }
                }
            }
        }
        return nil
    }

    /// 表格结构拖拽的统一入口。拖动过程只写瞬态属性；松手时才做一次标准文本
    /// 替换，因此整个操作只有一个撤销步骤，途中也不会让 Markdown 反复重解析。
    @discardableResult
    public func handleTableDrag(_ event: TableDragEvent) -> Bool {
        guard presentationMode == .rendered,
              pendingDirtyRange == nil,
              let package = lastPackage,
              let table = package.tables.first(where: { $0.headerLine == event.tableID }),
              let storage = textStorage,
              let textView
        else { return false }

        switch event.phase {
        case .began, .changed:
            let limit = event.axis == .row ? table.rows.count : table.columnCount
            guard event.source >= 0, event.source < limit,
                  event.destination >= 0, event.destination < limit,
                  let range = tableSourceRange(table, package: package, storage: storage)
            else { return false }
            suppressUndo {
                storage.beginEditing()
                storage.addAttributes([
                    .museTableDragAxis: event.axis.rawValue,
                    .museTableDragSource: NSNumber(value: event.source),
                    .museTableDragDestination: NSNumber(value: event.destination),
                ], range: range)
                storage.endEditing()
            }
            textView.needsDisplay = true
            return true

        case .cancelled:
            clearTableDragAttributes(table: table, package: package, storage: storage)
            textView.needsDisplay = true
            return true

        case .ended:
            clearTableDragAttributes(table: table, package: package, storage: storage)
            guard event.source != event.destination else {
                let bounds: TableSelectionBounds
                switch event.axis {
                case .row:
                    bounds = TableSelectionBounds(
                        minRow: event.source, maxRow: event.source,
                        minColumn: 0, maxColumn: max(0, table.columnCount - 1)
                    )
                case .column:
                    bounds = TableSelectionBounds(
                        minRow: 0, maxRow: max(0, table.rows.count - 1),
                        minColumn: event.source, maxColumn: event.source
                    )
                }
                _ = selectTableCells(tableID: event.tableID, bounds: bounds)
                textView.needsDisplay = true
                return true
            }
            switch event.axis {
            case .row:
                return reorderTable(
                    table: table,
                    package: package,
                    storage: storage,
                    textView: textView,
                    rowFrom: event.source,
                    rowTo: event.destination
                )
            case .column:
                return reorderTable(
                    table: table,
                    package: package,
                    storage: storage,
                    textView: textView,
                    columnFrom: event.source,
                    columnTo: event.destination
                )
            }
        }
    }

    @discardableResult
    func moveTableRow(tableID: Int, from source: Int, to destination: Int) -> Bool {
        handleTableDrag(TableDragEvent(
            phase: .ended,
            tableID: tableID,
            axis: .row,
            source: source,
            destination: destination
        ))
    }

    @discardableResult
    func moveTableColumn(tableID: Int, from source: Int, to destination: Int) -> Bool {
        handleTableDrag(TableDragEvent(
            phase: .ended,
            tableID: tableID,
            axis: .column,
            source: source,
            destination: destination
        ))
    }

    private func clearTableDragAttributes(
        table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage
    ) {
        guard let range = tableSourceRange(table, package: package, storage: storage) else { return }
        suppressUndo {
            storage.beginEditing()
            storage.removeAttribute(.museTableDragAxis, range: range)
            storage.removeAttribute(.museTableDragSource, range: range)
            storage.removeAttribute(.museTableDragDestination, range: range)
            storage.endEditing()
        }
    }

    private func tableSourceRange(
        _ table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage
    ) -> NSRange? {
        guard table.headerLine < package.lineStarts.count,
              table.lastLine < package.lineStarts.count
        else { return nil }
        let source = storage.string as NSString
        let start = package.index.utf16Offset(package.lineStarts[table.headerLine])
        let lastStart = package.index.utf16Offset(package.lineStarts[table.lastLine])
        guard start >= 0, lastStart >= start, lastStart <= source.length else { return nil }
        let lastLine = source.lineRange(for: NSRange(location: lastStart, length: 0))
        var end = NSMaxRange(lastLine)
        while end > lastLine.location {
            let character = source.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func reorderTable(
        table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage,
        textView: NSTextView,
        rowFrom source: Int,
        rowTo destination: Int
    ) -> Bool {
        guard source >= 1, source < table.rows.count,
              destination >= 1, destination < table.rows.count
        else { return false }
        var rows = tableRows(table, package: package, storage: storage)
        guard rows.count == table.rows.count else { return false }
        let moved = rows.remove(at: source)
        rows.insert(moved, at: destination)
        return replaceTable(
            table: table,
            package: package,
            storage: storage,
            textView: textView,
            rows: rows,
            alignments: table.alignments,
            selectionRow: destination,
            selectionColumn: 0,
            actionName: "移动表格行",
            selectedBounds: TableSelectionBounds(
                minRow: destination,
                maxRow: destination,
                minColumn: 0,
                maxColumn: max(0, table.columnCount - 1)
            )
        )
    }

    private func reorderTable(
        table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage,
        textView: NSTextView,
        columnFrom source: Int,
        columnTo destination: Int
    ) -> Bool {
        guard source >= 0, source < table.columnCount,
              destination >= 0, destination < table.columnCount
        else { return false }
        var rows = tableRows(table, package: package, storage: storage)
        guard !rows.isEmpty else { return false }
        for index in rows.indices {
            let moved = rows[index].remove(at: source)
            rows[index].insert(moved, at: destination)
        }
        var alignments = (0..<table.columnCount).map { table.alignment(column: $0) }
        let movedAlignment = alignments.remove(at: source)
        alignments.insert(movedAlignment, at: destination)
        return replaceTable(
            table: table,
            package: package,
            storage: storage,
            textView: textView,
            rows: rows,
            alignments: alignments,
            selectionRow: 0,
            selectionColumn: destination,
            actionName: "移动表格列",
            selectedBounds: TableSelectionBounds(
                minRow: 0,
                maxRow: max(0, table.rows.count - 1),
                minColumn: destination,
                maxColumn: destination
            )
        )
    }

    private func tableRows(
        _ table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage
    ) -> [[String]] {
        let source = storage.string as NSString
        return table.rows.map { row in
            var cells = row.cells.map { cell -> String in
                let range = package.index.nsRange(cell.content)
                guard range.location >= 0, NSMaxRange(range) <= source.length else { return "" }
                return source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if cells.count < table.columnCount {
                cells.append(contentsOf: repeatElement("", count: table.columnCount - cells.count))
            }
            return Array(cells.prefix(table.columnCount))
        }
    }

    private func replaceTable(
        table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage,
        textView: NSTextView,
        rows: [[String]],
        alignments: [TableStructure.ColumnAlignment],
        selectionRow: Int,
        selectionColumn: Int,
        actionName: String = "编辑表格",
        selectedBounds: TableSelectionBounds? = nil
    ) -> Bool {
        guard let range = tableSourceRange(table, package: package, storage: storage),
              !rows.isEmpty
        else { return false }
        let serialized = serializeTable(
            rows: rows,
            alignments: alignments,
            containerPrefix: table.containerPrefix
        )
        let original = (storage.string as NSString).substring(with: range)
        textView.breakUndoCoalescing()
        let manager = textView.undoManager
        manager?.beginUndoGrouping()
        // `shouldChangeText` 会预置 AppKit 自己的 attributed-string 撤销记录；必须
        // 从询问 delegate 开始就关闭自动注册，而不是等真正替换时才关闭。
        manager?.disableUndoRegistration()
        guard textView.shouldChangeText(in: range, replacementString: serialized.text) else {
            manager?.enableUndoRegistration()
            manager?.endUndoGrouping()
            textView.breakUndoCoalescing()
            return false
        }
        storage.replaceCharacters(in: range, with: serialized.text)
        textView.didChangeText()
        manager?.enableUndoRegistration()
        manager?.registerUndo(withTarget: self) { coordinator in
            coordinator.performRegisteredTableReplacement(
                at: range.location,
                replacing: serialized.text,
                with: original,
                actionName: actionName
            )
        }
        manager?.setActionName(actionName)
        activeTableSelection = selectedBounds.map {
            ActiveTableSelection(tableID: table.headerLine, bounds: $0)
        }
        if selectionRow < serialized.cells.count,
           selectionColumn < serialized.cells[selectionRow].count {
            let relative = serialized.cells[selectionRow][selectionColumn]
            let selection = NSRange(location: range.location + relative.location, length: relative.length)
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
        }
        manager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        return true
    }

    private func replaceWholeTable(
        table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage,
        textView: NSTextView,
        replacement: String,
        actionName: String
    ) -> Bool {
        guard let range = tableSourceRange(table, package: package, storage: storage) else { return false }
        let original = (storage.string as NSString).substring(with: range)
        textView.breakUndoCoalescing()
        let manager = textView.undoManager
        manager?.beginUndoGrouping()
        manager?.disableUndoRegistration()
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            manager?.enableUndoRegistration()
            manager?.endUndoGrouping()
            textView.breakUndoCoalescing()
            return false
        }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        manager?.enableUndoRegistration()
        manager?.registerUndo(withTarget: self) { coordinator in
            coordinator.performRegisteredTableReplacement(
                at: range.location,
                replacing: replacement,
                with: original,
                actionName: actionName
            )
        }
        manager?.setActionName(actionName)
        activeTableSelection = nil
        let caret = NSRange(location: min(range.location, storage.length), length: 0)
        textView.setSelectedRange(caret)
        manager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        return true
    }

    /// NSTextStorage 的默认撤销会保存带渲染属性的 attributed substring；表格替换后
    /// 异步属性重排会让它内部记录的区间失效。这里仅记录两份纯 Markdown 字符串，
    /// undo/redo 都按当前字符串长度做对称替换，既稳定也保证一次拖拽只有一步。
    private func performRegisteredTableReplacement(
        at location: Int,
        replacing current: String,
        with replacement: String,
        actionName: String
    ) {
        guard let storage = textStorage, let textView else { return }
        let range = NSRange(location: location, length: (current as NSString).length)
        guard location >= 0, NSMaxRange(range) <= storage.length else { return }

        let manager = textView.undoManager
        manager?.registerUndo(withTarget: self) { coordinator in
            coordinator.performRegisteredTableReplacement(
                at: location,
                replacing: replacement,
                with: current,
                actionName: actionName
            )
        }
        manager?.setActionName(actionName)
        manager?.disableUndoRegistration()
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        manager?.enableUndoRegistration()
        activeTableSelection = nil
        let caret = NSRange(location: min(location, storage.length), length: 0)
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
    }

    private func serializeTable(
        rows: [[String]],
        alignments: [TableStructure.ColumnAlignment],
        containerPrefix: String = ""
    ) -> SerializedTable {
        let columnCount = rows.map(\.count).max() ?? 0
        var text = ""
        var ranges: [[NSRange]] = []

        func appendRow(_ cells: [String]) -> [NSRange] {
            var result: [NSRange] = []
            text += containerPrefix + "|"
            for column in 0..<columnCount {
                let cell = column < cells.count ? cells[column] : ""
                text += " "
                let location = (text as NSString).length
                text += cell
                result.append(NSRange(location: location, length: (cell as NSString).length))
                text += " |"
            }
            return result
        }

        ranges.append(appendRow(rows[0]))
        text += "\n" + containerPrefix + "|"
        for column in 0..<columnCount {
            let alignment = column < alignments.count ? alignments[column] : .leading
            switch alignment {
            case .leading: text += " --- |"
            case .center: text += " :---: |"
            case .trailing: text += " ---: |"
            }
        }
        for row in rows.dropFirst() {
            text += "\n"
            ranges.append(appendRow(row))
        }
        return SerializedTable(text: text, cells: ranges)
    }

    private func performTableNavigation(
        _ direction: TableNavigationDirection,
        package: RenderEngine.Package
    ) -> Bool {
        guard let textView, let storage = textStorage else { return false }
        let selection = textView.selectedRange()

        for table in package.tables {
            let cells = table.rows.enumerated().flatMap { rowIndex, row in
                row.cells.enumerated().map { columnIndex, cell in
                    EditableTableCell(
                        table: table,
                        row: rowIndex,
                        column: columnIndex,
                        content: package.index.nsRange(cell.content),
                        ink: package.index.nsRange(cell.ink)
                    )
                }
            }
            guard let current = cells.firstIndex(where: {
                Self.selection(selection, belongsTo: $0.content, ink: $0.ink)
            }) else { continue }

            switch direction {
            case .backward:
                guard current > 0 else { return true }
                selectTableCell(cells[current - 1].ink, in: textView)
                return true
            case .forward:
                if current + 1 < cells.count {
                    selectTableCell(cells[current + 1].ink, in: textView)
                    return true
                }
                return appendTableRow(after: cells[current].table, package: package,
                                      storage: storage, textView: textView, targetColumn: 0)
            case .returnKey:
                let cell = cells[current]
                if cell.row + 1 < table.rows.count {
                    let nextRow = table.rows[cell.row + 1]
                    guard !nextRow.cells.isEmpty else { return true }
                    let nextColumn = min(cell.column, nextRow.cells.count - 1)
                    selectTableCell(package.index.nsRange(nextRow.cells[nextColumn].ink), in: textView)
                    return true
                }
                return appendTableRow(after: cells[current].table, package: package,
                                      storage: storage, textView: textView,
                                      targetColumn: cell.column)
            case .arrow(let direction):
                let cell = cells[current]
                switch direction {
                case .up:
                    guard cell.row > 0 else { return false }
                    let previousRow = table.rows[cell.row - 1]
                    guard !previousRow.cells.isEmpty else { return true }
                    let column = min(cell.column, previousRow.cells.count - 1)
                    placeTableCaret(
                        at: package.index.nsRange(previousRow.cells[column].ink).location,
                        in: textView
                    )
                    return true
                case .down:
                    guard cell.row + 1 < table.rows.count else { return false }
                    let nextRow = table.rows[cell.row + 1]
                    guard !nextRow.cells.isEmpty else { return true }
                    let column = min(cell.column, nextRow.cells.count - 1)
                    placeTableCaret(
                        at: package.index.nsRange(nextRow.cells[column].ink).location,
                        in: textView
                    )
                    return true
                case .left:
                    guard selection.location <= cell.ink.location, current > 0 else { return false }
                    placeTableCaret(at: NSMaxRange(cells[current - 1].ink), in: textView)
                    return true
                case .right:
                    guard selection.location >= NSMaxRange(cell.ink), current + 1 < cells.count else {
                        return false
                    }
                    placeTableCaret(at: cells[current + 1].ink.location, in: textView)
                    return true
                }
            }
        }
        return false
    }

    private func drainPendingTableNavigations(package: RenderEngine.Package) {
        while pendingDirtyRange == nil, !pendingTableNavigations.isEmpty {
            let direction = pendingTableNavigations.removeFirst()
            _ = performTableNavigation(direction, package: package)
        }
    }

    private func editableTableCell(
        at selection: NSRange?,
        package: RenderEngine.Package
    ) -> EditableTableCell? {
        guard let selection else { return nil }
        for table in package.tables {
            for (rowIndex, row) in table.rows.enumerated() {
                for (columnIndex, cell) in row.cells.enumerated() {
                    let editable = EditableTableCell(
                        table: table,
                        row: rowIndex,
                        column: columnIndex,
                        content: package.index.nsRange(cell.content),
                        ink: package.index.nsRange(cell.ink)
                    )
                    if Self.selection(selection, belongsTo: editable.content, ink: editable.ink) {
                        return editable
                    }
                }
            }
        }
        return nil
    }

    private static func selection(_ selection: NSRange, belongsTo content: NSRange, ink: NSRange) -> Bool {
        if selection.length == 0 {
            return selection.location >= content.location
                && selection.location <= NSMaxRange(content)
        }
        if ink.length > 0, NSIntersectionRange(selection, ink).length > 0 {
            return true
        }
        return selection.location >= content.location && NSMaxRange(selection) <= NSMaxRange(content)
    }

    private func selectTableCell(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private func placeTableCaret(at location: Int, in textView: NSTextView) {
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private func appendTableRow(
        after table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage,
        textView: NSTextView,
        targetColumn: Int
    ) -> Bool {
        guard table.columnCount > 0, table.lastLine < package.lineStarts.count else { return true }
        let source = storage.string as NSString
        let lineStart = package.index.utf16Offset(package.lineStarts[table.lastLine])
        guard lineStart <= source.length else { return true }

        let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location {
            let character = source.character(at: contentEnd - 1)
            guard character == 0x0A || character == 0x0D else { break }
            contentEnd -= 1
        }
        let hasTerminator = contentEnd < NSMaxRange(lineRange)
        let row = table.containerPrefix
            + "|"
            + Array(repeating: "  ", count: table.columnCount).joined(separator: "|")
            + "|"
        let insertion = hasTerminator ? NSMaxRange(lineRange) : contentEnd
        let replacement = hasTerminator ? row + "\n" : "\n" + row
        let rowStart = insertion + (hasTerminator ? 0 : 1)
        let column = min(max(0, targetColumn), table.columnCount - 1)
        let prefixLength = (table.containerPrefix as NSString).length
        let targetCellCaret = NSRange(location: rowStart + prefixLength + 2 + column * 3, length: 0)

        guard textView.shouldChangeText(
            in: NSRange(location: insertion, length: 0),
            replacementString: replacement
        ) else { return true }

        textView.breakUndoCoalescing()
        let manager = textView.undoManager
        manager?.beginUndoGrouping()
        textView.insertText(replacement, replacementRange: NSRange(location: insertion, length: 0))
        // AppKit 会按光标两侧字符重算 typingAttributes，所以先放光标，再由下面的
        // 过渡态渲染把可见输入属性固定下来。
        textView.setSelectedRange(targetCellCaret)
        applyTransientTableRow(
            rowStart: rowStart,
            rowLength: (row as NSString).length,
            table: table,
            package: package,
            storage: storage,
            textView: textView
        )
        manager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        return true
    }

    /// 新行插入后后台解析通常只需几毫秒，但这几毫秒里 NSTextView 会继承末行的
    /// 可见输入属性，于是 `|  |  |` 会闪成源码。先按已有列边界写一份可丢弃的网格
    /// 属性；最新 AST 落地后，正常增量渲染会完整覆盖它。
    private func applyTransientTableRow(
        rowStart: Int,
        rowLength: Int,
        table: TableStructure,
        package: RenderEngine.Package,
        storage: NSTextStorage,
        textView: NSTextView
    ) {
        guard rowLength > 0, rowStart >= 0, rowStart + rowLength <= storage.length,
              let lastRow = table.rows.last,
              let firstCell = lastRow.cells.first
        else { return }

        let previousLocation = package.index.utf16Offset(firstCell.ink.lowerBound)
        guard previousLocation < storage.length,
              let boundaries = storage.attribute(
                .museTableColumns,
                at: previousLocation,
                effectiveRange: nil
              ) as? [NSNumber]
        else { return }

        let theme = Theme.standard
        let rowRange = NSRange(location: rowStart, length: rowLength)
        let source = storage.string as NSString
        let previousLine = source.paragraphRange(
            for: NSRange(location: previousLocation, length: 0)
        )

        suppressUndo {
            storage.beginEditing()
            storage.addAttribute(
                .paragraphStyle,
                value: theme.tableParagraph(isLast: false),
                range: previousLine
            )
            storage.removeAttribute(.museBlockRole, range: previousLine)

            storage.addAttributes([
                .museBlock: BlockVisual.table.rawValue,
                .museBlockRole: "close",
                .museTableColumns: boundaries,
                .museTableRow: NSNumber(value: table.rows.count),
                .museTableID: NSNumber(value: table.headerLine),
                .paragraphStyle: theme.tableParagraph(isLast: true),
            ], range: rowRange)
            storage.addAttributes(
                RenderEngine.markerVisibilityAttributes(state: .hidden),
                range: rowRange
            )

            // 生成行固定是 `|  |  |`：每格三枚结构字符。把各格的空内容落点推到
            // 对应列内边距，输入第一个字符时不会先出现在表格最左侧。
            let values = boundaries.map { CGFloat($0.doubleValue) }
            var priorTarget: CGFloat = 0
            for column in 0..<min(table.columnCount, values.count - 1) {
                let carrier = rowStart + column * 3
                guard carrier < rowStart + rowLength else { break }
                let target = values[column] + Theme.tableCellPaddingX
                storage.addAttribute(
                    .kern,
                    value: NSNumber(value: Double(target - priorTarget)),
                    range: NSRange(location: carrier, length: 1)
                )
                priorTarget = target
            }
            storage.endEditing()
        }

        // 光标两侧都是隐藏空格，显式给下一次输入可见属性，避免等待解析期间首字
        // 也继承 0.1pt 字体。
        textView.typingAttributes = [
            .font: theme.baseFont(),
            .foregroundColor: theme.text,
            .paragraphStyle: theme.tableParagraph(isLast: true),
            .museBlock: BlockVisual.table.rawValue,
            .museBlockRole: "close",
            .museTableColumns: boundaries,
            .museTableRow: NSNumber(value: table.rows.count),
            .museTableID: NSNumber(value: table.headerLine),
        ]
        textView.needsDisplay = true
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

    private static func clampedDirtyRange(_ range: NSRange, toLength length: Int) -> NSRange {
        let lower = min(max(range.location, 0), length)
        let upper = min(max(NSMaxRange(range), lower), length)
        return NSRange(location: lower, length: upper - lower)
    }

    /// 缺陷 1 的确定性测试插桩：真实编辑仍走 NSTextStorage delegate，仅冻结后台消费。
    func setParseLoopPausedForTesting(_ paused: Bool) {
        isParseLoopPausedForTesting = paused
        if !paused { startParseLoopIfNeeded() }
    }

    var revisionForTesting: Int { revision }
    var pendingDirtyRangeForTesting: NSRange? { pendingDirtyRange }
    var isParseDeferredForMarkedTextForTesting: Bool { isParseDeferredForMarkedText }
    var needsMathRefreshForTesting: Bool { needsMathRefresh }

    func waitForImagePreparationForTesting() async {
        let task = imagePreparationTask
        await task?.value
    }

    func waitForMathPreparationForTesting() async {
        let task = mathPreparationTask
        await task?.value
    }

    func applyParsedForTesting(
        package: RenderEngine.Package,
        revision: Int,
        dirtyRange: NSRange
    ) {
        applyParsed(package: package, rev: revision, dirtyNS: dirtyRange)
    }

    @discardableResult
    func consumeLatestParseRequestForTesting(package: RenderEngine.Package) -> Bool {
        guard let request = latestParseRequest else { return false }
        latestParseRequest = nil
        applyParsed(
            package: package,
            rev: request.revision,
            dirtyNS: request.dirtyRange
        )
        return true
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
            if lastReconcileWriteCount > 0 {
                textView?.needsDisplay = true
            }
        }
    }

    /// 编辑视图挂接后调用：用真实选区补齐首次显隐（初始渲染发生在 textView 存在之前）。
    public func refreshMarkerVisibility(into storage: NSTextStorage) {
        guard presentationMode == .rendered, !isApplyingAttributes, pendingDirtyRange == nil else { return }
        guard let package = lastPackage else { return }
        suppressUndo {
            reconcileVisibility(package: package, selection: textView?.selectedRange(), into: storage, forceLines: nil)
            if lastReconcileWriteCount > 0 {
                textView?.needsDisplay = true
            }
        }
    }

    /// 滚动或布局变化时更新可视正文锚点。标题按源码顺序排列，用二分查找避免
    /// 在高频滚动路径中随标题数量线性退化。
    public func updateVisibleHeading(at documentLocation: Int?) {
        visibleDocumentLocation = documentLocation
        refreshVisibleHeading()
    }

    /// Controls whether editable block syntax (for example `# ` and `> `) is
    /// revealed under the caret while the editor remains in rendered mode.
    public func setRevealsCurrentBlockSource(_ enabled: Bool) {
        guard revealsCurrentBlockSource != enabled else { return }
        revealsCurrentBlockSource = enabled
        revealCache.removeAll(keepingCapacity: true)
        guard presentationMode == .rendered,
              !isApplyingAttributes,
              pendingDirtyRange == nil,
              let package = lastPackage,
              let storage = textStorage
        else { return }
        suppressUndo {
            reconcileVisibility(
                package: package,
                selection: textView?.selectedRange(),
                into: storage,
                forceLines: nil
            )
            if lastReconcileWriteCount > 0 {
                textView?.needsDisplay = true
            }
        }
    }

    /// 供测试直接注入已解析的 package（正常路径由编辑流自动写入）。
    public func adoptPackage(_ package: RenderEngine.Package) {
        lastPackage = package
    }

    /// 供测试注入正常 UI 已无法创建的陈旧结构选区，以独立验证模式和 revision
    /// 闸门；生产路径只通过 `selectTableCells` 创建选区。
    func adoptTableSelectionForTesting(tableID: Int, bounds: TableSelectionBounds?) {
        activeTableSelection = bounds.map { ActiveTableSelection(tableID: tableID, bounds: $0) }
    }

    /// 在即时渲染与源码模式之间切换。两种模式共享同一份正文，切换只重建
    /// 可丢弃属性，不进入 undo 栈，也不创建第二份 String。
    public func setPresentationMode(_ mode: RenderEngine.PresentationMode) {
        if presentationMode != mode {
            presentationMode = mode
            revealCache.removeAll(keepingCapacity: true)
            lastReconcileWriteCount = 0
            if mode != .rendered {
                pendingTableNavigations.removeAll(keepingCapacity: true)
                activeTableSelection = nil
            }
        }
        applyPresentationModeIfPossible()
    }

    /// 组合输入结束时由编辑视图重试尚未落地的模式切换。
    /// NSTextView 的 marked text 仍由系统独占，不在候选态上改写属性。
    public func refreshPresentationMode() {
        resumeParsingAfterMarkedTextIfPossible()
        applyPresentationModeIfPossible()
        applyImageRefreshIfPossible()
        applyMathRefreshIfPossible()
    }

    private func resumeParsingAfterMarkedTextIfPossible() {
        guard isParseDeferredForMarkedText,
              textView?.hasMarkedText() != true
        else { return }
        isParseDeferredForMarkedText = false
        if latestParseRequest == nil, let storage = textStorage {
            enqueueCurrentParse(storage: storage)
        }
        startParseLoopIfNeeded()
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
                revealsCurrentBlockSource: revealsCurrentBlockSource,
                into: storage,
                imageBaseURL: imageBaseURL
            )
            textView?.needsDisplay = true
        }
        isApplyingAttributes = false
        appliedPresentationMode = presentationMode
        if presentationMode == .rendered {
            recordMathArtifactsApplied()
            scheduleMathPreparation(package: package, revision: revision)
        } else {
            mathPreparationTask?.cancel()
        }
    }

    private func applyImageRefreshIfPossible() {
        guard needsImageRefresh,
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
                revealsCurrentBlockSource: revealsCurrentBlockSource,
                into: storage,
                imageBaseURL: imageBaseURL
            )
            textView?.needsDisplay = true
        }
        isApplyingAttributes = false
        appliedPresentationMode = presentationMode
        needsImageRefresh = false
        if presentationMode == .rendered {
            recordMathArtifactsApplied()
        }
        revealCache.removeAll(keepingCapacity: true)
        lastReconcileWriteCount = 0
    }

    private func applyMathRefreshIfPossible() {
        guard needsMathRefresh,
              presentationMode == .rendered,
              textView?.hasMarkedText() != true,
              !isApplyingAttributes,
              pendingDirtyRange == nil,
              let package = lastPackage,
              let storage = textStorage
        else { return }

        isApplyingAttributes = true
        suppressUndo {
            _ = engine.refreshMathArtifacts(
                package: package,
                selection: textView?.selectedRange(),
                revealsCurrentBlockSource: revealsCurrentBlockSource,
                into: storage
            )
            textView?.needsDisplay = true
        }
        isApplyingAttributes = false
        recordMathArtifactsApplied()
    }

    private func recordMathArtifactsApplied() {
        appliedMathArtifactGeneration = MathRenderer.shared.artifactGeneration
        needsMathRefresh = false
    }

    /// 侧边栏点击 heading 时调用：把选区放到标题行首并滚动可见。
    ///
    /// `heading.lineRange` 来自 `makeOutline`，是 package 派生的区间。脏区未清时
    /// `lastPackage` 对应的是编辑前的正文，此刻跳转会按旧行偏移定位——项目里其余
    /// 消费 package 派生区间的地方都有 `pendingDirtyRange == nil` 闸门，这里原来
    /// 漏了。改为排队等最新 outline，而不是丢掉这次点击。
    public func reveal(heading: OutlineHeading) {
        guard pendingDirtyRange == nil else {
            pendingOutlineReveal = heading.id
            return
        }
        performReveal(heading: heading)
    }

    private func performReveal(heading: OutlineHeading) {
        guard let textView, let storage = textStorage else { return }
        let length = storage.length
        guard heading.lineRange.location + heading.lineRange.length <= length else { return }
        let caret = NSRange(location: heading.lineRange.location, length: 0)
        textView.setSelectedRange(caret)
        // 先做一次最小滚动：它顺带保证目标那一段已经排好版，下面量 fragment 才有
        // 值可量。然后再精确定位——两步都在同一帧里，看不到中间态。
        textView.scrollRangeToVisible(heading.lineRange)
        scrollHeadingNearTop(at: caret.location, in: textView)
        textView.window?.makeFirstResponder(textView)
    }

    /// 大纲跳转时标题行距视口顶端留出的余量。贴死顶边看着像被截断。
    private static let outlineRevealTopMargin: CGFloat = 12

    /// 把标题行送到视口靠上的位置。
    ///
    /// `scrollRangeToVisible` 只做**最小**滚动：从上往下跳时，目标停在视口*底*边，
    /// 跳过去的那一节整个在屏幕外，等于跳了又没跳。这里主动定位，两个方向都让
    /// 这一节从顶部开始。
    ///
    /// 文档末尾附近够不到那么下面，所以按可滚动范围夹住——夹不住就会滚到空白。
    private func scrollHeadingNearTop(at location: Int, in textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let textLocation = contentManager.location(
                contentManager.documentRange.location, offsetBy: location
              ),
              let fragment = layoutManager.textLayoutFragment(for: textLocation)
        else { return }

        let clipView = scrollView.contentView
        let targetY = fragment.layoutFragmentFrame.minY
            + textView.textContainerOrigin.y
            - Self.outlineRevealTopMargin
        let maxY = max(0, clipView.documentRect.height - clipView.bounds.height)
        clipView.scroll(to: CGPoint(
            x: clipView.bounds.origin.x,
            y: min(max(0, targetY), maxY)
        ))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 最新 outline 落地后补做排队中的跳转。按 id 在**新** outline 里重新取区间；
    /// 那个标题已经被这次编辑删掉时就丢弃，绝不复用旧坐标。
    private func drainPendingOutlineReveal() {
        guard let id = pendingOutlineReveal else { return }
        pendingOutlineReveal = nil
        guard let heading = outline.first(where: { $0.id == id }) else { return }
        performReveal(heading: heading)
    }

    // MARK: - 内部

    private func refreshVisibleHeading() {
        let headingID = Self.headingID(
            in: outline,
            at: visibleDocumentLocation
        )
        guard visibleHeadingID != headingID else { return }
        visibleHeadingID = headingID
    }

    private static func headingID(
        in outline: [OutlineHeading],
        at documentLocation: Int?
    ) -> Int? {
        guard let documentLocation, outline.isEmpty == false else { return nil }

        var lowerBound = 0
        var upperBound = outline.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if outline[middle].lineRange.location <= documentLocation {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        guard lowerBound > 0 else { return nil }
        return outline[lowerBound - 1].id
    }

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

        let entries = engine.computedVisibility(
            package: package,
            selection: selection,
            revealsCurrentBlockSource: revealsCurrentBlockSource
        )
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
        // With no caret every marker has the same state. `applyDirty` only resets the forced
        // lines, so walking and rebuilding identities for the rest of a large document is pure
        // overhead. Keep no reveal cache in this mode; when a text view is attached, the normal
        // reconciliation path will populate it from the actual selection.
        revealCache.removeAll(keepingCapacity: true)
        guard let forceLines else {
            lastReconcileWriteCount = 0
            return
        }
        var firstWrite = true
        var writeCount = 0

        for tokenIndex in package.tokenIndices(overlapping: forceLines) {
            let token = package.tokens[tokenIndex]
            guard package.tokenLineRanges[tokenIndex].overlaps(forceLines) else { continue }
            // `markerVisibilityRanges`（而不是 allMarkerRanges）：块图片整段折叠，
            // 只隐藏 `![` 与 `](目的地)` 会把标签留在正文里。
            for range in token.markerVisibilityRanges {
                let identity = engine.markerIdentity(for: range, package: package)
                guard forceLines.contains(identity.line) else { continue }
                if firstWrite {
                    storage.beginEditing()
                    firstWrite = false
                }
                let markerNS = package.index.nsRange(range)
                if token.mathExpression != nil {
                    let isBlock: Bool
                    if case .blockMath = token.kind { isBlock = true } else { isBlock = false }
                    engine.applyMathVisibility(
                        state: .hidden,
                        span: markerNS,
                        markerSubRange: package.index.nsRange(token.markerRange),
                        closingSubRange: token.closingMarkerRange.map(package.index.nsRange),
                        contentSubRange: token.contentRange.map(package.index.nsRange),
                        isBlock: isBlock,
                        into: storage
                    )
                } else if token.inlineImageRange != nil {
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
        }

        if !firstWrite {
            storage.endEditing()
        }
        lastReconcileWriteCount = writeCount
    }

    private func suppressUndo(_ body: () -> Void) {
        let undoManager = textView?.undoManager
        undoManager?.disableUndoRegistration()
        body()
        undoManager?.enableUndoRegistration()
    }
}
