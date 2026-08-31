import AppKit
import Testing
@testable import MuseKit

/// M0 性能基准：20KB / 200KB（混合中文 + markdown 构造）的
/// 「扫描 + 索引」与「属性批量应用」耗时。目标（v0.2 4.6）不作为断言门槛，
/// 只记录基线数据；断言上限为"不死循环/明显退化"的粗防线。
///
/// 语料刻意把**表格与块图片**也算进去：这两种块的样式要跨行量列宽、要解析图片
/// 路径，是全篇里最贵的一档。语料里每 ~150 字节就有一张表，比任何真实文档都密集，
/// 因此这里的数字是上界而不是典型值。
@Suite(.serialized) @MainActor struct PerformanceTests {
    let clock = ContinuousClock()

    private static var fullPipelineBudgetMilliseconds: Double {
        #if DEBUG
        900
        #else
        500
        #endif
    }

    /// 确定性语料：重复若干种块，直到达到目标大小。
    static func corpus(kb: Int) -> String {
        // 缺陷 12 的性能守卫：单行引用无法暴露“换行后整段重排”。每个语料单元
        // 都带 40 行连续引用，确保 20KB/200KB 基准都覆盖长引用拓扑。
        let quoteBlock = (1...40)
            .map { "> 引用块第 \($0) 行，包含 **加粗**、中文与 lazy-continuation 邻接。" }
            .joined(separator: "\n")
        let unit = """
        # 标题 与 Heading

        这是一个中英文混合段落，包含 **粗体**、*斜体*、`代码` 与 ~~删除线~~。
        Emoji: 😀 🚀 👨‍👩‍👧‍👦 and some English words to fill the line length.

        - 列表项 one
        - 列表项 two with 中文
          - 嵌套列表项 nested

        1. 有序第一
        2. 有序第二

        \(quoteBlock)

        ```swift
        func sample() -> Int { return 42 } // 代码块
        ```

        | 列 A | 列 B | 列 C |
        |---|:---:|---:|
        | 即时渲染 | ✅ | 42 |
        | table row 中英混排 | ok | 1024 |

        ![块图片](corpus-image.png)

        ---

        """
        let unitBytes = unit.utf8.count
        var doc = ""
        doc.reserveCapacity(kb * 1024)
        while doc.utf8.count < kb * 1024 {
            doc += unit
        }
        _ = unitBytes
        return doc
    }

    @Test func fullPipelineBudgetMatchesBuildConfiguration() {
        #if DEBUG
        #expect(Self.fullPipelineBudgetMilliseconds == 900)
        #else
        #expect(Self.fullPipelineBudgetMilliseconds == 500)
        #endif
    }

    @Test func perf20KB() throws {
        try measure(kb: 20)
    }

    @Test func perf200KB() throws {
        try measure(kb: 200)
    }

    @Test func perf1MBSmoke() throws {
        let source = Self.corpus(kb: 1024)
        let parseDuration = clock.measure {
            let package = RenderEngine().prepare(source)
            let storage = NSTextStorage(string: source)
            _ = RenderEngine().render(package: package, selection: NSRange(location: 0, length: 0), into: storage)
        }
        print("[PERF] 1MB 全管线: \(ms(parseDuration)) ms, 字数: \(source.utf16.count)")
        // 仅防明显退化。Debug 下 swift-markdown 带编译器插桩，解析本身就占大头
        // （实测 200KB 解析 Debug 110ms vs Release 86ms），产品门槛以 Release 为准。
        // 语料在表格/块图片加入后变密，实测 Release 2149ms / Debug 3016ms。
        #if DEBUG
        #expect(ms(parseDuration) < 5000)
        #else
        #expect(ms(parseDuration) < 3000)
        #endif
    }

    @Test func perfDirtyApply200KB() {
        // 输入热路径基准：200KB 文档中部的单字符脏区增量应用
        let source = Self.corpus(kb: 200)
        let engine = RenderEngine()
        let package = engine.prepare(source)
        let storage = NSTextStorage(string: source)
        _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)

