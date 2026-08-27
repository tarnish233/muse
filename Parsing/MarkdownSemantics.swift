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

    public let lineKinds: [LineKind]
    public let links: [LinkSyntax]
    public let inlineMarkers: [InlineMarker]
    public let blocks: [BlockStructure]
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
        result.append(contentsOf: links.map { link in
            Token(kind: .link, markerRange: link.openBracket, closingMarkerRange: link.tail,
                  contentRange: link.label, linkDestination: link.destination, line: link.line)
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
        self.inlineMarkers = semanticWalker.inlineMarkers.sorted {
            if $0.openMarker.lowerBound != $1.openMarker.lowerBound {
                return $0.openMarker.lowerBound < $1.openMarker.lowerBound
            }
            return $0.openMarker.upperBound > $1.openMarker.upperBound
        }
        self.blocks = semanticWalker.blocks.sorted {
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.marker.lowerBound < $1.marker.lowerBound
        }
        self.listItemLines = semanticWalker.listItemLines
        self.quoteLines = semanticWalker.quoteLines
        self.fenceLines = semanticWalker.fenceLines
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
               let syntax = MarkdownSemantics.parseBounds(range, bytes: bytes) {
                links.append(.init(openBracket: syntax.openBracket, label: syntax.label,
                                   tail: syntax.tail, destination: syntax.destination,
                                   line: sourceLine(of: link) ?? 0))
            }
            descendInto(link)
        }

        mutating func defaultVisit(_ markup: Markup) {
            descendInto(markup)
        }

        private mutating func appendHeading(_ heading: Heading) {
            guard let range = byteRange(heading), let line = sourceLine(of: heading) else { return }
            let contentStart = firstChildStart(heading) ?? min(range.upperBound, lines[line].end)
            let markerStart = syntaxStart(on: line)
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
            let markerStart = syntaxStart(on: line)
            let markerUpper = min(max(contentStart, markerStart), lines[line].end)
            blocks.append(.init(kind: kind, line: line, marker: markerStart..<markerUpper,
                                content: markerUpper..<lines[line].end))
            listItemLines.insert(line)
        }

        private mutating func appendBlockQuote(_ blockQuote: BlockQuote) {
            guard let range = byteRange(blockQuote), let line = sourceLine(of: blockQuote) else { return }
            let depth = quoteDepth(from: blockQuote)
            let contentStart = firstChildStart(blockQuote) ?? min(range.upperBound, lines[line].end)
            let markerStart = syntaxStart(on: line)
            let markerUpper = min(max(contentStart, markerStart), lines[line].end)
            blocks.append(.init(kind: .blockquote(depth: depth), line: line,
                                marker: markerStart..<markerUpper,
                                content: markerUpper..<lines[line].end))
            markAllLines(range, into: &quoteLines)
        }

        private mutating func appendCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = byteRange(codeBlock), let line = sourceLine(of: codeBlock) else { return }
            markAllLines(range, into: &fenceLines)

            guard let opening = delimiterRun(on: lines[line]) else { return }
            // The AST source range already bounds this code block. Use that
            // range directly instead of searching the accumulated fence-line
            // set from the beginning of the document for every block.
            let sourceEndLine = codeBlock.range?.upperBound.line ?? line + 1
            let endLine = min(lines.count - 1, max(line, sourceEndLine - 1))
            var closingLine: TokenScanner.Line?
            if line < endLine {
                for index in (line + 1)...endLine {
                    let candidate = lines[index]
                    if isClosingFence(candidate, matching: opening) {
                        closingLine = candidate
                        break
                    }
                }
            }
            let bodyStart = lines[line].next
            let bodyEnd = closingLine?.start ?? bytes.count
            let closingMarker = closingLine.flatMap { delimiterRun(on: $0) }
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
            let start = max(lineStarts[line], range.lowerBound)
            let end = min(lines[line].end, max(start, range.upperBound))
            blocks.append(.init(kind: .rule, line: line,
                                marker: start..<end))
        }

        private func syntaxStart(on line: Int) -> Int {
            var start = lineStarts[line]
            while start < lines[line].end, bytes[start] == 0x20 || bytes[start] == 0x09 {
                start += 1
            }
            return start
        }

        /// Extract a delimiter run only after the AST has identified the code
        /// block. This recovers the exact source span; it does not decide
        /// whether a line opens or closes a block.
        private func delimiterRun(on line: TokenScanner.Line) -> Range<Int>? {
            var start = line.start
            while start < line.end, bytes[start] == 0x20 || bytes[start] == 0x09 {
                start += 1
            }
            guard start < line.end, bytes[start] == 0x60 || bytes[start] == 0x7E else { return nil }
            let delimiter = bytes[start]
            var end = start
            while end < line.end, bytes[end] == delimiter { end += 1 }
            guard end - start >= 3 else { return nil }
            return start..<end
        }

        private func isClosingFence(
            _ line: TokenScanner.Line,
            matching opening: Range<Int>?
        ) -> Bool {
            guard let opening, let closing = delimiterRun(on: line),
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
                  let lower = MarkdownSemantics.byteOffset(range.lowerBound, lineStarts: lineStarts, byteCount: bytes.count),
                  let upper = MarkdownSemantics.byteOffset(range.upperBound, lineStarts: lineStarts, byteCount: bytes.count),
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

        private func markAllLines(_ range: Range<Int>, into target: inout Set<Int>) {
            let start = max(0, lineIndex(ofByte: range.lowerBound) ?? 0)
            let endOffset = max(range.lowerBound, range.upperBound - 1)
            let end = min(lines.count - 1, max(start, lineIndex(ofByte: endOffset) ?? start))
            for line in start...end {
                target.insert(line)
            }
        }
    }

    private static func byteOffset(
        _ location: SourceLocation,
        lineStarts: [Int],
        byteCount: Int
    ) -> Int? {
        let line = location.line - 1
        guard line >= 0, line < lineStarts.count else { return nil }
        let offset = lineStarts[line] + max(0, location.column - 1)
        guard offset >= 0, offset <= byteCount else { return nil }
        return offset
    }

    /// 在语法区间内做字节级边界解析：`[`、平衡嵌套括号的标签、`](`、
    /// 平衡括号的目的地、收尾 `)`。reference 式链接 / 未闭合语法返回 nil。
    private static func parseBounds(_ syntax: Range<Int>, bytes: [UInt8]) -> LinkSyntax? {
        let end = min(syntax.upperBound, bytes.count)
        guard syntax.lowerBound < end, bytes[syntax.lowerBound] == 0x5B else { return nil }

        // 标签：支持嵌套括号 [a [b] c]
        var depth = 1
        var labelEnd = -1
        var i = syntax.lowerBound + 1
        while i < end {
            let b = bytes[i]
            if b == 0x5C { i += 2; continue }
            if b == 0x5B { depth += 1 }
            else if b == 0x5D {
                depth -= 1
                if depth == 0 { labelEnd = i; break }
            }
            i += 1
        }
        guard labelEnd >= 0, labelEnd + 2 < end, bytes[labelEnd + 1] == 0x28 else { return nil } // ](

        // 目的地：平衡括号（允许 URL 内含括号）
        var parenDepth = 1
        var j = labelEnd + 2
        while j < end {
            let b = bytes[j]
            if b == 0x5C { j += 2; continue }
            if b == 0x28 { parenDepth += 1 }
            else if b == 0x29 {
                parenDepth -= 1
                if parenDepth == 0 { break }
            }
            j += 1
        }
        guard j < end else { return nil }

        let open = syntax.lowerBound
        return LinkSyntax(
            openBracket: open..<(open + 1),
            label: (open + 1)..<labelEnd,
            tail: labelEnd..<(j + 1),
            destination: (labelEnd + 2)..<j
        )
    }
}
