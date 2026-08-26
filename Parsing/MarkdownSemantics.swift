import Foundation
import Markdown

/// swift-markdown 语义层（v0.2 §4.1）：AST 回答"这段内容是什么"，
/// TokenScanner 回答"精确的标记字符在哪"。在后台解析任务中构建，
/// 只提取 Sendable 的纯值信息；本层不触碰 AppKit/存储。
nonisolated struct MarkdownSemantics: Sendable {
    /// 行级块分类（0-based 行号），供差异测试与后续增量渲染使用。
    struct LineKind: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case heading(Int)  // ATX 级别
            case quote
            case list
            case fence        // 围栏体内（含开/闭栏行）
        }

        let line: Int
        let kind: Kind
    }

    /// 行内链接语法定位（均为 UTF-8 字节偏移）。
    struct LinkSyntax: Sendable, Equatable {
        /// `[`（单字节）
        let openBracket: Range<Int>
        /// 标签内容
        let label: Range<Int>
        /// `]` 到 `)` 的整段（标记隐藏时连同目的地一起隐藏）
        let tail: Range<Int>
        /// 目的地（tail 内部）
        let destination: Range<Int>
        /// 行内扫描的保护区间（tail）——强调分隔符不进入 URL 区域配对
        var inertRanges: [Range<Int>] { [tail] }
    }

    let lineKinds: [LineKind]
    let links: [LinkSyntax]

    init(_ source: String) {
        let bytes = Array(source.utf8)
        let lineStarts = TokenScanner().lines(source).map(\.start)
        let document = Document(parsing: source)

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

        // 行内链接：AST 只提供"这里有个 Link + 整段语法区间"，
        // 边界（嵌套括号标签、`](`、平衡括号目的地）做字节级解析。
        var linkRanges: [Range<Int>] = []
        Self.collectLinkRanges(document, bytes: bytes, lineStarts: lineStarts, into: &linkRanges)
        let parsed = linkRanges.compactMap { Self.parseBounds($0, bytes: bytes) }

        self.lineKinds = lineKinds
        self.links = parsed
    }

    // MARK: - 链接收集

    private static func collectLinkRanges(
        _ markup: Markup,
        bytes: [UInt8],
        lineStarts: [Int],
        into ranges: inout [Range<Int>]
    ) {
        // Image 是独立的 Markup 类型，不会落入 Link 分支（图片语法 M5 处理）。
        if let link = markup as? Link, link.destination != nil, let range = link.range {
            let lower = lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1
            let upper = lineStarts[range.upperBound.line - 1] + range.upperBound.column - 1
            ranges.append(lower..<upper)
        }
        for child in markup.children {
            collectLinkRanges(child, bytes: bytes, lineStarts: lineStarts, into: &ranges)
        }
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
