import AppKit

public nonisolated enum TableDragPhase: Sendable {
    case began
    case changed
    case ended
    case cancelled
}

public nonisolated struct TableDragEvent: Sendable {
    public let phase: TableDragPhase
    public let tableID: Int
    public let axis: TableDragHandleGeometry.Axis
    public let source: Int
    public let destination: Int

    public init(
        phase: TableDragPhase,
        tableID: Int,
        axis: TableDragHandleGeometry.Axis,
        source: Int,
        destination: Int
    ) {
        self.phase = phase
        self.tableID = tableID
        self.axis = axis
        self.source = source
        self.destination = destination
    }
}

public nonisolated struct TableSelectionBounds: Sendable, Equatable {
    public let minRow: Int
    public let maxRow: Int
    public let minColumn: Int
    public let maxColumn: Int

    public init(minRow: Int, maxRow: Int, minColumn: Int, maxColumn: Int) {
        self.minRow = min(minRow, maxRow)
        self.maxRow = max(minRow, maxRow)
        self.minColumn = min(minColumn, maxColumn)
        self.maxColumn = max(minColumn, maxColumn)
    }
}

public nonisolated enum TableSortDirection: Sendable {
    case ascending
    case descending
}

public nonisolated enum TableStructureAction: Sendable {
    case insertRow(index: Int, copying: Int?)
    case removeRow(index: Int)
    case moveRow(from: Int, to: Int)
    case insertColumn(index: Int, copying: Int?, alignmentFrom: Int?)
    case removeColumn(index: Int)
    case moveColumn(from: Int, to: Int)
    case align(columns: ClosedRange<Int>, alignment: TableStructure.ColumnAlignment)
    case sort(column: Int, direction: TableSortDirection)
    case clear(TableSelectionBounds)
    case delete(TableSelectionBounds)
}

/// 块级视觉标记：渲染引擎把它作为自定义属性写入整行/整块范围，
/// 布局层的 MuseLayoutFragment 据此决定绘制内容（引用竖线、通宽背景、分隔线横线）。
/// 与样式状态严格一致（随属性应用写、随脏带重置清）。
public enum BlockVisual: String {
    case heading
    case quote
    case codeFence
    case rule
    /// GFM 表格：列宽由属性层算好，绘制层照着画单元格线与表头底色。
    case table
    /// 行内图片独占一行时的块呈现：字符全部折叠，图片由绘制层画在
    /// 段落撑出的行高里（tech-plan §4.7 的 Phase 2 路线）。
    case image
    /// `$$…$$` 块级公式：源码折叠后由布局 fragment 绘制缓存的原生公式图。
    case math
    /// 列表（含任务）：值带后缀 ":u"（无序）/":o"（有序）/":t"（任务）。
    case list
}

