import Foundation

/// Markdown 源码的行索引适配器。
///
/// Markdown 的闭合语法与块结构统一由 `MarkdownSemantics` 的 swift-markdown AST
/// 提供；本类型只保留行边界计算。`scan` 为旧调用方保留兼容入口，返回的仍是同一
/// AST 产物，不再维护第二套 CommonMark 匹配器。未闭合语法不会出现在 AST token
/// 中，因此保持基础文字属性，让编辑中的源码标记自然可见。
public nonisolated struct TokenScanner {
    public struct Line {
        /// 本行内容 [start, end)，不含换行符；next 为下一行起点（= end + 换行宽度）。
        public let start: Int
        public let end: Int
        public let next: Int
        public let index: Int

        public init(start: Int, end: Int, next: Int, index: Int) {
            self.start = start
            self.end = end
            self.next = next
            self.index = index
        }
    }

    public init() {}

    /// 兼容旧 API：闭合 marker 与块结构全部来自 AST。
    ///
    /// 参数保留是为了不破坏增量管线的调用方；AST 已经拥有完整的上下文，旧的
    /// 排除区间与结构行提示不再参与第二次匹配。
    public func scan(
        _ source: String,
        excludingRanges: [Range<Int>] = [],
        semanticListLines: Set<Int> = [],
        semanticQuoteLines: Set<Int> = [],
        semanticFenceLines: Set<Int> = []
    ) -> [Token] {
        _ = (excludingRanges, semanticListLines, semanticQuoteLines, semanticFenceLines)
        return MarkdownSemantics(source).tokens
    }

    /// 每行字节区间，供渲染层计算光标所在行与 AST source location 的偏移。
    public func lines(_ source: String) -> [Line] {
        computeLines(Array(source.utf8))
    }

    /// 在同一份不可变快照上计算行边界，避免 AST 管线重复复制 UTF-8 缓冲区。
    nonisolated func lines(_ bytes: [UInt8]) -> [Line] {
        computeLines(bytes)
    }

    private func computeLines(_ bytes: [UInt8]) -> [Line] {
        var result: [Line] = []
        var start = 0
        var index = 0
        var offset = 0
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x0A:
                result.append(Line(start: start, end: offset, next: offset + 1, index: index))
                start = offset + 1
                index += 1
            case 0x0D where offset + 1 < bytes.count && bytes[offset + 1] == 0x0A:
                result.append(Line(start: start, end: offset, next: offset + 2, index: index))
                start = offset + 2
                index += 1
                offset += 1
            default:
                break
            }
            offset += 1
        }
        result.append(Line(start: start, end: bytes.count, next: bytes.count, index: index))
        return result
    }
}
