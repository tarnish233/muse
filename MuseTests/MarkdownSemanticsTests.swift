import Foundation
import Testing
@testable import MuseKit

/// M2：swift-markdown 语义层 —— 链接锚点与 scanner↔AST 行级块分类的差异测试。
@Suite struct MarkdownSemanticsTests {
    let engine = RenderEngine()

    // MARK: - 链接

    @Test func inlineLinkBounds() throws {
        let source = "[label](https://x.com)"
        let tokens = engine.prepare(source).tokens
        let link = try #require(tokens.first { $0.kind == .link })
        #expect(link.markerRange == 0..<1)                 // [
        #expect(link.contentRange == 1..<6)                // label
        #expect(link.closingMarkerRange == 6..<22)         // ]( 到 )
        #expect(link.linkDestination == 8..<21)            // https://x.com
    }

    @Test func nestedBracketLabel() throws {
        let source = "[a [b] c](u)"
        let tokens = engine.prepare(source).tokens
        let link = try #require(tokens.first { $0.kind == .link })
        #expect(link.contentRange == 1..<8) // "a [b] c"
        #expect(link.linkDestination == 10..<11) // "u"
    }

    @Test func linkInsideBold() throws {
        let source = "**[链接](https://x.com)**"
        let tokens = engine.prepare(source).tokens
        #expect(tokens.contains { $0.kind == .strong })
        #expect(tokens.contains { $0.kind == .link })
    }

    @Test func unclosedLinkProducesNoToken() {
        #expect(engine.prepare("[x](y").tokens.allSatisfy { $0.kind != .link })
    }

    @Test func imageIsNotLinkified() {
        // 图片语法（M5 处理）不得被识别为链接
        let tokens = engine.prepare("![alt](img.png)").tokens
        #expect(tokens.allSatisfy { $0.kind != .link })
    }

    @Test func referenceLinkWithoutParensIsNotTokenized() {
        let source = "[文字][ref]\n\n[ref]: http://x.com"
        let tokens = engine.prepare(source).tokens
        #expect(tokens.allSatisfy { $0.kind != .link })
    }

    @Test func starInsideDestinationDoesNotPairOut() {
        // URL 里的 * 不得与标签前的 * 配对（保护区间）
        let source = "*a* and [b](https://x/y*z)"
        let tokens = engine.prepare(source).tokens
        let emphasis = tokens.filter { $0.kind == .emphasis }
        #expect(emphasis.count == 1)
        #expect(emphasis[0].contentRange == 1..<2) // 只有 "a"
    }

    // MARK: - scanner ↔ AST 行级块分类（差异测试）

    @Test func blockClassificationMatchesAST() throws {
        let source = """
        # 一级标题

        段落 with **粗体** and [link](https://x.com)

        - 列表项一
        - 列表项二

        > 引用第一行

        ```swift
        func f() -> Int { 1 }
        ```

        ## 二级标题
        段落收尾
        """
        let scanner = TokenScanner()
        let lines = scanner.lines(source)
        let scanned = scanner.scan(source,
            excludingRanges: engine.prepare(source).tokens
                .filter { $0.kind == .link }.flatMap { $0.allMarkerRanges })

        func lineIndex(ofByte offset: Int) -> Int {
            var lo = 0
            var hi = lines.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lines[mid].start <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }

        // 扫描器侧行级覆盖
        var fenceLineSet = Set<Int>()
        var headingLines: [Int: Int] = [:]
        var quoteLineSet = Set<Int>()
        var listLineSet = Set<Int>()
        for token in scanned {
            switch token.kind {
            case .codeFence:
                let upper = token.contentRange?.upperBound ?? token.markerRange.upperBound
                let endLine = lineIndex(ofByte: max(upper, token.markerRange.lowerBound))
                for l in token.line...endLine { fenceLineSet.insert(l) }
            case .heading(let level):
                headingLines[token.line] = level
            case .blockquote:
                quoteLineSet.insert(token.line)
            case .unorderedListItem, .orderedListItem, .taskListItem:
                listLineSet.insert(token.line)
            default:
                break
            }
        }

        let semantics = MarkdownSemantics(source)
        let semanticsByLine = Dictionary(uniqueKeysWithValues: semantics.lineKinds.map { ($0.line, $0.kind) })
        // AST 的 list 范围含尾随空行；空行不要求扫描器覆盖
        let blankLines = Set(lines.enumerated().filter { $0.element.start == $0.element.end }.map(\.offset))

        for (line, semanticKind) in semanticsByLine {
            switch semanticKind {
            case .heading(let level):
                // 语义的标题行（ATX 只占一行）应与扫描器一致
                #expect(headingLines[line] == level)
            case .quote:
                #expect(quoteLineSet.contains(line))
            case .fence:
                #expect(fenceLineSet.contains(line))
            case .list:
                // 扫描器只标记有 marker 的行；AST 的 list 范围含续行（懒式延续）与尾随空行
                #expect(listLineSet.contains(line) || blankLines.contains(line))
            }
        }
    }

    @Test func ASTProvidesDeepNestedListStructureToScanner() throws {
        let source = "- parent\n    - child\n"
        let semantics = MarkdownSemantics(source)
        #expect(semantics.listItemLines.contains(0))
        #expect(semantics.listItemLines.contains(1))

        let nested = try #require(RenderEngine().prepare(source).tokens.first { token in
            token.line == 1 && token.kind == .unorderedListItem
        })
        #expect(nested.markerRange.lowerBound == 13) // "- parent\n" + 4 个缩进空格
    }
}