extension NSAttributedString.Key {
    /// nonisolated：块视觉的 fragment（MuseLayoutFragment）在 nonisolated 的
    /// 度量路径（renderingSurfaceBounds）里也要读它。Key 本身是 Sendable。
    public nonisolated static let museBlock = NSAttributedString.Key("museBlock")
    /// 块内角色（"open" / "close" / "open+close"）：代码围栏首/末行据此把背景
    /// 延伸成带垂直内边距的圆角块（间距由 Theme.fenceParagraph 撑出）。
    public nonisolated static let museBlockRole = NSAttributedString.Key("museBlockRole")
    /// 表格列边界（[NSNumber]，相对本行正文起点的 x 偏移，含首尾两端）。
    /// 绘制层据此画竖线，不重新度量文本。
    public nonisolated static let museTableColumns = NSAttributedString.Key("museTableColumns")
    /// 表格内的行序号（0 为表头）：绘制层用它做隔行底色。
    public nonisolated static let museTableRow = NSAttributedString.Key("museTableRow")
    /// 表格的稳定身份（表头源码行号）。同一张表的所有可见行共享该值，编辑视图
    /// 据此把各 fragment 组合成一项整行/整列拖拽操作。
    public nonisolated static let museTableID = NSAttributedString.Key("museTableID")
    /// 表格内的临时选区。TextKit 2 会把隐藏结构字符上的大额 kern 再算进系统选区
    /// 几何，导致蓝色选框漂到表格右侧；布局 fragment 用这个属性在真实字形位置
    /// 绘制选区。它只是一项可丢弃的呈现属性，不进入 Markdown 与撤销栈。
    public nonisolated static let museTableSelection = NSAttributedString.Key("museTableSelection")
    /// 普通文本选区在含大 kern 的行内公式段落里由 fragment 按实际字形落点绘制。
    public nonisolated static let museTextSelection = NSAttributedString.Key("museTextSelection")
    /// 拖拽期间的纯呈现属性；不进入 Markdown，也不进入撤销栈。
    public nonisolated static let museTableDragAxis = NSAttributedString.Key("museTableDragAxis")
    public nonisolated static let museTableDragSource = NSAttributedString.Key("museTableDragSource")
    public nonisolated static let museTableDragDestination = NSAttributedString.Key("museTableDragDestination")
    /// Obsidian 风格的持久单元格选区，值为 `[minRow,maxRow,minColumn,maxColumn]`。
    /// 只影响绘制和剪贴板命令，不写回 Markdown。
    public nonisolated static let museTableCellSelection = NSAttributedString.Key("museTableCellSelection")
    /// 图片解析后的绝对 URL（本地与远程共用），用于刷新定位与调试。
    public nonisolated static let museImageURL = NSAttributedString.Key("museImageURL")
    /// 当前正文强持有的不可变图片绘制产物。`NSCache` 被系统驱逐后，TextKit 绘制
    /// 仍从这里取得像素，不执行磁盘/网络 I/O，也不会留下陈旧的大行高占位框。
    public nonisolated static let museImageArtifact = NSAttributedString.Key("museImageArtifact")
    /// 图片的呈现尺寸（[NSNumber] 宽、高），与撑出的行高一致。
    public nonisolated static let museImageSize = NSAttributedString.Key("museImageSize")
    /// AST-provided ordered-list number consumed by the custom layout fragment.
    public nonisolated static let museListNumber = NSAttributedString.Key("museListNumber")
    /// AST-provided list depth consumed by the custom layout fragment.
    public nonisolated static let museListDepth = NSAttributedString.Key("museListDepth")
    /// UTF-16 offset of the source marker inside its paragraph.
    public nonisolated static let museListMarkerLocation = NSAttributedString.Key("museListMarkerLocation")
    /// UTF-16 length of the complete source marker, including trailing spacing.
    public nonisolated static let museListMarkerLength = NSAttributedString.Key("museListMarkerLength")
    /// AST-provided task state. The drawing layer must not reparse `[x]` from source.
    public nonisolated static let museTaskChecked = NSAttributedString.Key("museTaskChecked")
    /// 图片语法的目的地字符串（渲染引擎写入整个 `![标签](目的地)` 区间），
    /// 点击预览据此解析图片，不重新解析源码。
    public nonisolated static let museImageDestination = NSAttributedString.Key("museImageDestination")
    /// 标题级别，供公式显隐时从语义属性重建段落样式。
    public nonisolated static let museHeadingLevel = NSAttributedString.Key("museHeadingLevel")
    /// MathJax 在异步准备阶段生成的不可变 SVG 公式绘制产物。
    public nonisolated static let museMathArtifact = NSAttributedString.Key("museMathArtifact")
    /// NSNumber(Bool)：true 为块公式，false 为行内公式。
    public nonisolated static let museMathDisplay = NSAttributedString.Key("museMathDisplay")
    /// 块公式开分隔符的唯一绘制锚点；容器前缀仍可保留自己的 `.museBlock`。
    public nonisolated static let museBlockMathAnchor = NSAttributedString.Key("museBlockMathAnchor")
    /// 首段落内存在块公式锚点；避免普通 fragment 为寻找锚点而枚举整段。
    public nonisolated static let museBlockMathParagraph = NSAttributedString.Key("museBlockMathParagraph")
    /// 段落内存在可绘制行内公式。fragment 先 O(1) 读这个标记，再决定是否枚举。
    public nonisolated static let museInlineMathParagraph = NSAttributedString.Key("museInlineMathParagraph")
    /// 隐藏态行内公式的禁止断行区间，由 TextKit 2 delegate 消费。
    public nonisolated static let museInlineMathNoBreak = NSAttributedString.Key("museInlineMathNoBreak")
    /// 隐藏态行内公式实际需要的行高；段落恢复只枚举这一项，不做嵌套属性查询。
    public nonisolated static let museInlineMathReservedHeight = NSAttributedString.Key("museInlineMathReservedHeight")
}

