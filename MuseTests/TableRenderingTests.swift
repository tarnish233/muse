import AppKit
import CoreText
import Testing
@testable import MuseKit

/// 表格呈现的契约：列真的对齐、格线属性写对、无法对齐时诚实退回。
///
/// 列对齐用 Core Text 量**渲染后**的字形位置，而不是断言 kern 的数值——
/// kern 的语义（对索引 i 加 K，i 与 i+1 各分到 K/2）文档没写、是实测出来的，
/// 断言中间量等于把当时的理解也一起钉死；断言「同一列的墨迹落在同一个 x」
/// 才是真正要的性质，换实现也依然成立。
@Suite @MainActor struct TableRenderingTests {
    let engine = RenderEngine()
    let theme = Theme.standard

    /// 各行同一列的墨迹起点 x（按渲染后的属性度量）。
    ///
    /// 用 `CTLineGetOffsetForStringIndex` 而不是自己累加字宽：kern、折叠成 0.1pt
    /// 的结构字符、CJK 的字体回退都会影响推进量，只有让 Core Text 自己排一遍
    /// 才是真实位置。
    private func inkOrigins(
        source: String,
        storage: NSTextStorage,
        structure: TableStructure,
        index: SourceIndex
    ) -> [[CGFloat]] {
        structure.rows.map { row in
            let lineStartUTF16 = index.utf16Offset(row.cells[0].leadingGap.lowerBound)
            let lineRange = (storage.string as NSString).paragraphRange(
                for: NSRange(location: lineStartUTF16, length: 0)
            )
            let line = CTLineCreateWithAttributedString(storage.attributedSubstring(from: lineRange))
            return row.cells.map { cell in
                let inkUTF16 = index.utf16Offset(cell.ink.lowerBound) - lineRange.location
                return CTLineGetOffsetForStringIndex(line, inkUTF16, nil)
            }
        }
    }

    private func render(_ source: String) -> (NSTextStorage, RenderEngine.Package) {
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        return (storage, package)
    }

    /// 核心性质：左对齐列的墨迹在每一行都落在同一个 x —— 哪怕单元格里混着
    /// 中文、ASCII 和 emoji。源码里字符个数相同并不代表宽度相同（实测等宽字体
    /// 下 `中` 也不是 ASCII 的两倍宽），这正是「表格看起来没渲染」的根因。
    @Test func leadingAlignedColumnsShareOneOrigin() throws {
        let source = """
        | 功能 | 状态 | 说明 |
        |---|---|---|
        | 即时渲染 | ok | 属性层 + 绘制层 |
        | ab | 🎉 | d |
        | 表格 | x | 中英 mixed 混排 |
        """
        let (storage, package) = render(source)
        let structure = try #require(package.tables.first)
        let origins = inkOrigins(source: source, storage: storage, structure: structure, index: package.index)
        #expect(origins.count == 4)

        for column in 0..<structure.columnCount {
            let xs = origins.map { $0[column] }
            let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
            #expect(spread < 1.0, "第 \(column) 列未对齐：\(xs)")
        }
        // 列必须真的分开，不是全部塌在 0（那样「对齐」是假绿）。
        let firstRow = origins[0]
        for column in 1..<firstRow.count {
            #expect(firstRow[column] - firstRow[column - 1] > 20, "列宽塌缩：\(firstRow)")
        }
    }

    /// 居中与右对齐按列生效：右对齐列的墨迹**末端**对齐，居中列两侧余量相等。
    @Test func centerAndTrailingAlignmentsAreHonored() throws {
        let source = """
        | a | b | c |
        |---|:---:|---:|
        | 即时渲染 | 长一些的内容 | 长一些的内容 |
        | x | y | y |
        """
        let (storage, package) = render(source)
        let structure = try #require(package.tables.first)
        let origins = inkOrigins(source: source, storage: storage, structure: structure, index: package.index)
        let boundaries = try #require(
            storage.attribute(.museTableColumns, at: 0, effectiveRange: nil) as? [NSNumber]
        ).map { CGFloat($0.doubleValue) }
        #expect(boundaries.count == 4)

        func inkWidth(row: Int, column: Int) -> CGFloat {
            let cell = structure.rows[row].cells[column]
            let range = package.index.nsRange(cell.ink)
            return storage.attributedSubstring(from: range).size().width
        }

