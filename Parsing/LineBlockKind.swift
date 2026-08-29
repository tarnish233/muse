import Foundation
import Markdown

/// 单行的块归属，供编辑层在渲染属性尚未落地时判断「这一行能不能续行」。
///
/// 判定直接交给项目已有的 swift-markdown（cmark-gfm），**不自己实现 CommonMark
/// 规则**——见 `TokenScanner` 文件头：「不再维护第二套 CommonMark 匹配器」。
/// 手写版曾经把 `- - -` 当成 bullet、把 4 空格缩进代码块当成列表。
public enum LineBlockKind: Sendable, Equatable {
    case list
    case heading
    /// 段落、分隔线、代码块、HTML 块等一切不该触发块续行的行。
    case other
}

extension MarkdownSemantics {
    /// 单独解析一行并报告它属于哪种块。
    ///
    /// 单行解析实测 14µs（p95 14.2µs），而 Enter 不是逐键热路径，所以这个代价
    /// 远低于自己维护一套行级 CommonMark 规则的正确性风险。
    ///
    /// 只对**行内局部**的判定可信：分隔线、缩进代码块、行首 marker 都是单行可判的。
    /// 围栏体则不是——一行 `- item` 单独看就是列表，是否落在围栏里必须由调用方
    /// 用块级信息（渲染属性）否决。
    public static func lineBlockKind(of line: String) -> LineBlockKind {
        kind(ofFirstChildOf: Document(parsing: line))
    }

    private static func kind(ofFirstChildOf container: some Markup) -> LineBlockKind {
        guard let first = container.child(at: 0) else { return .other }
        switch first {
        case is UnorderedList, is OrderedList:
            return .list
        case is Heading:
            return .heading
        case let quote as BlockQuote:
            // `> - item` 的第一层是引用；真正决定续行的是它包着的那个块。
            return kind(ofFirstChildOf: quote)
        default:
            // ThematicBreak / CodeBlock / HTMLBlock / Paragraph / Table…
            return .other
        }
    }
}
