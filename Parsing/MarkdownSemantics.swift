import Foundation
import Markdown

/// swift-markdown 语义层（v0.2 §4.1）：AST 同时回答"这段内容是什么"与
/// "精确的标记字符在哪"。在后台解析任务中构建，只提取 Sendable 的纯值信息；
/// 本层不触碰 AppKit/存储。
public nonisolated struct MarkdownSemantics: Sendable {
    /// AST 推导出的行内标记。marker 由节点自身与首/末子节点的源码区间相减得到。
    public struct InlineMarker: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case strong
            case emphasis
            case inlineCode
            case strikethrough
        }

        public let kind: Kind
        public let openMarker: Range<Int>
        public let closeMarker: Range<Int>
        public let content: Range<Int>
        public let line: Int

        public init(
            kind: Kind,
            openMarker: Range<Int>,
            closeMarker: Range<Int>,
            content: Range<Int>,
            line: Int
        ) {
            self.kind = kind
            self.openMarker = openMarker
            self.closeMarker = closeMarker
            self.content = content
            self.line = line
        }
    }

    /// AST 推导出的块级结构。所有范围均为 UTF-8 字节偏移。
    public struct BlockStructure: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case heading(level: Int)
            case unorderedList(depth: Int)
            case orderedList(depth: Int, number: Int)
            case taskList(depth: Int, checked: Bool)
            case blockquote(depth: Int)
            case codeFence(language: String?)
            /// GFM 表格：line 为表头行，lastLine 为末行；分隔行恒为 line+1。
            case table(lastLine: Int)
            case rule
        }

        public let kind: Kind
        public let line: Int
        /// 语法 marker 到内容起点的区间（不含列表/块的前导缩进）。
        public let marker: Range<Int>
        /// 块正文区间；围栏块为开栏行之后至闭栏行之前。
        public let content: Range<Int>?
        /// 围栏块的闭栏 marker；其他块为 nil。
        public let closingMarker: Range<Int>?

        public init(
            kind: Kind,
            line: Int,
            marker: Range<Int>,
            content: Range<Int>? = nil,
            closingMarker: Range<Int>? = nil
        ) {
            self.kind = kind
            self.line = line
            self.marker = marker
            self.content = content
            self.closingMarker = closingMarker
        }
    }

    /// 行级块分类（0-based 行号），供差异测试与后续增量渲染使用。
    public struct LineKind: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case heading(Int)  // ATX 级别
            case quote
            case list
            case fence        // 围栏体内（含开/闭栏行）
        }

        public let line: Int
        public let kind: Kind

        public init(line: Int, kind: Kind) {
            self.line = line
            self.kind = kind
        }
    }

    /// 行内链接语法定位（均为 UTF-8 字节偏移）。
    public struct LinkSyntax: Sendable, Equatable {
        /// `[`（单字节）
        public let openBracket: Range<Int>
        /// 标签内容
        public let label: Range<Int>
        /// `]` 到 `)` 的整段（标记隐藏时连同目的地一起隐藏）
        public let tail: Range<Int>
        /// 目的地（tail 内部）
        public let destination: Range<Int>
        /// 所属行（0-based）。
        public let line: Int
        /// 行内扫描的保护区间（tail）——强调分隔符不进入 URL 区域配对
        public var inertRanges: [Range<Int>] { [tail] }

        public init(
            openBracket: Range<Int>,
            label: Range<Int>,
            tail: Range<Int>,
            destination: Range<Int>,
            line: Int = 0
        ) {
            self.openBracket = openBracket
            self.label = label
            self.tail = tail
            self.destination = destination
            self.line = line
        }
    }

    /// swift-markdown 数学 AST 节点的纯值快照。
    ///
    /// 语义判断完全由 `.parseMath` 产生的节点负责；这里只把节点范围拆成编辑器需要的
    /// 开/闭标记与正文范围，不自行识别 `$` 语法。
    public struct MathSyntax: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case inline
            case block(lastLine: Int)
        }

        public let kind: Kind
        public let expression: String
        public let openMarker: Range<Int>
        public let closeMarker: Range<Int>
        public let content: Range<Int>
        public let line: Int

        public init(
            kind: Kind,
            expression: String,
            openMarker: Range<Int>,
            closeMarker: Range<Int>,
            content: Range<Int>,
            line: Int
        ) {
            self.kind = kind
            self.expression = expression
            self.openMarker = openMarker
            self.closeMarker = closeMarker
            self.content = content
            self.line = line
        }
    }

    public let lineKinds: [LineKind]
    public let links: [LinkSyntax]
    public let images: [LinkSyntax]
    public let inlineMarkers: [InlineMarker]
    public let math: [MathSyntax]
    public let blocks: [BlockStructure]
    /// GFM 表格的源码几何（单元格与 `|` 区间、列对齐），供渲染层算列宽。
    public let tables: [TableStructure]
    /// 「块图片」所在的行：整行只有一个 `![标签](目的地)`（两侧仅空白）。
    ///
    /// 独占一行是完整的判据，所以行号本身就是这个谓词——一行里若还有别的文字，
    /// 这一行就不在集合里。渲染层据此把整行折叠成图片保留区，显隐层据此决定
    /// 是整段折叠还是只折叠语法标记。
    public let blockImageLines: Set<Int>
    /// AST 判定出的结构行，供 TokenScanner 在需要时扩大缩进识别范围。
    ///
    /// 例如 CommonMark 允许列表嵌套在 4 个以上空格之后；扫描器本身不复制块解析规则，
    /// 只在 AST 已确认该行属于对应结构时消费这些行级提示。
    public let listItemLines: Set<Int>
    public let quoteLines: Set<Int>
    public let fenceLines: Set<Int>

    /// 把 AST 已确认的 marker/结构转换成渲染 token。
    ///
    /// 这是唯一的转换层；TokenScanner 的 `scan` 仅为旧调用方保留同一结果的
    /// 兼容入口，不再另行实现 Markdown 匹配规则。
    public var tokens: [Token] {
        // A table block needs its structural marker ranges. Looking it up with `first(where:)`
        // for every block makes token construction quadratic in table-heavy documents.
        let tablesByHeaderLine = Dictionary(uniqueKeysWithValues: tables.map {
            ($0.headerLine, $0)
        })
        var result = blocks.map { block -> Token in
            switch block.kind {
            case let .heading(level):
                return Token(kind: .heading(level: level), markerRange: block.marker,
                             contentRange: block.content, line: block.line)
            case let .unorderedList(depth):
                return Token(kind: .unorderedListItem(depth: depth), markerRange: block.marker,
                             contentRange: block.content, line: block.line)
            case let .orderedList(depth, number):
                return Token(kind: .orderedListItem(depth: depth, number: number),
                             markerRange: block.marker, contentRange: block.content, line: block.line)
            case let .taskList(depth, checked):
                return Token(kind: .taskListItem(depth: depth, checked: checked),
                             markerRange: block.marker, contentRange: block.content, line: block.line)
            case let .blockquote(depth):
                return Token(kind: .blockquote(depth: depth), markerRange: block.marker,
                             contentRange: block.content, line: block.line)
            case let .table(lastLine):
                // 表格的「marker」是分隔行整行：随光标显隐（块级）。行内的结构区
                // （`|` 与单元格填充空白）作为附加 marker 一并显隐——隐藏态由绘制层
                // 画真实表格线，回显态露出源码。
                let structural = tablesByHeaderLine[block.line]?.structuralRanges ?? []
                return Token(kind: .table(lastLine: lastLine), markerRange: block.marker,
                             contentRange: block.content, extraMarkerRanges: structural,
                             line: block.line)
            case .codeFence:
                return Token(kind: .codeFence, markerRange: block.marker,
                             closingMarkerRange: block.closingMarker, contentRange: block.content,
                             line: block.line)
            case .rule:
                return Token(kind: .rule, markerRange: block.marker, line: block.line)
            }
        }
        result.append(contentsOf: inlineMarkers.map { marker in
            let kind: Token.Kind
            switch marker.kind {
            case .strong: kind = .strong
            case .emphasis: kind = .emphasis
            case .inlineCode: kind = .inlineCode
            case .strikethrough: kind = .strikethrough
            }
            return Token(kind: kind, markerRange: marker.openMarker,
                         closingMarkerRange: marker.closeMarker, contentRange: marker.content,
                         line: marker.line)
        })
        result.append(contentsOf: math.map { syntax in
            let kind: Token.Kind
            switch syntax.kind {
            case .inline:
                kind = .inlineMath
            case let .block(lastLine):
                kind = .blockMath(lastLine: lastLine)
            }
            return Token(
                kind: kind,
                markerRange: syntax.openMarker,
                closingMarkerRange: syntax.closeMarker,
                contentRange: syntax.content,
                mathExpression: syntax.expression,
                line: syntax.line
            )
        })
        result.append(contentsOf: links.map { link in
            Token(kind: .link, markerRange: link.openBracket, closingMarkerRange: link.tail,
                  contentRange: link.label, linkDestination: link.destination, line: link.line)
        })
        result.append(contentsOf: images.map { image in
            Token(kind: .image, markerRange: image.openBracket, closingMarkerRange: image.tail,
                  contentRange: image.label, linkDestination: image.destination,
                  isBlockImage: blockImageLines.contains(image.line), line: image.line)
        })
        return result.sorted { lhs, rhs in
            if lhs.markerRange.lowerBound != rhs.markerRange.lowerBound {
                return lhs.markerRange.lowerBound < rhs.markerRange.lowerBound
            }
            return lhs.markerRange.upperBound > rhs.markerRange.upperBound
        }
    }

    public init(_ source: String) {
        let bytes = Array(source.utf8)
        self.init(source, bytes: bytes, lines: TokenScanner().lines(bytes))
    }

    init(_ source: String, lines sourceLines: [TokenScanner.Line]) {
        self.init(source, bytes: Array(source.utf8), lines: sourceLines)
    }

    init(_ source: String, bytes: [UInt8], lines sourceLines: [TokenScanner.Line]) {
        let lineStarts = sourceLines.map(\.start)
        let document = Document(parsing: source, options: [.disableSmartOpts])

        var semanticWalker = SemanticWalker(bytes: bytes, lineStarts: lineStarts, lines: sourceLines)
        semanticWalker.visit(document)
        var mathWalker = MathSyntaxWalker(bytes: bytes, lineStarts: lineStarts, lines: sourceLines)
        mathWalker.visit(document)

        var lineKinds: [LineKind] = []
        for block in document.blockChildren {
            guard let range = block.range else { continue }
            let startLine = range.lowerBound.line - 1
            let endLine = range.upperBound.line - 1
            guard startLine >= 0, endLine >= startLine else { continue }

            let kind: LineKind.Kind
            if let heading = block as? Heading {
                kind = .heading(heading.level)
            } else if block is BlockQuote {
                kind = .quote
            } else if block is UnorderedList || block is OrderedList {
                kind = .list
            } else if block is CodeBlock {
                kind = .fence
            } else {
                continue
            }
            for line in startLine...endLine {
                lineKinds.append(LineKind(line: line, kind: kind))
            }
        }
        self.lineKinds = lineKinds
        self.links = semanticWalker.links
        self.images = semanticWalker.images
        self.inlineMarkers = semanticWalker.inlineMarkers.sorted {
            if $0.openMarker.lowerBound != $1.openMarker.lowerBound {
                return $0.openMarker.lowerBound < $1.openMarker.lowerBound
            }
            return $0.openMarker.upperBound > $1.openMarker.upperBound
        }
        self.math = mathWalker.math.sorted {
            if $0.openMarker.lowerBound != $1.openMarker.lowerBound {
                return $0.openMarker.lowerBound < $1.openMarker.lowerBound
            }
            return $0.openMarker.upperBound > $1.openMarker.upperBound
        }
        self.blocks = semanticWalker.blocks.sorted {
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.marker.lowerBound < $1.marker.lowerBound
        }
        self.tables = semanticWalker.tables.sorted { $0.headerLine < $1.headerLine }
        self.blockImageLines = semanticWalker.blockImageLines
        self.listItemLines = semanticWalker.listItemLines
        self.quoteLines = semanticWalker.quoteLines
        self.fenceLines = semanticWalker.fenceLines
    }

    /// 公式扩展只重写可能包含公式的 AST 叶节点，而不是复制整棵文档树。
    ///
    /// 当前 swift-markdown 数学提案通过 `MarkupRewriter` 复制整棵 AST；在 200 KB / 1 MB
    /// 文档里，即使只有一个公式也会把解析退化到秒级。这里先用标准 AST 找到 Paragraph / Text
    /// 叶节点，再把这些很小的节点文本交给同一个 `.parseMath` 扩展。`$` 字节只负责跳过
    /// 不可能命中的叶节点；分隔符能否成立、表达式内容和范围仍全部取自数学 AST。
    private struct MathSyntaxWalker: MarkupWalker {
        let bytes: [UInt8]
        let lineStarts: [Int]
        let lines: [TokenScanner.Line]
        var math = [MathSyntax]()

        mutating func visitParagraph(_ paragraph: Paragraph) {
            if appendBlockMath(from: paragraph) { return }
            descendInto(paragraph)
        }

        mutating func visitText(_ text: Text) {
            guard let originalRange = byteRange(text),
                  originalRange.lowerBound >= 0,
                  originalRange.upperBound <= bytes.count,
                  bytes[originalRange].contains(0x24),
                  let sourceRange = text.range,
                  sourceRange.lowerBound.line == sourceRange.upperBound.line
            else { return }

            // `Text.string` 已经被 cmark 解码：实体会缩短，反斜杠转义也会被消费。
            // 数学 AST 的列号若从那份字符串取得，就不能再直接加到原始 UTF-8 偏移。
            // 改为探测原始切片，并逐字节把普通正文替换成 ASCII `x`：既屏蔽切片
            // 开头的 Markdown 块/行内语法，又严格保留 CJK、实体与转义前后的字节列。
            let probeSource = inlineMathProbeSource(originalRange)
            let probe = Document(
                parsing: probeSource,
                options: [.disableSmartOpts, .parseMath]
            )
            var collector = InlineMathProbe()
            collector.visit(probe)
            let line = sourceRange.lowerBound.line - 1
            guard line >= 0, line < lines.count else { return }

            for node in collector.nodes {
                guard let localRange = node.range,
                      localRange.lowerBound.line == 1,
                      localRange.upperBound.line == 1
                else { continue }
                let lower = originalRange.lowerBound + localRange.lowerBound.column - 1
                let upper = originalRange.lowerBound + localRange.upperBound.column - 1
                guard lower >= originalRange.lowerBound,
                      upper <= originalRange.upperBound,
                      upper - lower >= 2
                else { continue }
                math.append(MathSyntax(
                    kind: .inline,
                    expression: String(decoding: bytes[(lower + 1)..<(upper - 1)], as: UTF8.self),
                    openMarker: lower..<(lower + 1),
                    closeMarker: (upper - 1)..<upper,
                    content: (lower + 1)..<(upper - 1),
                    line: line
                ))
            }
        }

        /// 行内公式探测必须保留原始 UTF-8 列。按 Unicode 字符替换会把一个 CJK
        /// 标量从 3 字节压成 1 字节，仍然会重现错位；因此直接逐字节替换。Text 的
        /// AST range 可能从已消费转义后的 `$` 才开始，故还要回看全局原始字节，
        /// 把奇数个反斜杠转义的 dollar 一并屏蔽。
        private func inlineMathProbeSource(_ range: Range<Int>) -> String {
            var probe = Array(bytes[range])
            for localIndex in probe.indices {
                let byte = probe[localIndex]
                if byte == 0x24 {
                    let globalIndex = range.lowerBound + localIndex
                    var slashCount = 0
                    var cursor = globalIndex
                    while cursor > 0, bytes[cursor - 1] == 0x5C {
                        slashCount += 1
                        cursor -= 1
                    }
                    if slashCount.isMultiple(of: 2) { continue }
                } else if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    continue
                }
                probe[localIndex] = 0x78
            }
            return String(decoding: probe, as: UTF8.self)
        }

        /// 返回 true 表示 Paragraph 已由数学 AST 确认为块公式，不再扫描其中的行内节点。
        private mutating func appendBlockMath(from paragraph: Paragraph) -> Bool {
            guard let range = byteRange(paragraph),
                  let sourceRange = paragraph.range,
                  !lines.isEmpty,
                  range.lowerBound >= 0,
                  range.upperBound <= bytes.count
            else { return false }

            // 优先把 Paragraph 对应的原始 UTF-8 切片交给数学扩展。不能使用
            // Paragraph/Text 的 `.string` 重建：CommonMark 会先消费 `\!`、`\,`
            // 这类合法 LaTeX 转义，也可能把下划线组合拆成强调节点，导致复杂公式
            // 尚未进入数学 AST 就已经失真或被拒绝。
            let exactSource = String(decoding: bytes[range], as: UTF8.self)
            if exactSource.utf8.contains(0x24) {
                let probe = Document(
                    parsing: blockMathProbeSource(exactSource),
                    options: [.disableSmartOpts, .parseMath]
                )
                if probe.child(at: 0) is BlockMath,
                   appendBlockMath(
                    expression: nil,
                    range: range,
                    sourceRange: sourceRange,
                    containerTextRanges: nil
                   ) {
                    return true
                }
            }

            // 引用等容器的 Paragraph 范围会跨过每一行的容器前缀，原始连续切片
            // 不能单独构成 BlockMath；这种情况保留 AST 子节点重建作为回退。
            var rawText = ""
            var textRanges: [Range<Int>] = []
            for child in paragraph.children {
                if let text = child as? Text {
                    rawText += text.string
                    if let range = byteRange(text) {
                        textRanges.append(range)
                    }
                } else if child is SoftBreak || child is LineBreak {
                    rawText += "\n"
                } else {
                    return false
                }
            }
            guard rawText.utf8.contains(0x24) else { return false }

            let probe = Document(
                parsing: rawText,
                options: [.disableSmartOpts, .parseMath]
            )
            guard let blockMath = probe.child(at: 0) as? BlockMath else { return false }
            return appendBlockMath(
                expression: blockMath.code,
                range: range,
                sourceRange: sourceRange,
                containerTextRanges: textRanges
            )
        }

        private mutating func appendBlockMath(
            expression suppliedExpression: String?,
            range: Range<Int>,
            sourceRange: SourceRange,
            containerTextRanges: [Range<Int>]?
        ) -> Bool {
            let line = sourceRange.lowerBound.line - 1
            guard line >= 0, line < lines.count else { return false }
            let lastLine = min(
                lineIndex(ofByte: max(range.upperBound - 1, range.lowerBound)) ?? line,
                lines.count - 1
            )
            guard lastLine >= line else { return false }

            let expression: String
            if let suppliedExpression {
                expression = suppliedExpression
            } else if line == lastLine {
                guard range.count >= 4 else { return false }
                expression = String(
                    decoding: bytes[(range.lowerBound + 2)..<(range.upperBound - 2)],
                    as: UTF8.self
                )
            } else {
                let contentStart = lines[line].next
                let contentEnd = lines[max(line, lastLine - 1)].end
                guard contentStart <= contentEnd,
                      contentStart >= range.lowerBound,
                      contentEnd <= range.upperBound
                else { return false }
                expression = String(decoding: bytes[contentStart..<contentEnd], as: UTF8.self)
            }

            if line == lastLine {
                guard range.count >= 4 else { return false }
                math.append(MathSyntax(
                    kind: .block(lastLine: lastLine),
                    expression: expression,
                    openMarker: range.lowerBound..<(range.lowerBound + 2),
                    closeMarker: (range.upperBound - 2)..<range.upperBound,
                    content: (range.lowerBound + 2)..<(range.upperBound - 2),
                    line: line
                ))
                return true
            }

            if containerTextRanges == nil {
                guard range.count >= 4 else { return false }
                let closeMarker = (range.upperBound - 2)..<range.upperBound
                math.append(MathSyntax(
                    kind: .block(lastLine: lastLine),
                    expression: expression,
                    openMarker: range.lowerBound..<(range.lowerBound + 2),
                    closeMarker: closeMarker,
                    content: min(lines[line].next, closeMarker.lowerBound)..<closeMarker.lowerBound,
                    line: line
                ))
                return true
            }

            // 容器前缀（如 `> `）不属于 Paragraph 的 Text 子节点。首尾 Text 的 AST
            // 范围因此能精确排除引用前缀，避免把它并进 `$$` 分隔符。
            guard let openMarker = containerTextRanges?.first,
                  let closeMarker = containerTextRanges?.last,
                  openMarker.upperBound <= closeMarker.lowerBound
            else { return false }
            math.append(MathSyntax(
                kind: .block(lastLine: lastLine),
                expression: expression,
                openMarker: openMarker,
                closeMarker: closeMarker,
                content: min(lines[line].next, closeMarker.lowerBound)..<closeMarker.lowerBound,
                line: line
            ))
            return true
        }

        /// swift-markdown 当前的数学扩展在识别 `$$` 前会先跑 CommonMark 行内解析，
        /// 因而 `_`、`*`、`\!` 等 LaTeX 字符可能把 Paragraph 拆成非 Text 子节点。
        /// 探测串只保留分隔符与空白布局，屏蔽正文的行内语法；是否为块公式仍由
        /// `.parseMath` 产生的 BlockMath 节点决定，真实表达式再从同一 AST 范围的
        /// 原始 UTF-8 快照读取。
        private func blockMathProbeSource(_ source: String) -> String {
            String(source.map { character in
                switch character {
                case "$", " ", "\t", "\n", "\r":
                    character
                default:
                    "x"
                }
            })
        }

        private func byteRange(_ markup: Markup) -> Range<Int>? {
            guard let range = markup.range,
                  let lower = MarkdownSemantics.byteOffset(
                    range.lowerBound,
                    lineStarts: lineStarts,
                    lines: lines
                  ),
                  let upper = MarkdownSemantics.byteOffset(
                    range.upperBound,
                    lineStarts: lineStarts,
                    lines: lines
                  ),
                  lower <= upper
            else { return nil }
            return lower..<upper
        }

        private func lineIndex(ofByte offset: Int) -> Int? {
            guard !lineStarts.isEmpty else { return nil }
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return min(low, lines.count - 1)
        }

        private struct InlineMathProbe: MarkupWalker {
            var nodes = [InlineMath]()

            mutating func visitInlineMath(_ inlineMath: InlineMath) {
                nodes.append(inlineMath)
            }
        }
    }

    /// 使用 swift-markdown 官方 walker 收集语义结构与 marker。
    ///
    /// 这个 walker 不匹配分隔符，也不复制 CommonMark 规则：AST 节点的父子
    /// `SourceRange` 直接给出 marker 边界，块结构则由节点类型和 parent 链给出。
    private struct SemanticWalker: MarkupWalker {
        let bytes: [UInt8]
        let lineStarts: [Int]
        let lines: [TokenScanner.Line]

        var inlineMarkers = [InlineMarker]()
        var blocks = [BlockStructure]()
        var links = [LinkSyntax]()
        var images = [LinkSyntax]()
        var tables = [TableStructure]()
        var blockImageLines = Set<Int>()
        var listItemLines = Set<Int>()
        var quoteLines = Set<Int>()
        var fenceLines = Set<Int>()

        init(bytes: [UInt8], lineStarts: [Int], lines: [TokenScanner.Line]) {
            self.bytes = bytes
            self.lineStarts = lineStarts
            self.lines = lines
        }

        mutating func visitHeading(_ heading: Heading) {
            appendHeading(heading)
            descendInto(heading)
        }

        mutating func visitListItem(_ listItem: ListItem) {
            appendListItem(listItem)
            descendInto(listItem)
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            appendBlockQuote(blockQuote)
            descendInto(blockQuote)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            appendCodeBlock(codeBlock)
        }

        /// GFM 表格。分隔行整行作为表格的 marker 参与显隐；表头恒可见。
        /// 单元格内的行内标记照常由通用 visit 收集。
        mutating func visitTable(_ table: Table) {
            guard let range = byteRange(table), let headerLine = sourceLine(of: table),
                  headerLine + 1 < lines.count
            else {
                descendInto(table)
                return
            }
            // 末行按 AST 区间末字节所在行反推；文件末尾无换行时按行数组收口。
            let lastLine = min(lineIndex(ofByte: max(range.upperBound - 1, 0)) ?? headerLine, lines.count - 1)
            let delimiter = lines[headerLine + 1]
            // content 必须非空（applyStyle 的 content guard）：用末行区间占位。
            blocks.append(.init(
                kind: .table(lastLine: max(lastLine, headerLine + 1)),
                line: headerLine,
                marker: delimiter.start..<delimiter.end,
                content: delimiter.end..<max(delimiter.end, lines[max(lastLine, headerLine)].end)
            ))
            appendTableStructure(
                table,
                headerLine: headerLine,
                lastLine: max(lastLine, headerLine + 1)
            )
            descendInto(table)
        }

        /// 把 AST 的单元格区间还原成源码几何：单元格取 `Table.Cell.range`，
        /// `|` 在单元格边界上按字节核对。核对失败（源码省略了该处管线符）时
        /// 记为 nil，渲染层据此少一个内边距承载点，不影响其余列。
        private mutating func appendTableStructure(
            _ table: Table,
            headerLine: Int,
            lastLine: Int
        ) {
            var rows: [TableStructure.Row] = []
            if let headerRow = tableRow(cells: Array(table.head.cells)) {
                rows.append(headerRow)
            }
            for bodyRow in table.body.rows {
                if let row = tableRow(cells: Array(bodyRow.cells)) {
                    rows.append(row)
                }
            }
            guard !rows.isEmpty else { return }

            let firstStructureOffset = rows[0].cells[0].leadingGap.lowerBound
            let prefixRange = lines[headerLine].start..<max(lines[headerLine].start, firstStructureOffset)
            let containerPrefix = String(decoding: bytes[prefixRange], as: UTF8.self)

            let alignments = table.columnAlignments.map { alignment -> TableStructure.ColumnAlignment in
                switch alignment {
                case .center: return .center
                case .right: return .trailing
                case .left, .none: return .leading
                }
            }
            tables.append(TableStructure(
                headerLine: headerLine,
                containerPrefix: containerPrefix,
                delimiterLine: headerLine + 1,
                lastLine: lastLine,
                alignments: alignments,
                rows: rows
            ))
        }

        private func tableRow(cells: [Table.Cell]) -> TableStructure.Row? {
            guard let first = cells.first, let line = sourceLine(of: first) else { return nil }
            var contents: [Range<Int>] = []
            for cell in cells {
                // colspan 0 的单元格被前一格覆盖，没有自己的源码区间。
                guard cell.colspan > 0, var range = byteRange(cell) else { continue }
                // cmark-gfm 对全空白单元格会把右侧分隔 `|` 算进 Cell.range。
                // 例如 `|  |  |` 的两个 cell 都以管线符结尾；若把它当作墨迹，
                // 增量渲染重置属性后就会露出竖线。未转义的管线符在 GFM 单元格
                // 末尾只能是分隔符，因此把它移回结构区；内容里的 `\|` 保留。
                if range.upperBound > range.lowerBound {
                    let pipeOffset = range.upperBound - 1
                    if bytes[pipeOffset] == 0x7C, isEscaped(at: pipeOffset) == false {
                        range = range.lowerBound..<pipeOffset
                    }
                }
                contents.append(range)
            }
            guard !contents.isEmpty else { return nil }

            let bounds = lines[line]
            // 结构区从行首的 `|`（若有）开始；没有行首管线符时从首格内容开始。
            var gapStart = pipe(endingAt: contents[0].lowerBound)?.lowerBound ?? contents[0].lowerBound
            var structureCells: [TableStructure.Cell] = []
            structureCells.reserveCapacity(contents.count)
            for content in contents {
                let ink = inkRange(in: content)
                structureCells.append(TableStructure.Cell(
                    content: content,
                    ink: ink,
                    leadingGap: gapStart..<max(gapStart, ink.lowerBound),
                    trailingPipe: pipe(startingAt: content.upperBound)
                ))
                gapStart = ink.upperBound
            }
            let rowEnd = min(
                max(gapStart, structureCells[structureCells.count - 1].trailingPipe?.upperBound
                    ?? contents[contents.count - 1].upperBound),
                bounds.end
            )
            return TableStructure.Row(
                line: line,
                cells: structureCells,
                trailingGap: gapStart..<rowEnd
            )
        }

        /// 单元格内去掉两侧空白后的区间。全为空白时长度为 0。
        private func inkRange(in content: Range<Int>) -> Range<Int> {
            var lower = content.lowerBound
            var upper = content.upperBound
            let isBlank: (Int) -> Bool = { self.bytes[$0] == 0x20 || self.bytes[$0] == 0x09 }
            while lower < upper, isBlank(lower) { lower += 1 }
            while upper > lower, isBlank(upper - 1) { upper -= 1 }
            return lower..<upper
        }

        /// `offset` 处正好是一个 `|` 时返回它的区间。
        private func pipe(startingAt offset: Int) -> Range<Int>? {
            guard offset >= 0, offset < bytes.count, bytes[offset] == 0x7C else { return nil }
            return offset..<(offset + 1)
        }

        /// `offset` 前一个字节正好是 `|` 时返回它的区间。
        private func pipe(endingAt offset: Int) -> Range<Int>? {
            pipe(startingAt: offset - 1)
        }

        private func isEscaped(at offset: Int) -> Bool {
            guard offset > 0 else { return false }
            var cursor = offset
            var slashCount = 0
            while cursor > 0, bytes[cursor - 1] == 0x5C {
                slashCount += 1
                cursor -= 1
            }
            return slashCount % 2 == 1
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            appendThematicBreak(thematicBreak)
        }

        mutating func visitStrong(_ strong: Strong) {
            appendInline(.strong, markup: strong)
            descendInto(strong)
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            appendInline(.emphasis, markup: emphasis)
            descendInto(emphasis)
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            appendInline(.strikethrough, markup: strikethrough)
            descendInto(strikethrough)
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            appendInlineCode(inlineCode)
        }

        mutating func visitLink(_ link: Link) {
            if link.destination != nil,
               let range = byteRange(link),
               let syntax = MarkdownSemantics.parseBounds(
                range,
                bytes: bytes,
                expectedDestination: link.destination
               ) {
                links.append(.init(openBracket: syntax.openBracket, label: syntax.label,
                                   tail: syntax.tail, destination: syntax.destination,
                                   line: sourceLine(of: link) ?? 0))
            }
            descendInto(link)
        }

        /// 图片 `![标签](目的地)`。边界解析复用链接的字节扫描：AST 区间以 `!`
        /// 开头，跳过它之后就是 `[…](…)` 的形状。
        mutating func visitImage(_ image: Image) {
            guard let range = byteRange(image), let line = sourceLine(of: image),
                  range.lowerBound + 1 < range.upperBound,
                  bytes[range.lowerBound] == 0x21, bytes[range.lowerBound + 1] == 0x5B,
                  let syntax = MarkdownSemantics.parseBounds(
                    (range.lowerBound + 1)..<range.upperBound,
                    bytes: bytes,
                    expectedDestination: image.source
                  )
            else {
                descendInto(image)
                return
            }
            images.append(.init(
                openBracket: range.lowerBound..<(range.lowerBound + 2),
                label: syntax.label,
                tail: syntax.tail,
                destination: syntax.destination,
                line: line
            ))
            if isSoleContentOfLine(range, line: line) {
                blockImageLines.insert(line)
            }
            descendInto(image)
        }

        /// 语法区间是否独占整行（两侧只允许空格与制表符）。
        private func isSoleContentOfLine(_ range: Range<Int>, line: Int) -> Bool {
            let bounds = lines[line]
            guard range.lowerBound >= bounds.start, range.upperBound <= bounds.end else { return false }
            let isBlank: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 }
            return bytes[bounds.start..<range.lowerBound].allSatisfy(isBlank)
                && bytes[range.upperBound..<bounds.end].allSatisfy(isBlank)
        }

        mutating func defaultVisit(_ markup: Markup) {
            descendInto(markup)
        }

        private mutating func appendHeading(_ heading: Heading) {
            guard let range = byteRange(heading), let line = sourceLine(of: heading) else { return }
            let contentStart = firstChildStart(heading) ?? min(range.upperBound, lines[line].end)
            let markerStart = syntaxStart(on: line, atOrAfter: range.lowerBound)
            let marker = markerStart..<min(max(contentStart, markerStart), lines[line].end)
            let content = marker.upperBound..<lines[line].end
            blocks.append(.init(kind: .heading(level: heading.level), line: line, marker: marker,
                                content: content))
        }

        private mutating func appendListItem(_ listItem: ListItem) {
            guard let range = byteRange(listItem), let parent = listItem.parent,
                  let line = sourceLine(of: listItem) else { return }

            let depth = listDepth(from: listItem)
            let kind: BlockStructure.Kind
            if let ordered = parent as? OrderedList {
                kind = .orderedList(depth: depth, number: Int(ordered.startIndex) + listItem.indexInParent)
            } else if parent is UnorderedList, let checkbox = listItem.checkbox {
                switch checkbox {
                case .checked:
                    kind = .taskList(depth: depth, checked: true)
                case .unchecked:
                    kind = .taskList(depth: depth, checked: false)
                }
            } else if parent is UnorderedList {
                kind = .unorderedList(depth: depth)
            } else {
                return
            }

            let contentStart = firstChildStart(listItem) ?? min(range.upperBound, lines[line].end)
            let markerStart = syntaxStart(on: line, atOrAfter: range.lowerBound)
            let markerUpper = min(max(contentStart, markerStart), lines[line].end)
            blocks.append(.init(kind: kind, line: line, marker: markerStart..<markerUpper,
                                content: markerUpper..<lines[line].end))
            listItemLines.insert(line)
        }

        /// 引用块**逐行**产出 token。
        ///
        /// 一块一个 token 是不够的：`.museBlock` 由绘制层按 fragment（= 一个段落，
        /// 也就是一行）读取，只在首行落标记时第二行就既没有竖条底色、也没人折叠它的
        /// `> `——引用块在第一行就断了。逐行产出同时让「光标所在行回显源码」这条规则
        /// （`token.line == caretLine`）落到行的粒度上，回显一行不影响整块的视觉。
        ///
        /// 每一层 BlockQuote 只认自己那一个 `>`（见 `quoteMarkerRange`），所以
        /// `> > x` 的内外两层不会抢同一段字符。
        private mutating func appendBlockQuote(_ blockQuote: BlockQuote) {
            guard let range = byteRange(blockQuote), !lines.isEmpty else { return }
            let depth = quoteDepth(from: blockQuote)
            for line in lineSpan(of: range) {
                let marker = quoteMarkerRange(on: line, depth: depth)
                blocks.append(.init(kind: .blockquote(depth: depth), line: line,
                                    marker: marker,
                                    content: marker.upperBound..<lines[line].end))
            }
            markAllLines(range, into: &quoteLines)
        }

        /// 本层引用在这一行上的 `>` 前缀。
        ///
        /// 一行可能带多层 `>`（`> > x`）：先跳过外层的 `depth - 1` 个，再吃掉本层的
        /// `>` 和紧随的至多一个空格（CommonMark 只把第一个空格算进 marker）。
        ///
        /// 懒续行（CommonMark 允许段落续行省掉 `>`）返回空区间——它没有字符要折叠，
        /// 只需要拿到块视觉，竖条才不会在这一行断开。
        private func quoteMarkerRange(on line: Int, depth: Int) -> Range<Int> {
            let end = lines[line].end
            var cursor = lineStarts[line]

            func skipBlanks() {
                while cursor < end, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
            }
            /// 吃掉一个 `>` 及其后至多一个空格；这一行没有 `>` 时返回 false。
            func consumeAngle() -> Bool {
                guard cursor < end, bytes[cursor] == 0x3E else { return false }
                cursor += 1
                if cursor < end, bytes[cursor] == 0x20 { cursor += 1 }
                return true
            }

            for _ in 0..<max(0, depth - 1) {
                skipBlanks()
                guard consumeAngle() else { return cursor..<cursor }
            }
            skipBlanks()
            let start = cursor
            return consumeAngle() ? start..<cursor : start..<start
        }

        private mutating func appendCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = byteRange(codeBlock), let line = sourceLine(of: codeBlock) else { return }
            markAllLines(range, into: &fenceLines)

            guard let opening = delimiterRun(on: lines[line], atOrAfter: range.lowerBound) else { return }
            let containerOffset = opening.lowerBound - lines[line].start
            // The AST source range already bounds this code block. Use that
            // range directly instead of searching the accumulated fence-line
            // set from the beginning of the document for every block.
            let sourceEndLine = codeBlock.range?.upperBound.line ?? line + 1
            let endLine = min(lines.count - 1, max(line, sourceEndLine - 1))
            var closingLine: TokenScanner.Line?
            if line < endLine {
                for index in (line + 1)...endLine {
                    let candidate = lines[index]
                    if isClosingFence(
                        candidate,
                        matching: opening,
                        containerOffset: containerOffset
                    ) {
                        closingLine = candidate
                        break
                    }
                }
            }
            let bodyStart = lines[line].next
            let bodyEnd = closingLine?.start ?? bytes.count
            let closingMarker = closingLine.flatMap {
                delimiterRun(on: $0, atOrAfter: $0.start + containerOffset)
            }
            blocks.append(.init(
                kind: .codeFence(language: codeBlock.language),
                line: line,
                marker: opening.lowerBound..<lines[line].end,
                content: bodyStart..<max(bodyStart, bodyEnd),
                closingMarker: closingMarker
            ))
        }

        private mutating func appendThematicBreak(_ thematicBreak: ThematicBreak) {
            guard let range = byteRange(thematicBreak), let line = sourceLine(of: thematicBreak) else {
                return
            }
            let start = syntaxStart(on: line, atOrAfter: range.lowerBound)
            let end = min(lines[line].end, max(start, range.upperBound))
            blocks.append(.init(kind: .rule, line: line,
                                marker: start..<end))
        }

        /// AST 节点可能嵌在 blockquote/list 容器内。节点自己的下界是可信的
        /// 最早语法位置；从那里继续跳过空格，既不吞容器前缀，也保留合法缩进。
        private func syntaxStart(on line: Int, atOrAfter lowerBound: Int) -> Int {
            var start = min(lines[line].end, max(lineStarts[line], lowerBound))
            while start < lines[line].end, bytes[start] == 0x20 || bytes[start] == 0x09 {
                start += 1
            }
            return start
        }

        /// Extract a delimiter run only after the AST has identified the code
        /// block. This recovers the exact source span; it does not decide
        /// whether a line opens or closes a block.
        private func delimiterRun(
            on line: TokenScanner.Line,
            atOrAfter lowerBound: Int
        ) -> Range<Int>? {
            let start = syntaxStart(on: line.index, atOrAfter: lowerBound)
            guard start < line.end, bytes[start] == 0x60 || bytes[start] == 0x7E else { return nil }
            let delimiter = bytes[start]
            var end = start
            while end < line.end, bytes[end] == delimiter { end += 1 }
            guard end - start >= 3 else { return nil }
            return start..<end
        }

        private func isClosingFence(
            _ line: TokenScanner.Line,
            matching opening: Range<Int>?,
            containerOffset: Int
        ) -> Bool {
            guard let opening,
                  let closing = delimiterRun(
                    on: line,
                    atOrAfter: line.start + containerOffset
                  ),
                  bytes[opening.lowerBound] == bytes[closing.lowerBound],
                  closing.count >= opening.count else { return false }
            return bytes[closing.upperBound..<line.end].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        }

        private mutating func appendInline(_ kind: InlineMarker.Kind, markup: Markup) {
            guard let range = byteRange(markup), let line = sourceLine(of: markup) else { return }

            // cmark preserves the Emphasis(Strong(...)) tree for a triple
            // delimiter run, but assigns the same source range to both nodes.
            // Keep that AST structure visible by splitting the known one-star
            // outer marker from the two-star inner marker. This is range
            // normalization for one source-location ambiguity, not delimiter
            // matching; all semantic decisions still come from the AST.
            if kind == .emphasis,
               let strong = markup.children.first(where: { _ in true }) as? Strong,
               byteRange(strong) == range,
               hasTripleDelimiter(in: range) {
                inlineMarkers.append(.init(
                    kind: .emphasis,
                    openMarker: range.lowerBound..<(range.lowerBound + 1),
                    closeMarker: (range.upperBound - 1)..<range.upperBound,
                    content: (range.lowerBound + 1)..<(range.upperBound - 1),
                    line: line
                ))
                return
            }

            if kind == .strong,
               markup.parent is Emphasis,
               let parent = markup.parent,
               byteRange(parent) == range,
               hasTripleDelimiter(in: range) {
                inlineMarkers.append(.init(
                    kind: .strong,
                    openMarker: (range.lowerBound + 1)..<(range.lowerBound + 3),
                    closeMarker: (range.upperBound - 3)..<(range.upperBound - 1),
                    content: (range.lowerBound + 3)..<(range.upperBound - 3),
                    line: line
                ))
                return
            }

            var first: Range<Int>?
            var last: Range<Int>?
            for child in markup.children {
                guard let childRange = byteRange(child) else { continue }
                if first == nil || childRange.lowerBound < first!.lowerBound {
                    first = childRange
                }
                if last == nil || childRange.upperBound > last!.upperBound {
                    last = childRange
                }
            }

            guard let first, let last,
                  range.lowerBound < first.lowerBound,
                  last.upperBound < range.upperBound else { return }

            let openMarker = range.lowerBound..<first.lowerBound
            var closeMarker = last.upperBound..<range.upperBound
            // cmark's source range includes the unused second star in
            // `*foo**`, although the emphasis node consumes one delimiter.
            // Keep the AST decision and normalize only this source-location
            // overhang so the token range describes the actual marker.
            if kind == .emphasis, openMarker.count == 1, closeMarker.count > 1 {
                closeMarker = closeMarker.lowerBound..<(closeMarker.lowerBound + 1)
            }
            inlineMarkers.append(.init(
                kind: kind,
                openMarker: openMarker,
                closeMarker: closeMarker,
                content: first.lowerBound..<last.upperBound,
                line: line
            ))
        }

        private func hasTripleDelimiter(in range: Range<Int>) -> Bool {
            guard range.count >= 6,
                  range.lowerBound + 2 < bytes.count,
                  range.upperBound - 3 >= range.lowerBound,
                  range.upperBound <= bytes.count else { return false }
            let delimiter = bytes[range.lowerBound]
            guard delimiter == 0x2A || delimiter == 0x5F else { return false }
            return bytes[range.lowerBound..<(range.lowerBound + 3)].allSatisfy { $0 == delimiter }
                && bytes[(range.upperBound - 3)..<range.upperBound].allSatisfy { $0 == delimiter }
        }

        private mutating func appendInlineCode(_ inlineCode: InlineCode) {
            guard let range = byteRange(inlineCode), range.lowerBound < range.upperBound,
                  let line = sourceLine(of: inlineCode) else { return }

            var openEnd = range.lowerBound
            while openEnd < range.upperBound, bytes[openEnd] == 0x60 { openEnd += 1 }
            var closeStart = range.upperBound
            while closeStart > openEnd, bytes[closeStart - 1] == 0x60 { closeStart -= 1 }
            guard openEnd > range.lowerBound, closeStart <= range.upperBound else { return }

            inlineMarkers.append(.init(
                kind: .inlineCode,
                openMarker: range.lowerBound..<openEnd,
                closeMarker: closeStart..<range.upperBound,
                content: openEnd..<closeStart,
                line: line
            ))
        }

        private func byteRange(_ markup: Markup) -> Range<Int>? {
            guard let range = markup.range,
                  let lower = MarkdownSemantics.byteOffset(
                    range.lowerBound,
                    lineStarts: lineStarts,
                    lines: lines
                  ),
                  let upper = MarkdownSemantics.byteOffset(
                    range.upperBound,
                    lineStarts: lineStarts,
                    lines: lines
                  ),
                  lower <= upper else { return nil }
            return lower..<upper
        }

        private func sourceLine(of markup: Markup) -> Int? {
            guard let range = markup.range else { return nil }
            let line = range.lowerBound.line - 1
            guard line >= 0, line < lines.count else { return nil }
            return line
        }

        private func lineIndex(_ range: Range<Int>) -> Int? {
            guard !lineStarts.isEmpty else { return nil }
            return lineIndex(ofByte: range.lowerBound)
        }

        private func lineIndex(ofByte offset: Int) -> Int? {
            guard !lineStarts.isEmpty else { return nil }
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return min(low, lines.count - 1)
        }

        private func firstChildStart(_ markup: Markup) -> Int? {
            for child in markup.children {
                if let range = byteRange(child) {
                    return range.lowerBound
                }
            }
            return nil
        }

        private func listDepth(from listItem: ListItem) -> Int {
            var depth = 0
            var ancestor = listItem.parent
            while let node = ancestor {
                if node is OrderedList || node is UnorderedList { depth += 1 }
                ancestor = node.parent
            }
            return max(depth, 1)
        }

        private func quoteDepth(from blockQuote: BlockQuote) -> Int {
            var depth = 1
            var ancestor = blockQuote.parent
            while let node = ancestor {
                if node is BlockQuote { depth += 1 }
                ancestor = node.parent
            }
            return depth
        }

        /// 字节区间覆盖到的行号闭区间。
        ///
        /// `upperBound` 是开区间端点，落在下一行行首时不能把那一行算进来，所以按
        /// 「最后一个字节」反查。逐行产出 token 与行集合（`quoteLines` 等）都从这里
        /// 取行号，两者因此不可能漂移。
        private func lineSpan(of range: Range<Int>) -> ClosedRange<Int> {
            let start = max(0, lineIndex(ofByte: range.lowerBound) ?? 0)
            let endOffset = max(range.lowerBound, range.upperBound - 1)
            let end = min(lines.count - 1, max(start, lineIndex(ofByte: endOffset) ?? start))
            return start...end
        }

        private func markAllLines(_ range: Range<Int>, into target: inout Set<Int>) {
            for line in lineSpan(of: range) {
                target.insert(line)
            }
        }
    }

    private static func byteOffset(
        _ location: SourceLocation,
        lineStarts: [Int],
        lines: [TokenScanner.Line]
    ) -> Int? {
        let line = location.line - 1
        guard line >= 0, line < lineStarts.count, line < lines.count else { return nil }
        let offset = lineStarts[line] + max(0, location.column - 1)
        guard offset >= lineStarts[line], offset <= lines[line].end else { return nil }
        return offset
    }

    /// AST 已确认节点合法；这里只恢复标签、destination 与整段 tail 的源码字节边界。
    private static func parseBounds(
        _ syntax: Range<Int>,
        bytes: [UInt8],
        expectedDestination: String?
    ) -> LinkSyntax? {
        let end = min(syntax.upperBound, bytes.count)
        guard syntax.lowerBound < end, bytes[syntax.lowerBound] == 0x5B else { return nil }

        // 标签：支持嵌套括号 [a [b] c]
        var depth = 1
        var labelEnd = -1
        var i = syntax.lowerBound + 1
        while i < end {
            let byte = bytes[i]
            if byte == 0x5C { i += 2; continue }
            if byte == 0x5B { depth += 1 }
            else if byte == 0x5D {
                depth -= 1
                if depth == 0 { labelEnd = i; break }
            }
            i += 1
        }
        guard labelEnd >= 0,
              labelEnd + 2 < end,
              bytes[labelEnd + 1] == 0x28,
              bytes[end - 1] == 0x29
        else { return nil }

        let payloadEnd = end - 1
        var destinationStart = labelEnd + 2
        while destinationStart < payloadEnd, isASCIIWhitespace(bytes[destinationStart]) {
            destinationStart += 1
        }

        let destination: Range<Int>
        if expectedDestination == nil || expectedDestination?.isEmpty == true {
            destination = destinationStart..<destinationStart
        } else if destinationStart < payloadEnd, bytes[destinationStart] == 0x3C { // <...>
            var close = destinationStart + 1
            while close < payloadEnd {
                if bytes[close] == 0x5C { close += 2; continue }
                if bytes[close] == 0x3E { break }
                close += 1
            }
            guard close < payloadEnd else { return nil }
            destination = (destinationStart + 1)..<close
        } else {
            var destinationEnd = destinationStart
            var parenthesisDepth = 0
            while destinationEnd < payloadEnd {
                let byte = bytes[destinationEnd]
                if byte == 0x5C {
                    destinationEnd = min(destinationEnd + 2, payloadEnd)
                    continue
                }
                if isASCIIWhitespace(byte), parenthesisDepth == 0 { break }
                if byte == 0x28 {
                    parenthesisDepth += 1
                } else if byte == 0x29, parenthesisDepth > 0 {
                    parenthesisDepth -= 1
                }
                destinationEnd += 1
            }
            destination = destinationStart..<destinationEnd
        }

        let open = syntax.lowerBound
        return LinkSyntax(
            openBracket: open..<(open + 1),
            label: (open + 1)..<labelEnd,
            tail: labelEnd..<end,
            destination: destination
        )
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
