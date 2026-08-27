import AppKit
import Testing
@testable import MuseKit

/// M0 性能基准：20KB / 200KB（混合中文 + markdown 构造）的
/// 「扫描 + 索引」与「属性批量应用」耗时。目标（v0.2 4.6）不作为断言门槛，
/// 只记录基线数据；断言上限为"不死循环/明显退化"的粗防线。
@Suite(.serialized) @MainActor struct PerformanceTests {
    let clock = ContinuousClock()

    /// 确定性语料：重复若干种块，直到达到目标大小。
    static func corpus(kb: Int) -> String {
        let unit = """
        # 标题 与 Heading

        这是一个中英文混合段落，包含 **粗体**、*斜体*、`代码` 与 ~~删除线~~。
        Emoji: 😀 🚀 👨‍👩‍👧‍👦 and some English words to fill the line length.

        - 列表项 one
        - 列表项 two with 中文
          - 嵌套列表项 nested

        1. 有序第一
        2. 有序第二

        > 引用块内容，包含 **加粗** 与中文。

        ```swift
        func sample() -> Int { return 42 } // 代码块
        ```

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
        #expect(ms(parseDuration) < 3000) // 仅防明显退化
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
        #expect(latency < 100) // 端到端含后台解析；主线程成本的实测值见 m0-report §2
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
        // 粗防线：200KB 整篇管线应远低于 500ms（目标 <16ms P95 待增量优化后验收）
        #expect(parseMs + applyMs < 500)
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