        let mid = NSRange(location: source.utf16.count / 2, length: 1)
        let dirtyDuration = clock.measure {
            engine.applyDirty(package: package, previousPackage: nil, utf16Range: mid, into: storage)
        }
        let dirtyMs = ms(dirtyDuration)
        print("[PERF] 200KB 引擎层脏行增量应用: \(dirtyMs) ms")
        // 方案目标：输入主线程预算 200KB < 16ms（P95）
        #expect(dirtyMs < 50) // 粗防线；达标线 16ms 由 M6 实测验收
    }

    /// 第二轮复审 P2：性能必须走真实协调器路径（编辑回调 → 快照 → 后台解析 → revision
    /// → 增量应用 → marker reconcile），而不是只调引擎层 applyDirty。
    @Test @MainActor func perfCoordinatorSingleKeystroke200KB() async {
        let source = Self.corpus(kb: 200)
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        var waited = 0
        while coordinator.appliedRevision < 1, waited < 10_000 {
            try? await Task.sleep(for: .milliseconds(2)); waited += 2
        }
        #expect(coordinator.appliedRevision >= 1)

        let start = clock.now
        let mid = NSRange(location: source.utf16.count / 2, length: 0)
        storage.replaceCharacters(in: mid, with: "好") // 一次真实单键输入
        waited = 0
        while coordinator.appliedRevision < 2, waited < 20_000 {
            try? await Task.sleep(for: .milliseconds(2)); waited += 2
        }
        let latency = ms(start.duration(to: clock.now))
        print("[PERF] 200KB 协调器单键路径(编辑→样式落地): \(latency) ms, 显隐写入 marker: \(coordinator.lastReconcileWriteCount)")
        #expect(coordinator.appliedRevision >= 2)
        // Debug builds of swift-markdown carry compiler/coverage instrumentation, so they only
        // enforce a gross-regression guard. The product latency budget is asserted in Release.
        #if DEBUG
        #expect(latency < 300)
        #else
        #expect(latency < 150)
        #endif
    }

    /// 缺陷 18：200KB 上同一轮连续输入不得再次把 dirty 请求退化成整篇。
    /// 这里用范围插桩验证装饰工作量，并打印最后一键到属性落地的真实端到端时间；
    /// 时间仅作为观测值，避免把机器负载差异写成脆弱断言。
    @Test @MainActor func perfCoordinatorContinuousTypingKeepsDirtyRangeLocal200KB() async {
        let source = Self.corpus(kb: 200)
        let storage = NSTextStorage(string: source)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        var waited = 0
        while coordinator.appliedRevision < 1, waited < 30_000 {
            try? await Task.sleep(for: .milliseconds(2)); waited += 2
        }
        #expect(coordinator.appliedRevision >= 1)

        let typed = "incremental"
        let nsSource = storage.string as NSString
        let half = nsSource.length / 2
        let nextLine = nsSource.range(
            of: "\n",
            range: NSRange(location: half, length: nsSource.length - half)
        )
        var insertion = nextLine.location == NSNotFound ? half : nextLine.location + 1
        let startRevision = coordinator.appliedRevision
        let startPreparationCount = coordinator.parsePreparationCount
        for character in typed {
            storage.replaceCharacters(in: NSRange(location: insertion, length: 0), with: String(character))
            insertion += 1
        }
        let lastKey = clock.now

        waited = 0
        while coordinator.appliedRevision < startRevision + typed.count, waited < 30_000 {
            try? await Task.sleep(for: .milliseconds(2)); waited += 2
        }
        let latency = ms(lastKey.duration(to: clock.now))
        let dirty = coordinator.lastAppliedDirtyRange
        print("[PERF] 200KB 连续输入最后一键→属性落地: \(latency) ms | dirty: \(String(describing: dirty)) / \(storage.length)")

        #expect(coordinator.appliedRevision >= startRevision + typed.count)
        #expect(coordinator.parsePreparationCount == startPreparationCount + 1)
        // NSTextStorage 在行首插入时可能把相邻换行一并计入 didProcessEditing 范围；
        // 允许常数级边界扩张，但绝不能随文档规模增长。
        #expect((dirty?.length ?? storage.length) <= typed.utf16.count + 2)
        #expect((dirty?.length ?? storage.length) < storage.length / 100)
    }

    private func measure(kb: Int) throws {
        let source = Self.corpus(kb: kb)
        let engine = RenderEngine()

        var tokenCount = 0
        let parseDuration = clock.measure {
            let package = engine.prepare(source)
            tokenCount = package.tokens.count
        }

        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let applyDuration = clock.measure {
            _ = engine.render(package: package, selection: NSRange(location: 0, length: 0), into: storage)
        }

        let parseMs = ms(parseDuration)
        let applyMs = ms(applyDuration)
        print("[PERF] \(kb)KB 扫描+索引: \(parseMs) ms | 属性应用: \(applyMs) ms | tokens: \(tokenCount) | 字数: \(source.utf16.count)")
        // Debug 下 swift-markdown 带编译器插桩，只守 900ms 粗防线；
        // 产品门槛仍由 Release 的 500ms 约束。
        #expect(parseMs + applyMs < Self.fullPipelineBudgetMilliseconds)
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
