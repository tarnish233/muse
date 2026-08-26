import Foundation
import Testing

/// M0 版扫描器的行为契约：字节区间的精确性由这些测试固化。
@Suite struct TokenScannerTests {
    let scanner = TokenScanner()

    @Test func atxHeading() {
        let tokens = scanner.scan("# 标题")
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .heading(level: 1))
        #expect(tokens[0].markerRange == 0..<2)
        #expect(tokens[0].contentRange == 2..<8) // "标题" 6 字节
        #expect(tokens[0].line == 0)
    }

    @Test func headingRequiresSpace() {
        #expect(scanner.scan("###no-space").isEmpty)
    }

    @Test func headingLevels() {
        #expect(scanner.scan("###### 六级").first?.kind == .heading(level: 6))
        // CommonMark：7 个 # 不是 ATX 标题（开栏序列最多 6 个），按段落处理
        #expect(scanner.scan("####### 七个").isEmpty)
    }

    @Test func unorderedList() {
        let tokens = scanner.scan("- 第一项")
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .unorderedListItem)
        #expect(tokens[0].markerRange == 0..<2)
        #expect(tokens[0].contentRange == 2..<11) // "第一项" 9 字节
    }

    @Test func taskList() {
        let done = scanner.scan("- [x] 完成")
        #expect(done.first?.kind == .taskListItem(checked: true))
        #expect(done.first?.markerRange == 0..<6)

        let todo = scanner.scan("- [ ] 待办")
        #expect(todo.first?.kind == .taskListItem(checked: false))

        // 大写的 X 也算完成
        let upper = scanner.scan("- [X] 大写")
        #expect(upper.first?.kind == .taskListItem(checked: true))

        // "- [ ]" 后无空格则不识别为任务
        #expect(scanner.scan("- [ ]未闭合").allSatisfy { !($0.kind == .taskListItem(checked: false)) })
    }

    @Test func orderedList() {
        let tokens = scanner.scan("12. 第十二项")
        #expect(tokens.first?.kind == .orderedListItem)
        #expect(tokens.first?.markerRange == 0..<4) // "12. "
    }

    @Test func blockquote() {
        let tokens = scanner.scan("> 引用内容")
        #expect(tokens.first?.kind == .blockquote)
        #expect(tokens.first?.markerRange == 0..<2)
        #expect(tokens.first?.contentRange == 2..<14) // "引用内容" 12 字节
    }

    @Test func strongWithChinese() {
        let tokens = scanner.scan("**粗**")
        #expect(tokens.count == 1)
        let token = tokens[0]
        #expect(token.kind == .strong)
        #expect(token.markerRange == 0..<2)
        #expect(token.contentRange == 2..<5)   // "粗" 3 字节
        #expect(token.closingMarkerRange == 5..<7)
    }

    @Test func emphasisAndStrikethrough() {
        let em = scanner.scan("*斜*")
        #expect(em.first?.kind == .emphasis)
        #expect(em.first?.markerRange == 0..<1)
        #expect(em.first?.closingMarkerRange == 4..<5) // "斜" 3 字节

        let strike = scanner.scan("~~删~~")
        #expect(strike.first?.kind == .strikethrough)
        #expect(strike.first?.markerRange == 0..<2)
        #expect(strike.first?.closingMarkerRange == 5..<7)
    }

    @Test func inlineCode() {
        let tokens = scanner.scan("`code`")
        #expect(tokens.first?.kind == .inlineCode)
        #expect(tokens.first?.contentRange == 1..<5)
        #expect(tokens.first?.closingMarkerRange == 5..<6)
    }

    @Test func nestedEmphasis() {
        // **a *b* c** → 外层 strong + 内层 emphasis（扫描器递归进入内容）
        let tokens = scanner.scan("**a *b* c**")
        #expect(tokens.contains { $0.kind == .strong })
        #expect(tokens.contains { $0.kind == .emphasis })
        let em = tokens.first { $0.kind == .emphasis }
        #expect(em?.contentRange == 5..<6)
    }

    @Test func unclosedSyntaxYieldsNoToken() {
        #expect(scanner.scan("**未闭合").isEmpty)
        #expect(scanner.scan("`未闭合").isEmpty)
        #expect(scanner.scan("*未闭合").isEmpty)
    }

    @Test func escapesSkipMarker() {
        // \*不是强调\* → 反斜杠吃掉下一个字符，不应产生 emphasis
        #expect(scanner.scan("\\*不是强调\\*").isEmpty)
    }

    @Test func codeFenceBlock() {
        let source = "```swift\nlet a = 1\n```\n正文"
        let tokens = scanner.scan(source)
        let fence = tokens.first { $0.kind == .codeFence }
        #expect(fence != nil)
        #expect(fence?.markerRange == 0..<3) // 只含反引号 run，"swift" 属于围栏行的可读后缀
        // 内容 = 开栏行整行之后 到 闭合行起点
        let bodyStart = 8 + 1 // "```swift\n"
        let closeStart = bodyStart + "let a = 1\n".count
        #expect(fence?.contentRange == bodyStart..<closeStart)
    }

    @Test func unclosedFenceExtendsToEnd() {
        let source = "```\n内容\n没有闭合"
        let fence = scanner.scan(source).first { $0.kind == .codeFence }
        #expect(fence?.contentRange?.upperBound == source.utf8.count)
    }

    @Test func crlfLines() {
        let tokens = scanner.scan("- 甲\r\n- 乙")
        #expect(tokens.count == 2)
        #expect(tokens[0].line == 0)
        #expect(tokens[1].line == 1)
        #expect(tokens[0].markerRange == 0..<2)
        #expect(tokens[1].markerRange == 7..<9) // "\r\n" 占 2 字节
    }

    @Test func emojiInLineDoesNotShiftMarkers() {
        // 字节偏移不会因 emoji 偏移：😀 前有 "图"（3 字节）
        // CJK/符号按"标点类"参与 flanking（有意偏离 CommonMark 词内限制，见 TokenScanner 注释）
        let tokens = scanner.scan("图😀**粗**")
        let strong = tokens.first { $0.kind == .strong }
        #expect(strong?.markerRange == 7..<9) // 3 + 4 = 7
        #expect(strong?.contentRange == 9..<12)
    }

    // MARK: - 块级内容中的行内语法（审查 P1）

    @Test func inlineInsideHeading() {
        let tokens = scanner.scan("# 标题 **加粗**")
        #expect(tokens.contains { $0.kind == .heading(level: 1) })
        let strong = tokens.first { $0.kind == .strong }
        #expect(strong?.markerRange == 9..<11)
        #expect(strong?.contentRange == 11..<17)
        #expect(strong?.closingMarkerRange == 17..<19)
    }

    @Test func inlineInsideList() {
        let tokens = scanner.scan("- **粗体**")
        #expect(tokens.contains { $0.kind == .unorderedListItem })
        let strong = tokens.first { $0.kind == .strong }
        #expect(strong?.markerRange == 2..<4)
        #expect(strong?.contentRange == 4..<10)
    }

    @Test func inlineInsideTaskAndQuote() {
        let task = scanner.scan("- [x] `完成`")
        #expect(task.contains { $0.kind == .taskListItem(checked: true) })
        #expect(task.contains { $0.kind == .inlineCode })

        let quote = scanner.scan("> *引*")
        #expect(quote.contains { $0.kind == .blockquote })
        let em = quote.first { $0.kind == .emphasis }
        #expect(em?.contentRange == 3..<6)
        #expect(em?.closingMarkerRange == 6..<7)
    }

    // MARK: - 转义闭合符（审查 P2）

    @Test func escapedClosingDelimiter() {
        // *a\*b*：被转义的中间 * 不能当作闭合符
        let tokens = scanner.scan("*a\\*b*")
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .emphasis)
        #expect(tokens[0].contentRange == 1..<5)
        #expect(tokens[0].closingMarkerRange == 5..<6)
    }

    @Test func strongWithEscapedClose() {
        let tokens = scanner.scan("**a\\*b**")
        let strong = tokens.first { $0.kind == .strong }
        #expect(strong?.markerRange == 0..<2)
        #expect(strong?.contentRange == 2..<6)
        #expect(strong?.closingMarkerRange == 6..<8)
    }

    @Test func strongInsideEmphasisParses() {
        // M2 起（分隔符 run 算法）：*a **b** c* 应解析为"斜体包粗体"
        let tokens = scanner.scan("*a **b** c*")
        let emphasis = tokens.first { $0.kind == .emphasis }
        let strong = tokens.first { $0.kind == .strong }
        #expect(emphasis != nil)
        #expect(strong != nil)
        #expect(emphasis?.markerRange == 0..<1)
        #expect(emphasis?.contentRange == 1..<10)
        #expect(emphasis?.closingMarkerRange == 10..<11)
        #expect(strong?.markerRange == 3..<5)
        #expect(strong?.contentRange == 5..<6)
        #expect(strong?.closingMarkerRange == 6..<8)
    }

    @Test func tripleStarParsesAsEmphasisAroundStrong() {
        // ***foo*** → <em><strong>foo</strong></em>，开符从 run 尾消耗、闭符从 run 头消耗
        let tokens = scanner.scan("***foo***")
        let strong = tokens.first { $0.kind == .strong }
        let emphasis = tokens.first { $0.kind == .emphasis }
        #expect(strong != nil)
        #expect(emphasis != nil)
        #expect(strong?.markerRange == 1..<3)
        #expect(strong?.closingMarkerRange == 6..<8)
        #expect(emphasis?.markerRange == 0..<1)
        #expect(emphasis?.contentRange == 1..<8)
        #expect(emphasis?.closingMarkerRange == 8..<9)
    }

    @Test func singleStarThenDoubleClose() {
        // *foo** → <em>foo</em>*（CommonMark：闭 run 长度不同时按 1 消耗，剩余字面量）
        let tokens = scanner.scan("*foo**")
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .emphasis)
        #expect(tokens[0].contentRange == 1..<4)
        #expect(tokens[0].closingMarkerRange == 4..<5)
    }

    @Test func strongInsideCodeSpanIsLiteral() {
        // 代码保护区间内的星号不做强调
        let tokens = scanner.scan("`a*b` 与 **粗**")
        #expect(tokens.allSatisfy { $0.kind != .emphasis })
        #expect(tokens.contains { $0.kind == .inlineCode })
        #expect(tokens.contains { $0.kind == .strong })
    }

    @Test func thematicBreak() {
        #expect(scanner.scan("---").first?.kind == .rule)
        #expect(scanner.scan("- - -").first?.kind == .rule)
        #expect(scanner.scan("***").first?.kind == .rule)
        #expect(scanner.scan("___").first?.kind == .rule)
        // 不足三个 / 是列表 / 后有文字 → 不是分隔线
        #expect(scanner.scan("--").isEmpty)
        #expect(scanner.scan("- 项").first?.kind == .unorderedListItem)
        #expect(!scanner.scan("--- 后文").contains { $0.kind == .rule })
    }
}
