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
        /// GFM 表格（只读）：marker 是分隔行整行（随块内光标显隐）。
        case table(lastLine: Int)
        case strong
        case emphasis
        case inlineCode
        case strikethrough
        case link
        case image
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
    /// 追加的标记区间，与 `markerRange` 同步显隐。
    ///
    /// 目前只有表格用它承载行内的 `|`：表格的主 marker 是分隔行，而管线符散布在
    /// 每一行，个数随列数变化，装不进固定的「开 + 闭」两个区间里。
    public let extraMarkerRanges: [Range<Int>]
    /// 图片语法是否独占一行（仅 .image）。
    ///
    /// 独占一行的图片按「块图片」呈现：整段折叠、行高撑成图片高度。夹在正文里的
    /// 图片保持语法呈现——判定在 AST 层做一次，渲染层与显隐层读同一个答案。
    public let isBlockImage: Bool
    /// 所属行（0-based，按 \n 分隔）。
    public let line: Int

    public init(
        kind: Kind,
        markerRange: Range<Int>,
        closingMarkerRange: Range<Int>? = nil,
        contentRange: Range<Int>? = nil,
        linkDestination: Range<Int>? = nil,
        extraMarkerRanges: [Range<Int>] = [],
        isBlockImage: Bool = false,
        line: Int
    ) {
        self.kind = kind
        self.markerRange = markerRange
        self.closingMarkerRange = closingMarkerRange
        self.contentRange = contentRange
        self.linkDestination = linkDestination
        self.extraMarkerRanges = extraMarkerRanges
        self.isBlockImage = isBlockImage
        self.line = line
    }

    /// 实际源码覆盖范围。跨 soft line break 的行内 token 不能只依赖起始行。
    public var sourceRange: Range<Int> {
        var lower = markerRange.lowerBound
        var upper = markerRange.upperBound
        let ranges = [contentRange, closingMarkerRange, linkDestination].compactMap { $0 }
            + extraMarkerRanges
        for range in ranges {
            lower = min(lower, range.lowerBound)
            upper = max(upper, range.upperBound)
        }
        return lower..<upper
    }

    /// 全部标记区间（块级通常只有一个；表格另带每行的 `|`）。
    public var allMarkerRanges: [Range<Int>] {
        var result = [markerRange]
        if let closingMarkerRange { result.append(closingMarkerRange) }
        result.append(contentsOf: extraMarkerRanges)
        return result
    }

    /// marker 显隐作用的区间。
    ///
    /// 块图片整段折叠——图由绘制层画在撑高的行里，源码一个字符都不该露出来。
    ///
    /// 夹在正文里的图片**什么都不折叠**：这一段不会被撑高去放图，所以图根本没画
    /// 出来，折叠掉一半语法只会留下 `![标签` 这种看起来像打错字的残句。整段源码
    /// 保留、由样式层弱化成 marker 色，读者一眼能认出「这里引用了一张图」，也能
    /// 直接改路径；点击仍然弹预览。
    public var markerVisibilityRanges: [Range<Int>] {
        if let inline = inlineImageRange { return [inline] }
        if case .image = kind { return [] }
        return allMarkerRanges
    }

    /// 块图片的整段区间（`![标签](目的地)`）。非块图片为 nil。
    public var inlineImageRange: Range<Int>? {
        guard case .image = kind, isBlockImage else { return nil }
        let end = closingMarkerRange?.upperBound ?? markerRange.upperBound
        return markerRange.lowerBound..<end
    }

    /// marker 是否属于块级（其显隐由"光标是否在本行/块内"决定，而非选区相交）。
    public var isBlockMarker: Bool {
        switch kind {
        case .heading, .unorderedListItem, .orderedListItem, .taskListItem, .blockquote, .codeFence, .table, .rule:
            return true
        case .strong, .emphasis, .inlineCode, .strikethrough, .link, .image:
            return false
        }
    }

    /// Semantic list depth for block-list markers. Inline markers inside a
    /// list deliberately return nil so their reveal state cannot alter the
    /// paragraph's hanging-indent geometry.
    public var listDepth: Int? {
        switch kind {
        case let .unorderedListItem(depth),
             let .orderedListItem(depth, _),
             let .taskListItem(depth, _):
            return depth
        default:
            return nil
        }
    }
}