        // 右对齐（第 2 列）：墨迹末端到列右边界的距离在每一行都相同。
        let trailingGaps = (0..<structure.rows.count).map { row in
            boundaries[3] - (origins[row][2] + inkWidth(row: row, column: 2))
        }
        #expect((trailingGaps.max() ?? 0) - (trailingGaps.min() ?? 0) < 1.0,
                "右对齐列的末端未对齐：\(trailingGaps)")

        // 居中（第 1 列）：左右余量相等。
        for row in 0..<structure.rows.count {
            let left = origins[row][1] - boundaries[1]
            let right = boundaries[2] - (origins[row][1] + inkWidth(row: row, column: 1))
            #expect(abs(left - right) < 1.5, "第 \(row) 行未居中：left \(left) right \(right)")
        }
    }

    /// 绘制层要的属性：列边界、行序号、块角色。缺一样格线就画不出来。
    @Test func rowsCarryGridAttributes() throws {
        let source = "| a | b |\n|---|---|\n| c | d |\n| e | f |"
        let (storage, package) = render(source)
        let structure = try #require(package.tables.first)

        for (rowIndex, row) in structure.rows.enumerated() {
            let location = package.index.utf16Offset(row.cells[0].ink.lowerBound)
            #expect(storage.attribute(.museBlock, at: location, effectiveRange: nil) as? String
                    == BlockVisual.table.rawValue)
            #expect((storage.attribute(.museTableRow, at: location, effectiveRange: nil) as? NSNumber)?.intValue
                    == rowIndex)
            let boundaries = storage.attribute(.museTableColumns, at: location, effectiveRange: nil) as? [NSNumber]
            #expect(boundaries?.count == structure.columnCount + 1)
        }
        let headLocation = package.index.utf16Offset(structure.rows[0].cells[0].ink.lowerBound)
        #expect(storage.attribute(.museBlockRole, at: headLocation, effectiveRange: nil) as? String == "head")
        let lastLocation = package.index.utf16Offset(
            structure.rows[structure.rows.count - 1].cells[0].ink.lowerBound
        )
        #expect(storage.attribute(.museBlockRole, at: lastLocation, effectiveRange: nil) as? String == "close")
    }

    /// 表头加粗、单元格用正文字体（表格不是代码，不该是等宽）。
    @Test func headerIsBoldAndCellsUseBodyFont() throws {
        let source = "| head | x |\n|---|---|\n| body | y |"
        let (storage, package) = render(source)
        let structure = try #require(package.tables.first)

        let headFont = storage.attribute(
            .font,
            at: package.index.utf16Offset(structure.rows[0].cells[0].ink.lowerBound),
            effectiveRange: nil
        ) as? NSFont
        let bodyFont = storage.attribute(
            .font,
            at: package.index.utf16Offset(structure.rows[1].cells[0].ink.lowerBound),
            effectiveRange: nil
        ) as? NSFont
        #expect(headFont == theme.boldFont())
        #expect(bodyFont == theme.baseFont())
        #expect(bodyFont?.isFixedPitch == false)
    }

    /// 结构区（`|` 与单元格填充空白）在渲染态全部折叠：看到的是格线，不是源码。
    @Test func structuralCharactersAreCollapsed() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let (storage, package) = render(source)
        let structure = try #require(package.tables.first)

        for range in structure.structuralRanges {
            let ns = package.index.nsRange(range)
            for offset in 0..<ns.length {
                let font = storage.attribute(.font, at: ns.location + offset, effectiveRange: nil) as? NSFont
                #expect((font?.pointSize ?? 100) < 1,
                        "结构字符 \(ns.location + offset) 未折叠")
            }
        }
        #expect(storage.string == source)
    }

    /// 分隔行必须塌成零高度：给它固定行高会在表头与首行数据之间留一条空行。
    @Test func delimiterRowCollapsesToZeroHeight() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let (storage, package) = render(source)
        let structure = try #require(package.tables.first)
        let location = package.index.utf16Offset(package.lineStarts[structure.delimiterLine])

        let paragraph = try #require(
            storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(paragraph.minimumLineHeight == 0, "分隔行不能带最小行高")
        #expect(storage.attribute(.museBlockRole, at: location, effectiveRange: nil) as? String == "delimiter")
        #expect(isHidden(location, in: storage))
    }

    /// 数据行的行高必须比正文行高，且上下内边距分开撑——TextKit 把行高的增量全部
    /// 加在基线之上，只用 minimumLineHeight 会让文字贴着单元格底边。
    @Test func rowGeometrySplitsPaddingAboveAndBelow() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let (storage, package) = render(source)
        let structure = try #require(package.tables.first)
        let location = package.index.utf16Offset(structure.rows[1].cells[0].ink.lowerBound)
        let paragraph = try #require(
            storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        )

        let font = theme.baseFont()
        let natural = font.ascender - font.descender + font.leading
        #expect(paragraph.minimumLineHeight == natural + Theme.tableCellPaddingY)
        #expect(paragraph.paragraphSpacing >= Theme.tableCellPaddingY)
        #expect(paragraph.maximumLineHeight == 0, "钳住最大行高会切掉 emoji")
        #expect(paragraph.lineBreakMode == .byClipping, "软换行会让格线与文字错位")
    }

    /// 完全不留空格的写法（`|a|b|`）放不下 kern 的承载字符：诚实退回不画格线的
    /// 呈现，而不是硬画一个和文字错位的表格。
    @Test func unalignableTableFallsBackWithoutGrid() throws {
        let source = "|a|b|\n|---|---|\n|c|d|"
        let (storage, package) = render(source)
        #expect(package.tables.first != nil, "AST 仍应认出这是表格")

        #expect(storage.attribute(.museBlock, at: 1, effectiveRange: nil) as? String
                == BlockVisual.table.rawValue)
        #expect(storage.attribute(.museTableColumns, at: 1, effectiveRange: nil) == nil,
                "对不齐就不该写列边界，否则绘制层会画出错位的格线")
        #expect(storage.attribute(.kern, at: 1, effectiveRange: nil) == nil)
        #expect(storage.string == source)
    }

    /// 单元格里的行内标记（`**`）会被折叠，列宽必须按折叠后的宽度算——
    /// 否则带粗体的那一列会比看起来需要的宽出两个星号。
    @Test func hiddenInlineMarkersDoNotInflateColumnWidth() throws {
        let plain = "| aaaa | b |\n|---|---|\n| c | d |"
        let bold = "| **aaaa** | b |\n|---|---|\n| c | d |"

        func firstColumnWidth(_ source: String) throws -> CGFloat {
            let (storage, _) = render(source)
            let boundaries = try #require(
                storage.attribute(.museTableColumns, at: 1, effectiveRange: nil) as? [NSNumber]
            )
            return CGFloat(boundaries[1].doubleValue)
        }

        // 粗体比常规略宽是正常的；宽出两个星号（约 10pt）就是把折叠区算进去了。
        let difference = try firstColumnWidth(bold) - firstColumnWidth(plain)
        #expect(difference < 6, "列宽把折叠掉的 ** 也算进去了：多了 \(difference)pt")
    }

    /// 光标进入表格：结构区回显源码。列仍然对齐——每行的结构字符个数相同，
    /// 各列同步位移。
    @Test func caretInsideTableRevealsSource() throws {
        let source = "| 功能 | 状态 |\n|---|---|\n| 即时渲染 | ok |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let structure = try #require(package.tables.first)
        let caret = package.index.utf16Offset(structure.rows[0].cells[0].ink.lowerBound)
        _ = engine.render(package: package, selection: NSRange(location: caret, length: 0), into: storage)

        for range in structure.structuralRanges {
            let ns = package.index.nsRange(range)
            let font = storage.attribute(.font, at: ns.location, effectiveRange: nil) as? NSFont
            #expect((font?.pointSize ?? 0) > 1, "回显时结构字符应可见")
        }
        let origins = inkOrigins(source: source, storage: storage, structure: structure, index: package.index)
        for column in 0..<structure.columnCount {
            let xs = origins.map { $0[column] }
            #expect((xs.max() ?? 0) - (xs.min() ?? 0) < 1.0, "回显后第 \(column) 列错位：\(xs)")
        }
        #expect(storage.string == source)
    }

    /// 边界形状：空单元格、少一格的行、只有表头没有数据行。
    /// 这些都是真实文档里会出现的写法，不能崩也不能把列宽算成负数。
    @Test(arguments: [
        "| a |  | c |\n|---|---|---|\n| 1 | 2 | 3 |",          // 空单元格
        "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 |",  // 少一格的行（GFM 会补齐）
        "| a | b |\n|---|---|",                                // 只有表头
        "| a | b |\n|---|---|\n|  |  |",                       // 整行空
    ])
    func degenerateTableShapesStayConsistent(source: String) throws {
        let (storage, package) = render(source)
        #expect(storage.string == source)
        let structure = try #require(package.tables.first)

        // 列边界必须单调递增（负列宽会让格线画反）。
        let location = package.index.utf16Offset(package.lineStarts[structure.headerLine])
        if let boundaries = storage.attribute(.museTableColumns, at: location, effectiveRange: nil) as? [NSNumber] {
            let values = boundaries.map { $0.doubleValue }
            for index in 1..<values.count {
                #expect(values[index] > values[index - 1], "列边界不单调：\(values)")
            }
        }
        // 结构区不重叠（重叠会让同一个字符被写两次 kern，内边距翻倍）。
        let ranges = structure.structuralRanges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<max(ranges.count, 1) where index < ranges.count {
            #expect(ranges[index].lowerBound >= ranges[index - 1].upperBound,
                    "结构区重叠：\(ranges[index - 1]) 与 \(ranges[index])")
        }
    }

    private func isHidden(_ location: Int, in storage: NSTextStorage) -> Bool {
        ((storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 100) < 1
    }
}
