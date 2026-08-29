import AppKit

/// 表格的排版度量：把 `TableStructure` 的源码几何变成「列边界」与「每个结构区
/// 要撑开多少」。
///
/// ## 为什么是 kern
///
/// 单元格必须落在同一列上，而源码里的列宽是按**字符个数**对齐的——中文、emoji、
/// ASCII 在任何字体下宽度都不成整数比，等宽字体也救不了（实测 `.monospacedSystemFont(13)`：
/// `M` 8.04pt、`中` 12.90pt、`🎉` 19.00pt，`中` 并不是 ASCII 的两倍）。既然不许改
/// 字符，就不能插制表符去用 `tabStops`；TextKit 2 也没有 TextKit 1 的字形替换钩子
/// （`NSGlyphProperty.elastic`），`NSTextTable` 更是只在 TextKit 1 下生效（实测：
/// 同一份带 `textBlocks` 的属性串，TK1 排成真表格，TK2 把 9 个单元格竖着摊开）。
/// 只剩「给某个字符的推进量加一个精确的点数」这条路，也就是 `.kern`。
///
/// ## kern 的半分裂（文档没写，实测得出）
///
/// 对索引 i 的字符加 kern K，**i 与 i+1 各分到 K/2**：
///
/// ```text
/// "X|abc|Y"  基线      : X=0  |=10.55  a=14.38  b=22.89  c=32.41
/// 在 index 1 加 kern 100: X=0  |=10.55  a=64.38  b=122.89 c=132.41
///                                        ↑ +50      ↑ +100
/// ```
///
/// 也就是说 i+1 只移动 K/2，i+2 之后才是整个 K。想把一段文字**整体**平移 K，
/// 承载字符必须落在这段文字前面**至少两个字符**处——中间那个字符会吃掉半个 K，
/// 所以它自己的落点不能有意义。
///
/// 表格恰好满足这个条件：`| 文字 |` 里「上一格尾部空白 + `|` + 本格头部空白」都是
/// 要折叠的结构字符，谁落在哪里都无所谓。承载字符取这段结构区的**首字符**，墨迹
/// 因此稳稳地在 i+2 之后。结构区不足 2 个字符的表格（`|a|b|` 这种完全不留空格的
/// 写法）无法整体平移，`isAlignable` 为 false，渲染层退回不画格线的保守呈现。
///
/// 表格结构字符在渲染模式下始终折叠；需要逐字查看时由文档级源码模式统一恢复。
nonisolated struct TableLayout {
    /// 一个结构区首字符的推进量补偿。
    struct Adjustment {
        let range: NSRange
        let kern: CGFloat
    }

    /// 列边界的 x 偏移，相对本行正文起点；含首尾，长度 = 列数 + 1。
    let columnBoundaries: [CGFloat]
    let adjustments: [Adjustment]
    /// 全部结构区都够放承载字符（能整体平移）时为 true。false 时调用方应退回
    /// 不画格线的保守呈现——半个 kern 会把某一格的头两个字符撑开，比不对齐更难看。
    let isAlignable: Bool

    var totalWidth: CGFloat { columnBoundaries.last ?? 0 }

    /// kern 的承载字符与它定位的墨迹之间至少要隔开的字符数。
    private static let carrierDistance = 2

    /// - Parameters:
    ///   - hiddenRanges: 单元格里会被折叠成近零宽的行内标记（如 `**`）。度量必须
    ///     排除它们，否则列宽按源码算会比实际渲染宽。
    ///   - headerFont/bodyFont: 表头与数据行的字体。单元格里嵌套的**粗体**会比按行
    ///     字体度量的结果略宽；左右各 `cellPadding` 的余量足以吸收，不为此再读一遍
    ///     已应用的属性（行内样式此刻还没落地）。
    static func compute(
        structure: TableStructure,
        source: NSString,
        index: SourceIndex,
        hiddenRanges: [Range<Int>],
        headerFont: NSFont,
        bodyFont: NSFont,
        measureText: ((NSString, Bool) -> CGFloat)? = nil,
        cellPadding: CGFloat = Theme.tableCellPaddingX
    ) -> TableLayout {
        let columnCount = structure.columnCount
        guard columnCount > 0 else {
            return TableLayout(columnBoundaries: [0], adjustments: [], isAlignable: false)
        }

        let sortedHidden = hiddenRanges.sorted { $0.lowerBound < $1.lowerBound }
        func font(forRow row: Int) -> NSFont { row == 0 ? headerFont : bodyFont }

        // 第一遍：量每一格的墨迹宽度（**只量一次**，度量要拼字符串又要过一次
        // 排版，重复量一遍在含大量表格的文档上是可观的开销），顺带求每列的上界。
        var inkWidths: [[CGFloat]] = []
        inkWidths.reserveCapacity(structure.rows.count)
        var maxInk = [CGFloat](repeating: 0, count: columnCount)
        for (rowIndex, row) in structure.rows.enumerated() {
            let rowFont = font(forRow: rowIndex)
            var widths = [CGFloat](repeating: 0, count: row.cells.count)
            for (column, cell) in row.cells.enumerated() where column < columnCount {
                let text = visibleText(of: cell.ink, source: source, index: index, hidden: sortedHidden)
                let width = measureText?(text, rowIndex == 0)
                    ?? text.size(withAttributes: [.font: rowFont]).width
                widths[column] = width
                maxInk[column] = max(maxInk[column], width)
            }
            inkWidths.append(widths)
        }
        var boundaries: [CGFloat] = [0]
        for ink in maxInk {
            boundaries.append(boundaries[boundaries.count - 1] + ink + cellPadding * 2)
        }

        // 第二遍：按行顺序推进，把每一格的墨迹推到目标 x。
        //
        // 结构字符折叠后推进量近零（0.1pt 字体），所以「墨迹的自然位置」就是它前面
        // 各格墨迹宽度之和；于是本格该补的量 = 目标 x − 当前累计推进。
        var adjustments: [Adjustment] = []
        adjustments.reserveCapacity(structure.rows.count * (columnCount + 1))
        var isAlignable = true

        for (rowIndex, row) in structure.rows.enumerated() {
            var x: CGFloat = 0
            for (column, cell) in row.cells.enumerated() where column < columnCount {
                let ink = inkWidths[rowIndex][column]
                let columnWidth = boundaries[column + 1] - boundaries[column]
                let target: CGFloat
                switch structure.alignment(column: column) {
                case .leading:
                    target = boundaries[column] + cellPadding
                case .trailing:
                    target = boundaries[column + 1] - cellPadding - ink
                case .center:
                    target = boundaries[column] + (columnWidth - ink) / 2
                }

                if let carrier = carrierRange(for: cell, index: index) {
                    adjustments.append(Adjustment(range: carrier, kern: target - x))
                    x = target + ink
                } else {
                    // 放不下承载字符：这一格按自然位置走，整张表退回保守呈现。
                    isAlignable = false
                    x += ink
                }
            }
            // 末列右侧的结构区补到表格右边界。竖线是绘制层照 `columnBoundaries`
            // 画的，不靠这一笔；补它是为了让这一行的推进宽度等于表格宽度，行尾
            // 光标落在表格右缘而不是紧贴最后一格的文字。
            if let carrier = carrierRange(forGap: row.trailingGap, index: index) {
                adjustments.append(Adjustment(range: carrier, kern: (boundaries.last ?? 0) - x))
            }
        }

        return TableLayout(
            columnBoundaries: boundaries,
            adjustments: adjustments,
            isAlignable: isAlignable
        )
    }

    /// 承载字符：结构区的首字符，且它与墨迹之间至少隔 `carrierDistance` 个字符。
    private static func carrierRange(
        for cell: TableStructure.Cell,
        index: SourceIndex
    ) -> NSRange? {
        // 结构字符全是 ASCII（`|`、空格、制表符），字节数就是 UTF-16 单元数，
        // 「隔几个字符」可以直接在字节坐标上判。
        guard cell.leadingGap.count >= carrierDistance else { return nil }
        return carrierRange(forGap: cell.leadingGap, index: index)
    }

    private static func carrierRange(
        forGap gap: Range<Int>,
        index: SourceIndex
    ) -> NSRange? {
        guard !gap.isEmpty else { return nil }
        let range = index.nsRange(gap.lowerBound..<(gap.lowerBound + 1))
        return range.length > 0 ? range : nil
    }

    /// 墨迹里真正会显示出来的文本：去掉被折叠的行内标记字节。
    private static func visibleText(
        of ink: Range<Int>,
        source: NSString,
        index: SourceIndex,
        hidden: [Range<Int>]
    ) -> NSString {
        guard !ink.isEmpty else { return "" }
        var pieces: [String] = []
        var cursor = ink.lowerBound
        var low = 0
        var high = hidden.count
        while low < high {
            let mid = (low + high) / 2
            if hidden[mid].upperBound <= ink.lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var hiddenIndex = low
        while hiddenIndex < hidden.count {
            let range = hidden[hiddenIndex]
            guard range.lowerBound < ink.upperBound else { break }
            let start = max(cursor, ink.lowerBound)
            let stop = min(range.lowerBound, ink.upperBound)
            if stop > start, let piece = substring(start..<stop, source: source, index: index) {
                pieces.append(piece)
            }
            cursor = max(cursor, range.upperBound)
            hiddenIndex += 1
        }
        if cursor < ink.upperBound,
           let piece = substring(cursor..<ink.upperBound, source: source, index: index) {
            pieces.append(piece)
        }
        return pieces.joined() as NSString
    }

    private static func substring(
        _ byteRange: Range<Int>,
        source: NSString,
        index: SourceIndex
    ) -> String? {
        let range = index.nsRange(byteRange)
        guard range.location >= 0, range.length > 0,
              range.location + range.length <= source.length else { return nil }
        return source.substring(with: range)
    }
}