/// 主题：字体与配色。亮/暗跟随系统外观（动态 NSColor）。
///
/// nonisolated + Sendable：块视觉在 `NSTextLayoutFragment` 的 nonisolated
/// 绘制/度量接口里取用主题。NSColor / NSFont 都是不可变且线程安全的，
/// 主题本身只读，跨隔离域读取无竞争。
public nonisolated struct Theme: @unchecked Sendable {
    public let text: NSColor
    public let mutedText: NSColor
    public let codeText: NSColor
    public let codeBackground: NSColor
    public let linkColor: NSColor
    public let quoteText: NSColor
    public let quoteBackground: NSColor
    public let markerText: NSColor
    public let borderColor: NSColor
    /// 任务复选框配色。数值由 Typora 默认主题的 2x 截图实测而来：勾选填充
    /// `#3478F6`、未勾选描边 `#808080`（平灰，不是半透明的 label 色——后者在
    /// 浅底上会偏淡，方框看着发虚）。
    ///
    /// 刻意**不跟随** `controlAccentColor`：系统默认蓝是 `#007AFF`，和 Typora 的
    /// 蓝差着一截（R 相差 52），跟随系统就对不上「照 Typora 来」这个要求。
    /// 暗色值未实测，是按浅色值提亮推的。
    public let checkboxFill: NSColor
    public let checkboxBorder: NSColor
    /// 表头底色与隔行底色（对标 Typora github.css 的 `#f6f8fa`）。
    public let tableHeaderBackground: NSColor
    public let tableStripeBackground: NSColor

    public let baseSize: CGFloat = 16

    public static let standard = Theme(
        text: adaptive(light: NSColor(calibratedWhite: 0.13, alpha: 1),
                       dark: NSColor(calibratedWhite: 0.93, alpha: 1)),
        mutedText: adaptive(light: NSColor(calibratedWhite: 0.42, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.62, alpha: 1)),
        codeText: adaptive(light: NSColor(calibratedRed: 0.58, green: 0.25, blue: 0.20, alpha: 1),
                           dark: NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.47, alpha: 1)),
        codeBackground: adaptive(light: NSColor(calibratedWhite: 0.955, alpha: 1),
                                 dark: NSColor(calibratedWhite: 0.16, alpha: 1)),
        linkColor: adaptive(light: NSColor(calibratedRed: 0.17, green: 0.40, blue: 0.72, alpha: 1),
                            dark: NSColor(calibratedRed: 0.50, green: 0.68, blue: 0.95, alpha: 1)),
        quoteText: adaptive(light: NSColor(calibratedWhite: 0.38, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.66, alpha: 1)),
        quoteBackground: adaptive(light: NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1),
                                  dark: NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.19, alpha: 1)),
        markerText: adaptive(light: NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.68, alpha: 0.9),
                             dark: NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.76, alpha: 0.9)),
        borderColor: adaptive(light: NSColor(calibratedWhite: 0.88, alpha: 1),
                              dark: NSColor(calibratedWhite: 0.25, alpha: 1)),
        checkboxFill: adaptive(light: NSColor(srgbRed: 52 / 255, green: 120 / 255, blue: 246 / 255, alpha: 1),
                               dark: NSColor(srgbRed: 90 / 255, green: 150 / 255, blue: 250 / 255, alpha: 1)),
        checkboxBorder: adaptive(light: NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1),
                                 dark: NSColor(calibratedWhite: 0.55, alpha: 1)),
        tableHeaderBackground: adaptive(light: NSColor(calibratedRed: 0.965, green: 0.973, blue: 0.980, alpha: 1),
                                        dark: NSColor(calibratedWhite: 0.20, alpha: 1)),
        tableStripeBackground: adaptive(light: NSColor(calibratedRed: 0.980, green: 0.984, blue: 0.988, alpha: 1),
                                        dark: NSColor(calibratedWhite: 0.17, alpha: 1))
    )

    // MARK: - 字体

    public func baseFont() -> NSFont { NSFont.systemFont(ofSize: baseSize) }
    public func boldFont() -> NSFont { NSFont.systemFont(ofSize: baseSize, weight: .semibold) }

    /// 在既有字体上合并字形特征（如强调嵌套在粗体内时应得到粗斜体，而不是覆盖成斜体）。
    /// NSFontManager.convert 只能可靠地从"基础 face"出发一次性加特征（从中间态再 convert
    /// 会静默丢失特征，如 RegularItalic→加粗 仍返回 RegularItalic），
    /// 因此先剥离粗/斜特征归一化，再一次性加上目标组合。
    public func derivedFont(from base: NSFont, adding trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        // 目标组合从原始字体计算；归一化后再一次性应用（从中间态 convert 会静默丢特征）。
        let desired = manager.traits(of: base).union(trait)
        let normalized = manager.convert(
            manager.convert(base, toNotHaveTrait: .boldFontMask),
            toNotHaveTrait: .italicFontMask
        )
        return manager.convert(normalized, toHaveTrait: desired)
    }
    public func italicFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: baseSize)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseSize) ?? base
    }
    public func titleFont(level: Int) -> NSFont {
        let sizeByLevel: [CGFloat] = [28, 24, 20, 18, 16.5, 16]
        let size = sizeByLevel[max(0, min(level - 1, 5))]
        return NSFont.systemFont(ofSize: size, weight: .bold)
    }
    public func codeFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) }
    /// marker 隐藏用：近零宽 + 透明。M0 验证项：观察是否产生可见留白。
    public func hiddenMarkerFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular) }
    /// Empty hidden list items still need normal vertical font metrics so
    /// TextKit creates a full-height line fragment. Compress only the horizontal
    /// axis so the invisible carrier does not move the replacement marker.
    public func hiddenMarkerLineHeightCarrierFont() -> NSFont {
        let base = baseFont()
        let transform = AffineTransform(scaleByX: 0.01, byY: 1)
        return NSFont(descriptor: base.fontDescriptor, textTransform: transform) ?? base
    }
    public func revealedMarkerFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }

    // MARK: - 段落

    /// 排版基准对标 Typora 默认主题（github.css）：body 16px / line-height 1.6、
    /// 段落 margin 0.8em、标题 margin 1rem、pre 字号 0.9em。
    /// CJK 字体自然行高约为字号的 1.4 倍，CSS 1.6 ≈ multiple 1.35。
    public func baseParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.35
        p.paragraphSpacing = 11
        return p
    }

    public func headingParagraph(level: Int) -> NSMutableParagraphStyle {
        let p = baseParagraph()
        // Typora 标题 line-height 1.2 左右，且上下 margin 均为 1rem；TextKit
        // 的段落间距是求和（不折叠），标题前的空隙由上一段的 spacing 共同承担。
        p.lineHeightMultiple = 1.15
        p.paragraphSpacingBefore = level <= 2 ? 16 : 12
        p.paragraphSpacing = level <= 2 ? 8 : 6
        return p
    }

    public func quoteParagraph() -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.firstLineHeadIndent = 18
        p.headIndent = 18
        return p
    }

    /// 列表每一层的缩进步长。
    ///
    /// 对标 Typora github.css 的 `ul, ol { padding-left: 30px }`：**整块列表比正文
    /// 和标题更靠右一步**，marker 画在这一步撑出的留白里——也就是 CSS
    /// `list-style-position: outside` 的模型（marker 属于 padding 区，不属于内容列）。
    ///
    /// 一定要 ≥ `ListMarkerGeometry.defaultMarkerLaneWidth`，否则 marker lane 会溢出
    /// 到正文左缘之外：那正是本项目此前的形态，视觉上「列表反而比正文更靠左」。
    public nonisolated static let listIndentStep: CGFloat = 28

    /// Paragraph geometry for every list form.
    ///
    /// 深度 d 的内容列在 `d * listIndentStep`，marker 的墨迹右缘紧贴内容列左侧，
    /// 落在上一层与本层内容列之间的留白里。于是：正文/标题在 0，一级列表正文在
    /// 28、marker 紧贴在它左边，二级列表正文在 56——每一层的 marker 与正文都同步
    /// 右移一步，和 Typora 的层级观感一致。
    ///
    /// 内容列**只由语义深度决定**：行首的源码缩进不折叠（空白没有墨迹），但会从
    /// 行起点里扣掉，所以 `  - x` 和 `    - x` 只要 AST 深度相同就落在同一列。
    /// 续行对齐同一个内容列。
    ///
    /// 回显源码（光标落在这一行）时整段前缀按实测推进量让位，正文列在显隐之间
    /// 不动；一级列表现在有整整一步的余量，`- ` 这类常见前缀不再触发临时位移。
    public func listParagraph(
        depth: Int,
        sourcePrefixText: String? = nil,
        markerRevealed: Bool = false
    ) -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.paragraphSpacing = 3

        let level = max(1, depth)
        let contentIndent = CGFloat(level) * Theme.listIndentStep

        let prefix = sourcePrefixText ?? ""
        let sourceIndent = prefix.prefix { $0 == " " || $0 == "\t" }
        let sourceIndentWidth = (String(sourceIndent) as NSString)
            .size(withAttributes: [.font: baseFont()]).width

        // 行首源码缩进不折叠（它是普通空白，没有墨迹），但**不能让它把正文列往右推**：
        // 否则同一层的条目会因为源码写 2 空格还是 4 空格而落在不同的列上，缩进也就
        // 不再由语义深度决定。做法是把行起点左移这段空白的宽度，正文照旧落在
        // `contentIndent`——不改一个字符，视觉上等价于把它折叠掉。
        var firstLineOffset = sourceIndentWidth
        if markerRevealed {
            // 回显时 marker 本体换成等宽字体，把它的实测推进量一并让出来，正文列
            // 因此在显隐之间完全不动。放不下时 TextKit 2 钳制负行起点，整行右移
            // （Obsidian 式临时位移）。
            let markerPart = prefix.drop { $0 == " " || $0 == "\t" }
            firstLineOffset += (String(markerPart) as NSString)
                .size(withAttributes: [.font: revealedMarkerFont()]).width
        }
        p.firstLineHeadIndent = max(0, contentIndent - firstLineOffset)
        p.headIndent = contentIndent
        return p
    }

    /// 代码行行距：Typora pre 为 line-height 1.45、行间无额外 margin。
    public func codeParagraph() -> NSMutableParagraphStyle {
        let p = baseParagraph()
        p.lineHeightMultiple = 1.25
        p.paragraphSpacing = 0
        return p
    }

    /// 代码围栏首/末行的段落样式。垂直内边距由两半组成：段落间距撑出空隙，
    /// 绘制层把背景反向延伸同样的距离补上空隙——视觉上就是带 padding 的圆角块。
    /// 数值对标 Typora：pre 上下 padding 8px/6px、margin 15px 0。
    public func fenceParagraph(isFirstLine: Bool, isLastLine: Bool) -> NSMutableParagraphStyle {
        let p = codeParagraph()
        if isFirstLine {
            p.paragraphSpacingBefore = 14
            p.paragraphSpacing = 0
        }
        if isLastLine {
            p.paragraphSpacing = 14
        }
        return p
    }

    /// 表格行段落样式。
    ///
    /// 单元格的上下内边距要**分开撑**：TextKit 把行高的增量全部加在基线**之上**
    /// （实测 `minimumLineHeight = 30` 时基线落在 27，字形贴着行盒底边、降部还会
    /// 越界），所以上内边距用 `minimumLineHeight` 撑、下内边距用 `paragraphSpacing`
    /// 撑，文字才落在单元格中间。
    ///
    /// 不设 `maximumLineHeight`：emoji 的行高比西文高，钳住会把它切掉。行盒实际
    /// 多高由绘制层从 `textLineFragments.first.typographicBounds` 读回来，两边因此
    /// 永远一致。
    public func tableParagraph(isLast: Bool) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        let font = baseFont()
        let naturalLineHeight = font.ascender - font.descender + font.leading
        p.minimumLineHeight = naturalLineHeight + Theme.tableCellPaddingY
        p.lineHeightMultiple = 1
        // 末行额外撑出表格与下一段之间的外边距。
        p.paragraphSpacing = Theme.tableCellPaddingY + (isLast ? 12 : 0)
        // 单元格文本不换行：列宽由内容决定，软换行会让横线与竖线错位。
        // kern 会参与断行（实测：kern 80 的行在 120pt 容器里被折成两行），
        // `.byClipping` 是唯一能保证一行一格的设置。
        p.lineBreakMode = .byClipping
        return p
    }

    /// 表格的排版常量（属性层与绘制层共用；两侧必须读同一份值）。
    /// 数值对标 Typora github.css：`th/td { padding: 6px 13px; border: 1px }`。
    public nonisolated static let tableCellPaddingX: CGFloat = 13
    public nonisolated static let tableCellPaddingY: CGFloat = 6
    public nonisolated static let tableBorderWidth: CGFloat = 1
    /// 表格外沿控制区与 Obsidian 的 `--size-4-4` 一致：足够命中，但默认不占视觉重量。
    public nonisolated static let tableChromeSize: CGFloat = 16

    /// 分隔行（`|---|---|`）的段落样式。
    ///
    /// 关键是**不设** `minimumLineHeight`：这一行整行是表格的 marker，隐藏态字体
    /// 只有 0.1pt，行高必须跟着塌到零；给它一个固定行高就会在表头与首行数据之间
    /// 留一条空行。显式切换到源码模式时，整篇会改用源码段落样式。
    public func tableDelimiterParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1
        p.paragraphSpacing = 0
        p.paragraphSpacingBefore = 0
        p.lineBreakMode = .byClipping
        return p
    }

    /// 图片独占一行时的段落样式：行高就是图片的呈现高度，绘制层在这块
    /// 保留区里画图。`minimumLineHeight` 是 TextKit 2 下唯一不改字符就能
    /// 预留垂直空间的公开手段（`.attachment` 会被 NSTextStorage 的属性修复
    /// 从非 U+FFFC 字符上抹掉——实测见 RendererTests）。
    public func imageParagraph(height: CGFloat) -> NSMutableParagraphStyle {
        resourceParagraph(
            height: height,
            verticalPadding: Theme.imagePaddingVertical,
            minimumHeight: 1,
            spacing: 6
        )
    }

    /// 块公式的独占行盒。源码多行中的后续段落另用 `collapsedMathParagraph` 折叠，
    /// 只有开分隔符所在 fragment 获得这一高度并绘制一次公式。
    public func mathParagraph(
        height: CGFloat,
        preserving sourceParagraph: NSParagraphStyle? = nil
    ) -> NSMutableParagraphStyle {
        let font = baseFont()
        return resourceParagraph(
            height: height,
            verticalPadding: Theme.mathPaddingVertical,
            minimumHeight: font.ascender - font.descender + font.leading,
            spacing: 8,
            preserving: sourceParagraph
        )
    }

    /// Images and display math use the same TextKit 2 reservation mechanism. Keep
    /// line-height, spacing, and clipping mutations here so resource paragraphs cannot
    /// silently diverge when one renderer changes.
    private func resourceParagraph(
        height: CGFloat,
        verticalPadding: CGFloat,
        minimumHeight: CGFloat,
        spacing: CGFloat,
        preserving sourceParagraph: NSParagraphStyle? = nil
    ) -> NSMutableParagraphStyle {
        let p = sourceParagraph?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        let reserved = max(height + verticalPadding * 2, minimumHeight)
        p.minimumLineHeight = reserved
        p.maximumLineHeight = reserved
        p.lineHeightMultiple = 1
        p.paragraphSpacing = max(p.paragraphSpacing, spacing)
        p.paragraphSpacingBefore = max(p.paragraphSpacingBefore, spacing)
        p.lineBreakMode = .byClipping
        return p
    }

    public func collapsedMathParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.1
        p.maximumLineHeight = 0.1
        p.lineHeightMultiple = 1
        p.paragraphSpacing = 0
        p.paragraphSpacingBefore = 0
        p.lineBreakMode = .byClipping
        return p
    }

    public nonisolated static let mathPaddingVertical: CGFloat = 8
    public nonisolated static let inlineMathFontSize: CGFloat = 17
    public nonisolated static let blockMathFontSize: CGFloat = 21
    public nonisolated static let blockMathMaximumWidth: CGFloat = 640
    public nonisolated static let inlineMathMaximumWidth: CGFloat = 320

    public nonisolated static let imagePaddingVertical: CGFloat = 6

    /// 加载不到的图片（文件缺失 / 远程地址）的占位框尺寸。
    public nonisolated static let imagePlaceholderSize = NSSize(width: 320, height: 72)

    /// 代码块背景的垂直内边距与圆角（绘制层消费，须与 fenceParagraph 的间距互补）。
    public nonisolated static let codeFencePaddingTop: CGFloat = 8
    public nonisolated static let codeFencePaddingBottom: CGFloat = 6
    public nonisolated static let codeFenceCornerRadius: CGFloat = 6

    /// 行内图片的显示上限：自然尺寸不超过它，超出按比例缩小（Typora 为 100% 内容宽）。
    public nonisolated static let inlineImageMaxSize = NSSize(width: 560, height: 400)

    public func ruleParagraph() -> NSMutableParagraphStyle {
        let p = baseParagraph()
        // Typora hr：2px 高、上下 margin 16px。
        p.paragraphSpacingBefore = 16
        p.paragraphSpacing = 16
        return p
    }

    // MARK: - 工具

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        }
    }
}

