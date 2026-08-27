import Foundation

/// 源码 token。所有范围均为 UTF-8 字节偏移（与 swift-markdown/cmark 同一坐标系），
/// 输出端经 SourceIndex 转成 UTF-16 NSRange 后才交给 AppKit。
/// nonisolated：token 在后台解析（v0.2 并发与性能）与主线程渲染之间传递。
public nonisolated struct Token: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case unorderedListItem(depth: Int)
        case orderedListItem(depth: Int, number: Int)
        case taskListItem(depth: Int, checked: Bool)
        case blockquote(depth: Int)
        case codeFence
        case strong
        case emphasis
        case inlineCode
        case strikethrough
        case link
        case rule
    }

    public let kind: Kind
    /// 起始标记字符的字节区间（`**`、`# `、`- ` …）。
    public let markerRange: Range<Int>
    /// 闭合标记区间，仅行内 token（`**`、`*`、`` ` ``、`~~` 的收尾分隔符）有值。
    /// 链接的闭合标记为 `](` 到 `)` 的整段（隐藏目的地）。
    public let closingMarkerRange: Range<Int>?
    /// 内容区间。块级 token 为整行内容；行内 token 为两个分隔符之间。空 token 为 nil。
    public let contentRange: Range<Int>?
    /// 链接目的地字节区间（仅 .link）。
    public var linkDestination: Range<Int>? = nil
    /// 所属行（0-based，按 \n 分隔）。
    public let line: Int

    public init(
        kind: Kind,
        markerRange: Range<Int>,
        closingMarkerRange: Range<Int>? = nil,
        contentRange: Range<Int>? = nil,
        linkDestination: Range<Int>? = nil,
        line: Int
    ) {
        self.kind = kind
        self.markerRange = markerRange
        self.closingMarkerRange = closingMarkerRange
        self.contentRange = contentRange
        self.linkDestination = linkDestination
        self.line = line
    }

    /// 两个标记区间的总览（块级只有一个）。
    public var allMarkerRanges: [Range<Int>] {
        if let closingMarkerRange { return [markerRange, closingMarkerRange] }
        return [markerRange]
    }

    /// marker 是否属于块级（其显隐由"光标是否在本行/块内"决定，而非选区相交）。
    public var isBlockMarker: Bool {
        switch kind {
        case .heading, .unorderedListItem, .orderedListItem, .taskListItem, .blockquote, .codeFence, .rule:
            return true
        case .strong, .emphasis, .inlineCode, .strikethrough, .link:
            return false
        }
    }
}
