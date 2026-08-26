import Foundation

/// 源码 token。所有范围均为 UTF-8 字节偏移（与 swift-markdown/cmark 同一坐标系），
/// 输出端经 SourceIndex 转成 UTF-16 NSRange 后才交给 AppKit。
/// nonisolated：token 在后台解析（v0.2 并发与性能）与主线程渲染之间传递。
nonisolated struct Token: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case unorderedListItem
        case orderedListItem
        case taskListItem(checked: Bool)
        case blockquote
        case codeFence
        case strong
        case emphasis
        case inlineCode
        case strikethrough
    }

    let kind: Kind
    /// 起始标记字符的字节区间（`**`、`# `、`- ` …）。
    let markerRange: Range<Int>
    /// 闭合标记区间，仅行内 token（`**`、`*`、`` ` ``、`~~` 的收尾分隔符）有值。
    let closingMarkerRange: Range<Int>?
    /// 内容区间。块级 token 为整行内容；行内 token 为两个分隔符之间。空 token 为 nil。
    let contentRange: Range<Int>?
    /// 所属行（0-based，按 \n 分隔）。
    let line: Int

    /// 两个标记区间的总览（块级只有一个）。
    var allMarkerRanges: [Range<Int>] {
        if let closingMarkerRange { return [markerRange, closingMarkerRange] }
        return [markerRange]
    }

    /// marker 是否属于块级（其显隐由"光标是否在本行"决定，而非选区相交）。
    var isBlockMarker: Bool {
        switch kind {
        case .heading, .unorderedListItem, .orderedListItem, .taskListItem, .blockquote, .codeFence:
            return true
        case .strong, .emphasis, .inlineCode, .strikethrough:
            return false
        }
    }
}