/// Fragment 绘制使用的、已经按具体外观解析的颜色。
///
/// `NSTextLayoutFragment` 的绘制回调不保证建立了正确的
/// `NSAppearance.current`，而 TextKit 还可能缓存并复用 fragment。颜色不能在
/// fragment 内直接从动态 `NSColor` 取 `cgColor`，否则外观切换后可能静默回落亮色。
public nonisolated struct BlockVisualPaletteSnapshot: @unchecked Sendable {
    public let text: CGColor
    public let quoteBackground: CGColor
    public let codeBackground: CGColor
    public let marker: CGColor
    public let border: CGColor
    /// Accent used for checked task markers.
    public let checkboxChecked: CGColor
    /// Outline color for the unchecked checkbox.
    public let checkboxUnchecked: CGColor
    public let tableHeaderBackground: CGColor
    public let tableStripeBackground: CGColor
}

/// 块视觉调色板的唯一共享实例。
///
/// fragment 的接口是 nonisolated，读写不能依赖 MainActor；外观变化时替换快照
/// 内容，所有存活 fragment 都会在下一次绘制时读取当前外观的颜色。
public nonisolated final class BlockVisualPalette: @unchecked Sendable {
    public static let shared = BlockVisualPalette()

    private let lock = NSLock()
    private var current: BlockVisualPaletteSnapshot

    private init() {
        guard let appearance = NSAppearance(named: .aqua) else {
            fatalError("The system Aqua appearance is unavailable.")
        }
        current = Self.snapshot(for: appearance)
    }

    public func snapshot() -> BlockVisualPaletteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func update(for appearance: NSAppearance) {
        let next = Self.snapshot(for: appearance)
        lock.lock()
        current = next
        lock.unlock()
    }

    private static func snapshot(for appearance: NSAppearance) -> BlockVisualPaletteSnapshot {
        let theme = Theme.standard
        return BlockVisualPaletteSnapshot(
            text: resolvedCGColor(theme.text, for: appearance),
            quoteBackground: resolvedCGColor(theme.quoteBackground, for: appearance),
            codeBackground: resolvedCGColor(theme.codeBackground, for: appearance),
            marker: resolvedCGColor(theme.markerText, for: appearance),
            border: resolvedCGColor(theme.borderColor, for: appearance),
            checkboxChecked: resolvedCGColor(theme.checkboxFill, for: appearance),
            checkboxUnchecked: resolvedCGColor(theme.checkboxBorder, for: appearance),
            tableHeaderBackground: resolvedCGColor(theme.tableHeaderBackground, for: appearance),
            tableStripeBackground: resolvedCGColor(theme.tableStripeBackground, for: appearance)
        )
    }

    private static func resolvedCGColor(_ color: NSColor, for appearance: NSAppearance) -> CGColor {
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved ?? NSColor.black.cgColor
    }
}
