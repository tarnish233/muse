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

    @Test func linkDestinationExcludesOptionalTitles() throws {
        let cases = [
            ("[x](target.md \"caption\")", "target.md"),
            ("[x](target.md 'caption')", "target.md"),
            ("[x](target.md (caption))", "target.md"),
            ("[x](foo(bar).md \"caption\")", "foo(bar).md"),
            ("[x](<path with spaces> \"caption\")", "path with spaces"),
        ]

        for (source, expected) in cases {
            let token = try #require(engine.prepare(source).tokens.first { $0.kind == .link })
            let range = try #require(token.linkDestination)
            let destination = String(decoding: Array(source.utf8)[range], as: UTF8.self)
            #expect(destination == expected)
            #expect(token.closingMarkerRange?.upperBound == source.utf8.count)
        }
    }

    @Test func imageDestinationExcludesOptionalTitle() throws {
        let source = "![x](photo.png \"caption\")"
        let token = try #require(engine.prepare(source).tokens.first { $0.kind == .image })
        let range = try #require(token.linkDestination)
        let destination = String(decoding: Array(source.utf8)[range], as: UTF8.self)

        #expect(destination == "photo.png")
        #expect(token.closingMarkerRange?.upperBound == source.utf8.count)
    }

    // MARK: - 图片（M5）

    @Test func imageBounds() throws {
        let source = "![截图](assets/pic.png)" // 25 UTF-8 字节：! [ 截 图 ] ( 14 字符路径 )
        let tokens = engine.prepare(source).tokens
        let image = try #require(tokens.first { $0.kind == .image })
        #expect(image.markerRange == 0..<2)            // ![
        #expect(image.contentRange == 2..<8)           // 截图（CJK 各 3 字节）
        #expect(image.closingMarkerRange == 8..<25)    // ]( 到 )
        #expect(image.linkDestination == 10..<24)      // assets/pic.png
        // 独占一行：整段折叠，图由绘制层画在撑高的行里。
        #expect(image.isBlockImage)
        #expect(image.markerVisibilityRanges == [0..<25])
    }

    /// 夹在正文中间的图片不是块图片：整段源码都保留（只被弱化成 marker 色）。
    /// 折叠一半会留下 `![标签` 这种看起来像打错字的残句，而图并没有画出来。
    @Test func inlineImageKeepsWholeSyntaxVisible() throws {
        let source = "看这张 ![截图](a.png) 很清楚"
        let tokens = engine.prepare(source).tokens
        let image = try #require(tokens.first { $0.kind == .image })
        #expect(image.isBlockImage == false)
        #expect(image.inlineImageRange == nil)
        #expect(image.markerVisibilityRanges.isEmpty)
    }

    /// 两侧只有空白仍算独占一行。
    @Test func blockImageToleratesSurroundingWhitespace() throws {
        let source = "文字\n\n  ![截图](a.png)  \n\n更多"
        let image = try #require(engine.prepare(source).tokens.first { $0.kind == .image })
        #expect(image.isBlockImage)
    }

    // MARK: - GFM 表格几何

    /// 单元格墨迹与结构区（`|` + 填充空白）的还原。列宽度量只能用墨迹，
    /// 填充空白在渲染态会被折叠。
    @Test func tableCellInkAndStructuralRanges() throws {
        //                       0         1         2
        //                       0123456789012345678901
        let source = "| ab | c |\n|---|---|\n| d | e |"
        let tables = engine.prepare(source).tables
        let table = try #require(tables.first)
        #expect(table.headerLine == 0)
        #expect(table.delimiterLine == 1)
        #expect(table.lastLine == 2)
        #expect(table.columnCount == 2)

        let header = try #require(table.rows.first)
        #expect(header.line == 0)
        #expect(header.cells.count == 2)
        // `| ab | c |`：首格内容 " ab "（含两侧空格），墨迹只有 "ab"。
        #expect(header.cells[0].content == 1..<5)
        #expect(header.cells[0].ink == 2..<4)
        // 首格墨迹之前的结构区 = 行首的 `|` + 一个空格。
        #expect(header.cells[0].leadingGap == 0..<2)
        #expect(header.cells[0].trailingPipe == 5..<6)
        // 次格墨迹之前的结构区 = 上一格尾部空格 + `|` + 本格头部空格。
        #expect(header.cells[1].ink == 7..<8)
        #expect(header.cells[1].leadingGap == 4..<7)
        #expect(header.trailingGap == 8..<10)
    }

    /// 列对齐直接取 AST 的 `columnAlignments`，不重新解析 `:---:`。
    @Test func tableColumnAlignments() throws {
        let source = "| a | b | c | d |\n|---|:---|:---:|---:|\n| 1 | 2 | 3 | 4 |"
        let table = try #require(engine.prepare(source).tables.first)
        #expect(table.alignment(column: 0) == .leading)
        #expect(table.alignment(column: 1) == .leading)
        #expect(table.alignment(column: 2) == .center)
        #expect(table.alignment(column: 3) == .trailing)
    }

    /// 表格 token 把行内结构区一并带上，显隐层因此能把 `|` 与填充空白折叠掉。
    @Test func tableTokenCarriesStructuralMarkers() throws {
        let source = "| ab | c |\n|---|---|\n| d | e |"
        let package = engine.prepare(source)
        let table = try #require(package.tokens.first { if case .table = $0.kind { return true } else { return false } })
        let structural = try #require(package.tables.first).structuralRanges
        #expect(!structural.isEmpty)
        #expect(table.extraMarkerRanges == structural)
        // marker 本体仍是分隔行整行。
        #expect(table.markerRange == 11..<20)
        for range in structural {
            #expect(table.allMarkerRanges.contains(range))
        }
    }

    @Test func imageInsideLinkProducesBothTokens() {
        let source = "[![alt](a.png)](https://x.com)"
        let tokens = engine.prepare(source).tokens
        #expect(tokens.contains { $0.kind == .image })
        #expect(tokens.contains { $0.kind == .link })
    }

    // MARK: - 表格（M5 只读呈现）

    @Test func tableTokenSpansAllRowsWithDelimiterMarker() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        let tokens = engine.prepare(source).tokens
        let table = try #require(tokens.first {
            if case .table = $0.kind { return true }
            return false
        })
        #expect(table.line == 0)                       // 表头行
        #expect(table.markerRange == 10..<19)          // 分隔行整行 |---|---|
        guard case let .table(lastLine) = table.kind else {
            Issue.record("unexpected kind")
            return
        }
        #expect(lastLine == 3)
        // 管道表格行内的粗体照常得到行内标记
        let boldSource = "| x | y |\n|---|---|\n| **z** | w |"
        #expect(engine.prepare(boldSource).tokens.contains { $0.kind == .strong })
    }

    @Test func fenceBodyPipeRowsDoNotBecomeTable() {
        let source = "```\n| a | b |\n|---|---|\n```"
        let tokens = engine.prepare(source).tokens
        #expect(tokens.contains { $0.kind == .codeFence })
        #expect(!tokens.contains {
            if case .table = $0.kind { return true }
            return false
        })
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
            guard token.line == 1 else { return false }
            guard case let .unorderedListItem(depth) = token.kind else { return false }
            return depth == 2
        })
        #expect(nested.markerRange.lowerBound == 13) // "- parent\n" + 4 个缩进空格
    }

    // MARK: - M2-2：Token 携带 AST 层级与序号

    @Test func listTokensCarryDepth() throws {
        let source = "- 一层\n  - 二层\n    - 三层\n"
        let depths = RenderEngine().prepare(source).tokens.compactMap { token -> Int? in
            guard case let .unorderedListItem(depth) = token.kind else { return nil }
            return depth
        }
        #expect(depths == [1, 2, 3])
    }

    @Test func orderedListTokensCarryNumber() throws {
        let engine = RenderEngine()
        let numbers = engine.prepare("3. 三\n4. 四\n").tokens.compactMap { token -> Int? in
            guard case let .orderedListItem(_, number) = token.kind else { return nil }
            return number
        }
        let resetNumbers = engine.prepare("1. 一\n2. 二\n").tokens.compactMap { token -> Int? in
            guard case let .orderedListItem(_, number) = token.kind else { return nil }
            return number
        }
        #expect(numbers == [3, 4])
        #expect(resetNumbers == [1, 2])
    }

    // MARK: - M2-1：AST marker 与块结构输出

    @Test func inlineMarkersMatchByteBoundaries() throws {
        let source = "**粗体**、*斜体*、~~删除线~~、`行内代码`"
        let semantics = MarkdownSemantics(source)

        let strong = try #require(semantics.inlineMarkers.first { $0.kind == .strong })
        #expect(strong.openMarker == 0..<2)
        #expect(strong.content == 2..<8)
        #expect(strong.closeMarker == 8..<10)

        let emphasis = try #require(semantics.inlineMarkers.first { $0.kind == .emphasis })
        #expect(emphasis.openMarker == 13..<14)
        #expect(emphasis.content == 14..<20)
        #expect(emphasis.closeMarker == 20..<21)

        let strike = try #require(semantics.inlineMarkers.first { $0.kind == .strikethrough })
        #expect(strike.openMarker == 24..<26)
        #expect(strike.content == 26..<35)
        #expect(strike.closeMarker == 35..<37)

        let code = try #require(semantics.inlineMarkers.first { $0.kind == .inlineCode })
        #expect(code.openMarker == 40..<41)
        #expect(code.content == 41..<53)
        #expect(code.closeMarker == 53..<54)
    }

    @Test func nestedEmphasisMarkersFromAST() throws {
        let source = "**粗体里的 *斜体* 与 `代码`**"
        let semantics = MarkdownSemantics(source)

        let outer = try #require(semantics.inlineMarkers.first {
            $0.kind == .strong && $0.openMarker == 0..<2
        })
        #expect(outer.content == 2..<36)
        #expect(outer.closeMarker == 36..<38)

        let nestedEmphasis = try #require(semantics.inlineMarkers.first {
            $0.kind == .emphasis && $0.openMarker == 15..<16
        })
        #expect(nestedEmphasis.content == 16..<22)
        #expect(nestedEmphasis.closeMarker == 22..<23)

        let nestedCode = try #require(semantics.inlineMarkers.first {
            $0.kind == .inlineCode && $0.openMarker == 28..<29
        })
        #expect(nestedCode.content == 29..<35)
        #expect(nestedCode.closeMarker == 35..<36)

        let triple = MarkdownSemantics("***三层星号***").inlineMarkers
        #expect(triple.contains {
            $0.kind == .emphasis && $0.openMarker == 0..<1 && $0.closeMarker == 17..<18
        })
        #expect(triple.contains {
            $0.kind == .strong && $0.openMarker == 1..<3 && $0.closeMarker == 15..<17
        })
    }

    @Test func reverseNestedEmphasisFromAST() throws {
        let semantics = MarkdownSemantics("*a **b** c*")
        let outer = try #require(semantics.inlineMarkers.first { $0.kind == .emphasis })
        let inner = try #require(semantics.inlineMarkers.first { $0.kind == .strong })

        #expect(outer.openMarker == 0..<1)
        #expect(outer.content == 1..<10)
        #expect(outer.closeMarker == 10..<11)
        #expect(inner.openMarker == 3..<5)
        #expect(inner.content == 5..<6)
        #expect(inner.closeMarker == 6..<8)
    }

    @Test func unclosedEmphasisProducesNoMarker() {
        let semantics = MarkdownSemantics("**未闭合")
        #expect(semantics.inlineMarkers.isEmpty)
    }

    @Test func listDepthAndNumberFromAST() throws {
        let source = "- 一层\n  - 二层\n    - 三层\n\n3. 三\n4. 四\n"
        let blocks = MarkdownSemantics(source).blocks

        let unorderedDepths = blocks.compactMap { block -> Int? in
            guard case let .unorderedList(depth) = block.kind else { return nil }
            return depth
        }
        #expect(unorderedDepths == [1, 2, 3])

        let ordered = blocks.compactMap { block -> (depth: Int, number: Int)? in
            guard case let .orderedList(depth, number) = block.kind else { return nil }
            return (depth, number)
        }
        #expect(ordered.map(\.depth) == [1, 1])
        #expect(ordered.map(\.number) == [3, 4])
    }

    @Test func taskCheckboxFromAST() throws {
        let blocks = MarkdownSemantics("- [x] 完成\n- [ ] 待办\n").blocks
        let tasks = blocks.compactMap { block -> Bool? in
            guard case let .taskList(_, checked) = block.kind else { return nil }
            return checked
        }
        #expect(tasks == [true, false])
    }

    @Test func codeFenceLanguageFromAST() throws {
        let blocks = MarkdownSemantics("```swift\nlet value = 1\n```\n").blocks
        #expect(blocks.contains { block in
            guard case let .codeFence(language) = block.kind else { return false }
            return language == "swift"
        })
    }

    @Test func nestedListWithoutLinksStillUsesAST() throws {
        let source = "- root\n  - child\n"
        #expect(!source.contains("["))
        let blocks = MarkdownSemantics(source).blocks
        #expect(blocks.contains { block in
            guard case .unorderedList(depth: 2) = block.kind else { return false }
            return block.line == 1
        })
    }
}
