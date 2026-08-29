import Foundation

/// GFM 表格的源码几何：单元格墨迹、结构区（`|` 与填充空白）、列对齐。
///
/// 只描述「源码里什么在哪」，不含任何排版度量——列宽要读字体，属于渲染层
/// （`TableLayout`）。本类型与 `MarkdownSemantics` 同层，同样不触碰 AppKit，
/// 可以跨线程随 `RenderEngine.Package` 传递。
///
/// 区间来源是 swift-markdown 的 `Table` AST：单元格区间直接取 `Table.Cell.range`
/// （cmark 的 column 是**字节**列，与本项目的字节坐标同源），`|` 的位置则在 AST
/// 已确认的单元格边界上按字节核对一次。这不是第二套表格解析——是把 AST 的判定
/// 还原成精确源码区间，与 `MarkdownSemantics.delimiterRun` 同一套做法。
public nonisolated struct TableStructure: Sendable, Equatable {
    /// 列对齐。GFM 未指定时按 leading。
    public enum ColumnAlignment: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    public struct Cell: Sendable, Equatable {
        /// 单元格源码区间，含 AST 计入的两侧填充空格（`| 功能 |` 的 `" 功能 "`）。
        public let content: Range<Int>
        /// 去掉两侧空白后的墨迹区间：列宽度量与列定位都以它为准。空格属于结构区，
        /// 渲染态会被折叠，不能算进列宽。
        public let ink: Range<Int>
        /// 本格墨迹之前的结构区：上一格的尾部空白 + `|` + 本格的头部空白。
        /// 渲染态整段折叠；列内边距挂在它的**首字符**上（见 `TableLayout`）。
        public let leadingGap: Range<Int>
        /// 紧跟在单元格右侧的 `|`；行尾省略 `|` 时为 nil。
        public let trailingPipe: Range<Int>?

        public init(
            content: Range<Int>,
            ink: Range<Int>,
            leadingGap: Range<Int>,
            trailingPipe: Range<Int>?
        ) {
            self.content = content
            self.ink = ink
            self.leadingGap = leadingGap
            self.trailingPipe = trailingPipe
        }
    }

    public struct Row: Sendable, Equatable {
        public let line: Int
        public let cells: [Cell]
        /// 末格墨迹之后的结构区（尾部空白 + 行尾的 `|`）。可能为空。
        public let trailingGap: Range<Int>

        public init(line: Int, cells: [Cell], trailingGap: Range<Int>) {
            self.line = line
            self.cells = cells
            self.trailingGap = trailingGap
        }

        /// 本行全部要折叠的结构区间。
        public var structuralRanges: [Range<Int>] {
            var result = cells.compactMap { $0.leadingGap.isEmpty ? nil : $0.leadingGap }
            if !trailingGap.isEmpty { result.append(trailingGap) }
            return result
        }
    }

    /// 表头行（0-based）。
    public let headerLine: Int
    /// 表格所在 Markdown 容器在每一行前面的源码前缀。
    ///
    /// 顶层表格为空；引用块里通常是 `"> "`，列表续行里通常是缩进空格。
    /// 结构化编辑重写整张表时必须把它重新写回，否则表格会从父容器中脱落。
    public let containerPrefix: String
    /// 分隔行（`|---|---|`）恒为表头行 +1，不参与 `rows`。
    public let delimiterLine: Int
    /// 表格末行（0-based）。
    public let lastLine: Int
    public let alignments: [ColumnAlignment]
    /// 表头行在前，随后是数据行；不含分隔行。
    public let rows: [Row]

    public init(
        headerLine: Int,
        containerPrefix: String = "",
        delimiterLine: Int,
        lastLine: Int,
        alignments: [ColumnAlignment],
        rows: [Row]
    ) {
        self.headerLine = headerLine
        self.containerPrefix = containerPrefix
        self.delimiterLine = delimiterLine
        self.lastLine = lastLine
        self.alignments = alignments
        self.rows = rows
    }

    /// 列数取各行的最大值（GFM 会把行补齐，这里防御性地再取一次上界）。
    public var columnCount: Int {
        rows.map(\.cells.count).max() ?? 0
    }

    public func alignment(column: Int) -> ColumnAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    /// 全部要折叠的结构区间（不含分隔行——分隔行整行已经是表格的 marker）。
    public var structuralRanges: [Range<Int>] {
        rows.flatMap(\.structuralRanges)
    }
}
