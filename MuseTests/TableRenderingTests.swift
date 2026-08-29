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

    /// 光标进入表格仍直接编辑可视单元格，不把整块 Markdown 结构摊开。
    @Test func caretInsideTableKeepsStructureHidden() throws {
        let source = "| 功能 | 状态 |\n|---|---|\n| 即时渲染 | ok |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let structure = try #require(package.tables.first)
        let caret = package.index.utf16Offset(structure.rows[0].cells[0].ink.lowerBound)
        _ = engine.render(package: package, selection: NSRange(location: caret, length: 0), into: storage)

        for range in structure.structuralRanges {
            let ns = package.index.nsRange(range)
            let font = storage.attribute(.font, at: ns.location, effectiveRange: nil) as? NSFont
            #expect((font?.pointSize ?? 100) < 1, "可视化编辑时结构字符应保持隐藏")
        }
        let origins = inkOrigins(source: source, storage: storage, structure: structure, index: package.index)
        for column in 0..<structure.columnCount {
            let xs = origins.map { $0[column] }
            #expect((xs.max() ?? 0) - (xs.min() ?? 0) < 1.0, "编辑时第 \(column) 列错位：\(xs)")
        }
        #expect(storage.string == source)
    }

    @Test func tableTabSelectsNextCellAndBacktabReturns() throws {
        let source = "| 姓名 | 状态 |\n|---|---|\n| Muse | ok |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let table = try #require(package.tables.first)
        _ = engine.render(package: package, selection: nil, into: storage)

        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        textView.tableNavigationHandler = { coordinator.navigateTable(backward: $0) }

        let first = package.index.nsRange(table.rows[0].cells[0].ink)
        let second = package.index.nsRange(table.rows[0].cells[1].ink)
        textView.setSelectedRange(NSRange(location: first.location, length: 0))
        textView.insertTab(nil)
        #expect(textView.selectedRange() == second)

        textView.insertBacktab(nil)
        #expect(textView.selectedRange() == first)
        #expect(storage.string == source)
    }

    @Test func tabFromLastCellAppendsRowAndKeepsMarkdownBacking() throws {
        let source = "| 姓名 | 状态 |\n|---|---|\n| Muse | ok |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let table = try #require(package.tables.first)
        _ = engine.render(package: package, selection: nil, into: storage)

        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        textView.tableNavigationHandler = { coordinator.navigateTable(backward: $0) }

        let last = package.index.nsRange(try #require(table.rows.last?.cells.last?.ink))
        textView.setSelectedRange(last)
        textView.insertTab(nil)

        #expect(storage.string == source + "\n|  |  |")
        #expect(textView.selectedRange() == NSRange(location: (source as NSString).length + 3, length: 0))
        let generated = NSRange(location: (source as NSString).length + 1, length: 7)
        for location in generated.location..<NSMaxRange(generated) {
            #expect(isHidden(location, in: storage), "新增行在解析落地前不应闪出 Markdown 源码")
        }
        #expect(storage.attribute(.museBlock, at: generated.location, effectiveRange: nil) as? String
                == BlockVisual.table.rawValue)
    }

    @Test func returnFromLastCellAppendsRenderedRow() throws {
        let source = "| 姓名 | 状态 |\n|---|---|\n| Muse | ok |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let table = try #require(package.tables.first)
        _ = engine.render(package: package, selection: nil, into: storage)

        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        textView.tableReturnHandler = { coordinator.insertTableRowOnReturn() }

        let last = package.index.nsRange(try #require(table.rows.last?.cells.last?.ink))
        textView.setSelectedRange(last)
        textView.insertNewline(nil)

        #expect(storage.string == source + "\n|  |  |")
        #expect(textView.selectedRange() == NSRange(location: (source as NSString).length + 6, length: 0))
        let generated = NSRange(location: (source as NSString).length + 1, length: 7)
        for location in generated.location..<NSMaxRange(generated) {
            #expect(isHidden(location, in: storage), "Return 新增行应立即保持网格呈现")
        }
        let typingFont = textView.typingAttributes[.font] as? NSFont
        #expect((typingFont?.pointSize ?? 0) >= 1, "新增行首字必须立即可见")
    }

    @Test(arguments: [0, 1, 2])
    func returnFromAnyLastRowColumnAppendsAtSameColumn(column: Int) throws {
        let source = "| 功能 | 状态 | 说明 |\n|---|---|---|\n| 图片 | ✅ | 行内呈现 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let table = try #require(package.tables.first)
        _ = engine.render(package: package, selection: nil, into: storage)

        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        textView.tableReturnHandler = { coordinator.insertTableRowOnReturn() }

        let cell = try #require(table.rows.last?.cells[column])
        let ink = package.index.nsRange(cell.ink)
        let caret = NSRange(location: ink.location + min(1, ink.length), length: 0)
        textView.setSelectedRange(caret)
        textView.insertNewline(nil)

        let row = "|  |  |  |"
        #expect(storage.string == source + "\n" + row,
                "最后一行第 \(column + 1) 列回车不应拆开 Markdown 表格行")
        let rowStart = (source as NSString).length + 1
        #expect(textView.selectedRange() == NSRange(
            location: rowStart + 2 + column * 3,
            length: 0
        ), "新增行后应停在同一列")
        for location in rowStart..<(rowStart + (row as NSString).length) {
            #expect(isHidden(location, in: storage), "新增行不应短暂显示 Markdown 源码")
        }
    }

    @Test(arguments: [0, 1, 2])
    func returnBeforeLastRowMovesDownSameColumnWithoutEditing(column: Int) throws {
        let source = "| 功能 | 状态 | 说明 |\n|---|---|---|\n| 表格 | ✅ | 网格 |\n| 图片 | ✅ | 行内呈现 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let table = try #require(package.tables.first)
        _ = engine.render(package: package, selection: nil, into: storage)

        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        textView.tableReturnHandler = { coordinator.insertTableRowOnReturn() }

        let current = package.index.nsRange(table.rows[1].cells[column].ink)
        let expected = package.index.nsRange(table.rows[2].cells[column].ink)
        textView.setSelectedRange(NSRange(location: current.location, length: 0))
        textView.insertNewline(nil)

        #expect(storage.string == source, "非末行回车只负责纵向导航，不应改写 Markdown")
        #expect(textView.selectedRange() == expected, "回车应选中下一行的同列单元格")
    }

    @Test func arrowKeysCrossCellBoundariesWithoutEditingMarkdown() throws {
        let source = "| 功能 | 状态 | 说明 |\n|---|---|---|\n| 表格 | ✅ | 网格 |\n| 图片 | ✅ | 行内呈现 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let table = try #require(package.tables.first)
        _ = engine.render(package: package, selection: nil, into: storage)

        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        textView.tableArrowHandler = { coordinator.navigateTable(arrow: $0) }

        let first = package.index.nsRange(table.rows[1].cells[0].ink)
        let second = package.index.nsRange(table.rows[1].cells[1].ink)
        let belowSecond = package.index.nsRange(table.rows[2].cells[1].ink)

        textView.setSelectedRange(NSRange(location: NSMaxRange(first), length: 0))
        textView.moveRight(nil)
        #expect(textView.selectedRange() == NSRange(location: second.location, length: 0),
                "右方向键到达格尾后应进入下一格开头")

        textView.moveLeft(nil)
        #expect(textView.selectedRange() == NSRange(location: NSMaxRange(first), length: 0),
                "左方向键到达格首后应回到上一格末尾")

        textView.setSelectedRange(NSRange(location: second.location, length: 0))
        textView.moveDown(nil)
        #expect(textView.selectedRange() == NSRange(location: belowSecond.location, length: 0),
                "下方向键应进入下一行同列")

        textView.moveUp(nil)
        #expect(textView.selectedRange() == NSRange(location: second.location, length: 0),
                "上方向键应返回上一行同列")
        #expect(storage.string == source, "方向键导航不应改写 Markdown")
    }

    @Test(arguments: [0, 1, 2])
    func appendedBlankRowKeepsDelimitersHiddenAfterPipelineRender(column: Int) async throws {
        let source = "| 功能 | 状态 | 说明 |\n|---|---|---|\n| 图片 | ✅ | 行内呈现 |"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.onTextEdited = {}

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        let firstDeadline = ContinuousClock.now + .seconds(10)
        while coordinator.appliedRevision < 1, ContinuousClock.now < firstDeadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(coordinator.appliedRevision >= 1)

        let package = try #require(coordinator.lastPackage)
        let table = try #require(package.tables.first)
        let cell = try #require(table.rows.last?.cells[column])
        let ink = package.index.nsRange(cell.ink)
        textView.setSelectedRange(NSRange(location: ink.location + min(1, ink.length), length: 0))
        textView.tableReturnHandler = { coordinator.insertTableRowOnReturn() }
        textView.insertNewline(nil)

        let secondDeadline = ContinuousClock.now + .seconds(10)
        while coordinator.appliedRevision < 2, ContinuousClock.now < secondDeadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(coordinator.appliedRevision >= 2)

        let rowStart = (source as NSString).length + 1
        for offset in [0, 3, 6, 9] {
            let location = rowStart + offset
            #expect(isHidden(location, in: storage),
                    "后台渲染完成后，第 \(offset / 3 + 1) 个表格分隔符仍应不可见")
            #expect((storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
                    == NSColor.clear)
        }
        #expect(textView.selectedRange() == NSRange(
            location: rowStart + 2 + column * 3,
            length: 0
        ), "后台渲染后仍应停在新增行的同一列")
    }

    @Test func thirdColumnSelectionRectStaysInsideTable() throws {
        let source = """
        | 功能 | 状态 | 说明 |
        |---|---|---|
        | 即时渲染 | ✅ | 属性层 + 绘制层 |
        | 表格 | ✅ | 列宽实测对齐，绘制层画网格 |
        | 图片 | ✅ | 独占一行时行内呈现 |
        """
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        let table = try #require(package.tables.first)
        _ = engine.render(package: package, selection: nil, into: storage)
        let selection = package.index.nsRange(table.rows[2].cells[2].ink)
        storage.addAttribute(.museTableSelection, value: true, range: selection)

        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 1200, height: 500)
        textView.textContainer?.containerSize = NSSize(
            width: 1200,
            height: CGFloat.greatestFiniteMagnitude
        )
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        var target: MuseLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MuseLayoutFragment,
                  fragment.blockKind == BlockVisual.table.rawValue,
                  fragment.tableRowIndex == 2
            else { return true }
            target = fragment
            return false
        }
        let fragment = try #require(target)
        let boundaries = try #require(fragment.tableColumnBoundaries)
        let point = fragment.layoutFragmentFrame.origin
        let rect = try #require(fragment.tableSelectionRects(at: point).first)
        #expect(rect.minX >= point.x + boundaries[2] - 1,
                "第三列选区不应画到前一列：\(rect)")
        #expect(rect.maxX <= point.x + (boundaries.last ?? 0) + 1,
                "第三列选区越过表格右边界：\(rect)")
    }

    @Test func draggingWholeRowReordersCanonicalMarkdownAndUndoesOnce() throws {
        let source = "| A | B | C |\n|---|:---:|---:|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let table = try #require(package.tables.first)
        let textView = EditorTextView.make(textStorage: storage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        defer { window.contentView = nil }
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)

        #expect(coordinator.moveTableRow(tableID: table.headerLine, from: 2, to: 1))
        #expect(storage.string == "| A | B | C |\n| --- | :---: | ---: |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |")

        let undo = try #require(textView.undoManager)
        undo.undo()
        #expect(storage.string == source, "整行拖拽应由一次撤销完整还原")
    }

    @Test func draggingWholeColumnMovesCellsAndAlignmentTogether() throws {
        let source = "| A | B | C |\n|---|:---:|---:|\n| 1 | 2 | 3 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let table = try #require(package.tables.first)
        let textView = EditorTextView.make(textStorage: storage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        defer { window.contentView = nil }
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)

        #expect(coordinator.moveTableColumn(tableID: table.headerLine, from: 0, to: 2))
        #expect(storage.string == "| B | C | A |\n| :---: | ---: | --- |\n| 2 | 3 | 1 |")
    }

    @Test func cancellingTableDragOnlyClearsTransientPresentation() throws {
        let source = "| A | B |\n|---|---|\n| 1 | 2 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let table = try #require(package.tables.first)
        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)

        #expect(coordinator.handleTableDrag(TableDragEvent(
            phase: .began,
            tableID: table.headerLine,
            axis: .column,
            source: 0,
            destination: 0
        )))
        #expect(storage.attribute(.museTableDragAxis, at: 0, effectiveRange: nil) as? String == "column")
        #expect(coordinator.handleTableDrag(TableDragEvent(
            phase: .cancelled,
            tableID: table.headerLine,
            axis: .column,
            source: 0,
            destination: 1
        )))
        #expect(storage.attribute(.museTableDragAxis, at: 0, effectiveRange: nil) == nil)
        #expect(storage.string == source)
        #expect(textView.undoManager?.canUndo != true, "纯拖拽反馈不应污染撤销栈")
    }

    @Test func tableStructureActionsInsertRenderedRowsAndPreserveAlignment() throws {
        let source = "| A | B |\n|---|:---:|\n| 1 | 2 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let table = try #require(package.tables.first)
        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)

        #expect(coordinator.performTableAction(
            tableID: table.headerLine,
            action: .insertRow(index: table.rows.count, copying: nil)
        ))
        #expect(storage.string == "| A | B |\n| --- | :---: |\n| 1 | 2 |\n|  |  |")
        #expect(coordinator.currentTableSelection?.bounds == TableSelectionBounds(
            minRow: 2, maxRow: 2, minColumn: 0, maxColumn: 1
        ))
    }

    @Test func tableSortKeepsHeaderAndUsesNaturalOrdering() throws {
        let source = "| Item | Value |\n|---|---|\n| item10 | x |\n| item2 | y |\n| item1 | z |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let table = try #require(package.tables.first)
        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)

        #expect(coordinator.performTableAction(
            tableID: table.headerLine,
            action: .sort(column: 0, direction: .ascending)
        ))
        #expect(storage.string == "| Item | Value |\n| --- | --- |\n| item1 | z |\n| item2 | y |\n| item10 | x |")
    }

    @Test func shiftArrowsGrowAndShrinkRectangularTableSelection() throws {
        let source = "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let table = try #require(package.tables.first)
        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        textView.setSelectedRange(package.index.nsRange(table.rows[1].cells[1].ink))

        #expect(coordinator.extendTableSelection(arrow: .right))
        #expect(coordinator.extendTableSelection(arrow: .down))
        #expect(coordinator.currentTableSelection?.bounds == TableSelectionBounds(
            minRow: 1, maxRow: 2, minColumn: 1, maxColumn: 2
        ))

        #expect(coordinator.extendTableSelection(arrow: .left))
        #expect(coordinator.currentTableSelection?.bounds == TableSelectionBounds(
            minRow: 1, maxRow: 2, minColumn: 1, maxColumn: 1
        ), "活动端返回锚点列时，选区应收缩而不是保留历史并集")
    }

    @Test func pastedTSVExpandsTableWithoutExposingMarkdownDelimiters() throws {
        let source = "| A | B |\n|---|---|\n| 1 | 2 |"
        let storage = NSTextStorage(string: source)
        let package = engine.prepare(source)
        _ = engine.render(package: package, selection: nil, into: storage)
        let table = try #require(package.tables.first)
        let textView = EditorTextView.make(textStorage: storage)
        let coordinator = RenderCoordinator()
        coordinator.attach(storage: storage)
        coordinator.textView = textView
        coordinator.adoptPackage(package)
        #expect(coordinator.selectTableCells(
            tableID: table.headerLine,
            bounds: TableSelectionBounds(minRow: 1, maxRow: 1, minColumn: 1, maxColumn: 1)
        ))
        let pasteboard = NSPasteboard(name: .init("MuseTests.TableTSV.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("p\tq\nr\ts", forType: .string)

        #expect(coordinator.pasteTableSelection(from: pasteboard))
        #expect(storage.string == "| A | B |  |\n| --- | --- | --- |\n| 1 | p | q |\n|  | r | s |")
        #expect(coordinator.currentTableSelection?.bounds == TableSelectionBounds(
            minRow: 1, maxRow: 2, minColumn: 1, maxColumn: 2
        ))
    }

    @Test func tableFragmentsExposeOneRowHandleAndHeaderColumnHandles() throws {
        let source = "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |"
        let (storage, _) = render(source)
        let textView = EditorTextView.make(textStorage: storage)
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
        textView.textContainer?.containerSize = NSSize(
            width: 1000,
            height: CGFloat.greatestFiniteMagnitude
        )
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        var headerHandles: [TableDragHandleGeometry] = []
        var bodyHandles: [TableDragHandleGeometry] = []
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MuseLayoutFragment else { return true }
            let handles = fragment.tableDragHandleGeometries(at: fragment.layoutFragmentFrame.origin)
            if fragment.tableRowIndex == 0 { headerHandles = handles }
            if fragment.tableRowIndex == 1 { bodyHandles = handles }
            return true
        }
        #expect(headerHandles.filter { $0.axis == .row }.count == 1)
        #expect(headerHandles.filter { $0.axis == .column }.count == 3)
        #expect(bodyHandles.filter { $0.axis == .row }.count == 1)
        #expect(bodyHandles.filter { $0.axis == .column }.isEmpty)
    }

    @Test func tableChromeRemovesScrollOffsetWithoutFlippingAgain() {
        let visibleDocumentRect = CGRect(x: 0, y: 400, width: 1000, height: 600)
        let headerHandle = CGRect(x: 120, y: 450, width: 240, height: 16)

        let layerRect = TableChromeCoordinateSpace.layerRect(
            for: headerHandle,
            overlayFrame: visibleDocumentRect
        )

        #expect(layerRect == CGRect(x: 120, y: 50, width: 240, height: 16),
                "翻转 NSView 的 backing layer 已由 AppKit 对齐到左上坐标，不能再次镜像 Y")
        #expect(layerRect.minY == headerHandle.minY - visibleDocumentRect.minY,
                "覆盖层内的位置应只扣除可视区滚动偏移")
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
