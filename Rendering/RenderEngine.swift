import AppKit

/// M2-lite 渲染引擎：AST 语义之外的"属性层"。
/// 铁律（v0.2）：只写属性、不改字符 —— 不改字符数、不插入附件字符。
///
/// 两条应用路径：
/// - `render`：整篇全量应用（首次装载/基准测试；同步）。
/// - `applyDirty`：只重置+重排受影响行的属性（输入热路径；配合后台解析见 RenderCoordinator）。
/// 行级粒度与线式 tokenizer 一致（行内语法以行为界），是"变化块增量"的第一版近似。
public struct RenderEngine {
    /// 编辑器的两种呈现方式。源码模式仍使用同一份 NSTextStorage，只改变派生属性。
    public enum PresentationMode: Sendable, Equatable {
        case rendered
        case source
    }

    /// 后台解析产物：纯值、Sendable，可跨线程（v0.2 RenderSnapshot 的第一版形态）。
    public nonisolated struct Package: Sendable {
        public let tokens: [Token]
        public let index: SourceIndex
        /// 每行起点的 UTF-8 字节偏移。
        public let lineStarts: [Int]
        /// GFM 表格的源码几何，按表头行升序。列宽在应用样式时才算（要读字体）。
        public let tables: [TableStructure]

        public init(
            tokens: [Token],
            index: SourceIndex,
            lineStarts: [Int],
            tables: [TableStructure] = []
        ) {
            self.tokens = tokens
            self.index = index
            self.lineStarts = lineStarts
            self.tables = tables
        }

        func table(headerLine: Int) -> TableStructure? {
            tables.first { $0.headerLine == headerLine }
        }
    }

    public struct Stats {
        public let tokenCount: Int

        public init(tokenCount: Int) {
            self.tokenCount = tokenCount
        }
    }

    private let theme = Theme.standard

    public init() {}

    /// 表驱动行内样式合并：需要"在既有字体上叠特征"的 token 类型。
    private enum FontMerge {
        case bold
        case italic
    }

    // MARK: - 输入（后台）

    public nonisolated func prepare(_ source: String) -> Package {
        let scanner = TokenScanner()
        let bytes = Array(source.utf8)
        let sourceLines = scanner.lines(bytes)
        let lineStarts = sourceLines.map(\.start)

        // AST 是语义与源码定位的唯一来源。即使文档没有链接或深层缩进，也必须
        // 构建语义层，避免同一 Markdown 在不同输入形态下走两套规则。
        let semantics = MarkdownSemantics(source, bytes: bytes, lines: sourceLines)
        return Package(
            tokens: semantics.tokens,
            index: SourceIndex(utf8: bytes),
            lineStarts: lineStarts,
            tables: semantics.tables
        )
    }

    // MARK: - 全量渲染（首次装载/基准）

    public func render(
        package: Package,
        selection: NSRange?,
        mode: PresentationMode = .rendered,
        into storage: NSTextStorage,
        imageBaseURL: URL? = nil
    ) -> Stats {
        let full = NSRange(location: 0, length: storage.length)

        let context = StyleContext(storage: storage, package: package, imageBaseURL: imageBaseURL)
        storage.beginEditing()
        storage.setAttributes(mode == .source ? sourceAttributes() : baseAttributes(), range: full)
        if mode == .rendered {
            for token in package.tokens {
                applyStyle(token, package: package, into: storage, context: context)
            }
            applyVisibility(
                package: package,
                selection: selection,
                into: storage,
                forceAll: true,
                imageBaseURL: imageBaseURL
            )
        }
        storage.endEditing()

        return Stats(tokenCount: package.tokens.count)
    }

    // MARK: - 脏行增量应用（输入热路径）

    /// 只重置与重排 dirty 行（跨越的行）的属性；marker 显隐由调用方另行 reconcile。
    /// dirty 范围（复审 P1-3，全部纯计算、不读存储属性）：
    /// - 基础范围：editedRange 覆盖的行；
    /// - +1 邻居行：插入换行会把原行拆成两行，后一行继承旧属性需要重排；
    /// - 旧/新 package 中与脏区相接的围栏整块：开/闭栏符增删会改变后续多行语义；
    /// - 脏区邻近的引用归属变化行。
    @discardableResult
    public func applyDirty(
        package: Package,
        previousPackage: Package?,
        utf16Range: NSRange,
        mode: PresentationMode = .rendered,
        into storage: NSTextStorage,
        imageBaseURL: URL? = nil
    ) -> ClosedRange<Int> {
        var dirtyLines = lineSpan(containing: utf16Range, package: package)
        let lastLine = package.lineStarts.count - 1
        dirtyLines = dirtyLines.lowerBound...min(dirtyLines.upperBound + 1, lastLine)

        extendForStructuralChanges(&dirtyLines, package: package, previousPackage: previousPackage)

        // 行边界字节区间 → UTF-16 区间（增量应用只重置这一"带"）。
        let startUTF8 = package.lineStarts[dirtyLines.lowerBound]
        let endUTF8 = lineEndUTF8(dirtyLines.upperBound, package: package)
        let spanStart = package.index.utf16Offset(startUTF8)
        let spanEnd = package.index.utf16Offset(endUTF8)
        let span = NSRange(location: spanStart, length: spanEnd - spanStart)

        let context = StyleContext(storage: storage, package: package, imageBaseURL: imageBaseURL)
        storage.beginEditing()
        storage.setAttributes(mode == .source ? sourceAttributes() : baseAttributes(), range: span)
        if mode == .rendered {
            for token in package.tokens where tokenLineRange(token, package: package).overlaps(dirtyLines) {
                applyStyle(token, package: package, into: storage, context: context)
            }
        }
        storage.endEditing()

        return dirtyLines
    }

    /// 结构变更（换行拆分/合并、围栏/引用开合）把旧样式留在脏区之外的行上，
    /// 这里基于"旧 package vs 新 package"的纯计算吸收受影响块 —— 不读存储属性
    /// （TextKit 2 存储的属性读取实测 ~56µs/次，读存储会让热路径退化）。
    private func extendForStructuralChanges(
        _ dirtyLines: inout ClosedRange<Int>,
        package: Package,
        previousPackage: Package?
    ) {
        let lastLine = max(0, package.lineStarts.count - 1)
        let validLines = 0...lastLine

        // 多行块（围栏/表格）：旧/新块与脏区相接（含相邻 1 行）→ 整块纳入。
        // 重复直到稳定（围栏串接的场景），纯区间运算，必然终止。
        let blockRanges = (
            multilineBlockRanges(of: previousPackage) + multilineBlockRanges(of: package)
        ).compactMap { clamped($0, to: validLines) }
        extendConnectedRange(&dirtyLines, candidates: blockRanges)

        // CommonMark lazy continuation 只能由 AST 判定。引用拓扑未变化时普通正文编辑
        // 保持局部；发生变化时沿旧/新引用的连通区间扩张到稳定。
        let oldQuotes = quoteLines(of: previousPackage)
        let newQuotes = quoteLines(of: package)
        if oldQuotes != newQuotes {
            let quoteRanges = (
                contiguousRanges(oldQuotes) + contiguousRanges(newQuotes)
            ).compactMap { clamped($0, to: validLines) }
            extendConnectedRange(&dirtyLines, candidates: quoteRanges)
        }
    }

    private func extendConnectedRange(
        _ dirtyLines: inout ClosedRange<Int>,
        candidates: [ClosedRange<Int>]
    ) {
        var extended = true
        while extended {
            extended = false
            for range in candidates
            where range.lowerBound <= dirtyLines.upperBound + 1
                && dirtyLines.lowerBound <= range.upperBound + 1 {
                let fullyContained = dirtyLines.lowerBound <= range.lowerBound
                    && dirtyLines.upperBound >= range.upperBound
                guard !fullyContained else { continue }
                let lower = min(dirtyLines.lowerBound, range.lowerBound)
                let upper = max(dirtyLines.upperBound, range.upperBound)
                dirtyLines = lower...upper
                extended = true
            }
        }
    }

    /// 跨多行的结构块（围栏、表格）覆盖的行区间。
    private func multilineBlockRanges(of package: Package?) -> [ClosedRange<Int>] {
        guard let package else { return [] }
        return package.tokens.compactMap { token in
            switch token.kind {
            case .codeFence, .table:
                return tokenLineRange(token, package: package)
            default:
                return nil
            }
        }
    }

    private func quoteLines(of package: Package?) -> Set<Int> {
        guard let package else { return [] }
        return Set(package.tokens.compactMap { token in
            if case .blockquote = token.kind { return token.line }
            return nil
        })
    }

    private func contiguousRanges(_ lines: Set<Int>) -> [ClosedRange<Int>] {
        let sorted = lines.sorted()
        guard var start = sorted.first else { return [] }
        var end = start
        var result: [ClosedRange<Int>] = []
        for line in sorted.dropFirst() {
            if line == end + 1 {
                end = line
            } else {
                result.append(start...end)
                start = line
                end = line
            }
        }
        result.append(start...end)
        return result
    }

    private func clamped(
        _ range: ClosedRange<Int>,
        to bounds: ClosedRange<Int>
    ) -> ClosedRange<Int>? {
        let lower = max(range.lowerBound, bounds.lowerBound)
        let upper = min(range.upperBound, bounds.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    // MARK: - marker 显隐（纯计算，供协调器 diff 后写属性）

    /// marker 的两种显示状态（Typora 模式）：
    /// - `.revealed`：回显源码标记（光标所在行/块内）；
    /// - `.hidden`：折叠隐藏（近零宽 + 透明）。列表图形符号的对齐由段落缩进
    ///   负责，具体图形由 MuseLayoutFragment 在同一 marker 带绘制。
    public enum MarkerState: Equatable {
        case revealed
        case hidden
    }

    public struct VisibilityEntry {
        public let line: Int
        /// marker 起点相对所在行起点的字节偏移（稳定身份：插入字符不改变它）。
        public let markerRelOffset: Int
        public let markerNS: NSRange
        public let state: MarkerState
        /// Only the structural marker of a list item carries depth. Inline
        /// markers on that same line remain nil and cannot change indentation.
        public let listDepth: Int?
        /// 行内图片：整段区间（隐藏态折叠为附件图片）；非图片为 nil。
        public let inlineImageRange: NSRange?
        /// 行内图片的 `![` 与 `](目的地)` 子区间（回显时恢复源码字体）。
        public let imageMarkerSubRange: NSRange?
        public let imageClosingSubRange: NSRange?

        init(
            line: Int,
            markerRelOffset: Int,
            markerNS: NSRange,
            state: MarkerState,
            listDepth: Int?,
            inlineImageRange: NSRange? = nil,
            imageMarkerSubRange: NSRange? = nil,
            imageClosingSubRange: NSRange? = nil
        ) {
            self.line = line
            self.markerRelOffset = markerRelOffset
            self.markerNS = markerNS
            self.state = state
            self.listDepth = listDepth
            self.inlineImageRange = inlineImageRange
            self.imageMarkerSubRange = imageMarkerSubRange
            self.imageClosingSubRange = imageClosingSubRange
        }
    }

    /// 纯函数：给定 package 与选区，计算所有 marker 的显隐状态。不触碰 storage。
    public func computedVisibility(
        package: Package,
        selection: NSRange?,
        mode: PresentationMode = .rendered
    ) -> [VisibilityEntry] {
        func makeEntries(_ token: Token, state: MarkerState) -> [VisibilityEntry] {
            // 行内图片：整段一个条目，携带子区间供附件显隐与源码回显。
            if let inline = token.inlineImageRange {
                let spanNS = package.index.nsRange(inline)
                let identity = markerIdentity(for: inline, package: package)
                return [VisibilityEntry(
                    line: identity.line,
                    markerRelOffset: identity.relOffset,
                    markerNS: spanNS,
                    state: state,
                    listDepth: nil,
                    inlineImageRange: spanNS,
                    imageMarkerSubRange: package.index.nsRange(token.markerRange),
                    imageClosingSubRange: token.closingMarkerRange.map(package.index.nsRange)
                )]
            }
            return token.markerVisibilityRanges.map { range in
                let identity = markerIdentity(for: range, package: package)
                return VisibilityEntry(
                    line: identity.line,
                    markerRelOffset: identity.relOffset,
                    markerNS: package.index.nsRange(range),
                    state: state,
                    listDepth: token.listDepth
                )
            }
        }

        func defaultState(_ token: Token) -> MarkerState {
            .hidden
        }

        guard mode == .rendered else {
            return package.tokens.flatMap { makeEntries($0, state: .revealed) }
        }

        guard let selection else {
            // 无选区（textView 未挂接的初始渲染窗口）：块级标记先按"未回显"写，
            // 挂接后由 refreshMarkerVisibility 按真实光标修正。
            return package.tokens.flatMap { makeEntries($0, state: defaultState($0)) }
        }
        let caretLine = lineIndex(atUTF16: selection.location, package: package)

        return package.tokens.flatMap { token in
            let state: MarkerState
            if token.isBlockMarker {
                let onCaret: Bool
                if case .taskListItem = token.kind {
                    // 复选框**始终是复选框**（对标 Typora）：它是可点击的控件，
                    // 光标经过就变回 `- [ ] ` 源码会让控件在编辑时消失，也让
                    // 「点一下切换」失去落点。源码模式下逐字显示，由上面
                    // `mode == .rendered` 的 guard 统一处理，与光标无关。
                    onCaret = false
                } else if selection.length > 0 {
                    // 跨行拖选时，所有与选区相交的块标记都应回显，而不是只看
                    // selection.location 所在行。命中与拖选仍完全交给 NSTextView。
                    onCaret = touches(blockRange(token, package: package), selection: selection)
                } else if case .codeFence = token.kind {
                    onCaret = tokenLineRange(token, package: package).contains(caretLine) // 光标在围栏块任意行
                } else if case .table = token.kind {
                    onCaret = tokenLineRange(token, package: package).contains(caretLine) // 光标在表格任意行
                } else {
                    onCaret = token.line == caretLine
                }
                state = onCaret ? .revealed : defaultState(token)
            } else {
                let markerNS = package.index.nsRange(token.markerRange)
                let contentNS = token.contentRange.map(package.index.nsRange) ?? markerNS
                let closingNS = token.closingMarkerRange.map(package.index.nsRange)
                let revealed = touches(markerNS, selection: selection)
                    || (closingNS.map { touches($0, selection: selection) } ?? false)
                    || touches(contentNS, selection: selection)
                state = revealed ? .revealed : .hidden
            }
            return makeEntries(token, state: state)
        }
    }

    /// 显隐相关属性表（协调器 diff 后写入）。
    public static func markerVisibilityAttributes(revealed: Bool) -> [NSAttributedString.Key: Any] {
        markerVisibilityAttributes(state: revealed ? .revealed : .hidden)
    }

    public static func markerVisibilityAttributes(state: MarkerState) -> [NSAttributedString.Key: Any] {
        let theme = Theme.standard
        switch state {
        case .revealed:
            return [
                .font: theme.revealedMarkerFont(),
                .foregroundColor: theme.markerText,
                .backgroundColor: NSColor.clear,
            ]
        case .hidden:
            return [
                .font: theme.hiddenMarkerFont(),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
            ]
        }
    }

    /// Apply one marker visibility transition without moving the list's body
    /// column. When source syntax is revealed, its measured advance is placed
    /// into the existing marker lane by shifting only `firstLineHeadIndent`.
    /// Hiding it restores the normal preview paragraph style.
    func applyMarkerVisibility(
        state: MarkerState,
        markerNS: NSRange,
        listDepth: Int?,
        into storage: NSTextStorage
    ) {
        storage.addAttributes(Self.markerVisibilityAttributes(state: state), range: markerNS)
        guard let listDepth else { return }

        let source = storage.string as NSString
        let paragraphRange = source.paragraphRange(for: markerNS)
        // The paragraph geometry compensates the whole visible prefix
        // (indentation + marker), not just the marker characters.
        let prefixRange = NSRange(
            location: paragraphRange.location,
            length: markerNS.location - paragraphRange.location + markerNS.length
        )
        storage.addAttribute(
            .paragraphStyle,
            value: theme.listParagraph(
                depth: listDepth,
                sourcePrefixText: source.substring(with: prefixRange),
                markerRevealed: state == .revealed
            ),
            range: paragraphRange
        )
    }

    /// 行内图片的显隐应用。
    ///
    /// 隐藏态（光标不在这一行）：整段语法折叠成近零宽，块图片的行高与
    /// `.museBlock` 保留，图由绘制层画在保留区里。
    /// 回显态（光标进入）：撤掉块角色与撑高的行高、语法恢复回显字体，
    /// 这一行退回普通文本——这是编辑图片路径的唯一入口。
    ///
    /// 块角色是从存储里**重建**的，而不是另存一份状态：`.museImageSize` 由样式层
    /// 写在整行上、显隐层从不动它，所以任何一次翻转都能从存储自己读回来。
    func applyInlineImageVisibility(
        state: MarkerState,
        span: NSRange,
        markerSubRange: NSRange?,
        closingSubRange: NSRange?,
        imageBaseURL: URL?,
        into storage: NSTextStorage
    ) {
        guard span.location >= 0, span.upperBound <= storage.length else { return }
        let lineRange = (storage.string as NSString).paragraphRange(for: span)
        let size = Self.imageSize(in: storage, at: span.location)

        switch state {
        case .hidden:
            storage.addAttributes(Self.markerVisibilityAttributes(state: .hidden), range: span)
            guard let size else { return }
            storage.addAttributes([
                .museBlock: BlockVisual.image.rawValue,
                .paragraphStyle: theme.imageParagraph(height: size.height),
            ], range: lineRange)

        case .revealed:
            if let markerSubRange {
                storage.addAttributes(Self.markerVisibilityAttributes(state: .revealed), range: markerSubRange)
            }
            if let closingSubRange {
                storage.addAttributes(Self.markerVisibilityAttributes(state: .revealed), range: closingSubRange)
            }
            // 标签回到正文样式：它不是语法，回显时不该跟着变成 marker 字体。
            if let markerSubRange, let closingSubRange,
               closingSubRange.location > markerSubRange.upperBound {
                storage.addAttributes([
                    .font: theme.baseFont(),
                    .foregroundColor: theme.text,
                ], range: NSRange(
                    location: markerSubRange.upperBound,
                    length: closingSubRange.location - markerSubRange.upperBound
                ))
            }
            guard size != nil else { return }
            storage.removeAttribute(.museBlock, range: lineRange)
            storage.addAttributes([.paragraphStyle: theme.baseParagraph()], range: lineRange)
        }
    }

    /// 整行上由样式层写下的图片呈现尺寸。
    static func imageSize(in storage: NSAttributedString, at location: Int) -> NSSize? {
        guard location >= 0, location < storage.length,
              let numbers = storage.attribute(.museImageSize, at: location, effectiveRange: nil) as? [NSNumber],
              numbers.count == 2 else { return nil }
        return NSSize(width: numbers[0].doubleValue, height: numbers[1].doubleValue)
    }

    // MARK: - 样式

    /// 一次样式应用里可以复用的派生数据。
    ///
    /// 两样东西都是「按文档规模计费」的，而样式应用是按 token 逐个调用的：
    ///
    /// - `storage.string as NSString`：每次都要过一次 Swift↔ObjC 桥；表格、块图片、
    ///   列表段落各自取一次，就变成 O(token 数 × 文档)。
    /// - 图片路径解析：加载失败**不进缓存**（否则用户补上文件后就再也看不到），
    ///   于是每张缺失的图每次渲染都要 stat 一次磁盘。
    ///
    /// 实测（Release，含表格与图片的 200KB 语料）：不做这层复用时属性应用 349ms、
    /// 1MB 全管线 4025ms；做完是 245ms / 2151ms。
    private final class StyleContext {
        struct ResolvedImage {
            let url: URL
            let image: NSImage
        }

        let imageBaseURL: URL?
        private let storage: NSTextStorage
        private let package: Package
        private var cachedSource: NSString?
        private var resolvedImages: [String: ResolvedImage?] = [:]

        init(storage: NSTextStorage, package: Package, imageBaseURL: URL?) {
            self.storage = storage
            self.package = package
            self.imageBaseURL = imageBaseURL
        }

        var source: NSString {
            if let cachedSource { return cachedSource }
            let source = storage.string as NSString
            cachedSource = source
            return source
        }

        /// 落在 `span` 内、渲染态会被折叠的行内标记区间。
        ///
        /// `package.tokens` 本来就按 `markerRange.lowerBound` 升序，所以二分定位起点、
        /// 顺序取到出界即可——不要在这里按整篇 filter/sort：那是 O(表数 × token 数)，
        /// 实测把 200KB 的脏行增量应用从 0.5ms 拖到 17.8ms（输入热路径的预算是 16ms）。
        func hiddenInlineRanges(in span: Range<Int>) -> [Range<Int>] {
            let tokens = package.tokens
            var low = 0
            var high = tokens.count
            while low < high {
                let mid = (low + high) / 2
                if tokens[mid].markerRange.lowerBound < span.lowerBound { low = mid + 1 } else { high = mid }
            }
            var result: [Range<Int>] = []
            var index = low
            while index < tokens.count, tokens[index].markerRange.lowerBound < span.upperBound {
                let token = tokens[index]
                if !token.isBlockMarker {
                    result.append(contentsOf: token.allMarkerRanges)
                }
                index += 1
            }
            return result
        }

        /// 目的地 → 本地文件与图片，按次渲染记忆（包括负结果）。
        func image(destination: String) -> ResolvedImage? {
            if let cached = resolvedImages[destination] { return cached }
            let resolved = ImageResolver.resolvedURL(destination: destination, baseURL: imageBaseURL)
                .flatMap { url -> ResolvedImage? in
                    guard let image = ImageResolver.loadLocalImage(url: url) else { return nil }
                    return ResolvedImage(url: url, image: image)
                }
            resolvedImages[destination] = resolved
            return resolved
        }
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: theme.baseFont(),
            .foregroundColor: theme.text,
            .paragraphStyle: theme.baseParagraph(),
        ]
    }

    private func sourceAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: theme.codeFont(),
            .foregroundColor: theme.text,
            .paragraphStyle: theme.baseParagraph(),
        ]
    }

    private func applyStyle(
        _ token: Token,
        package: Package,
        into storage: NSTextStorage,
        context: StyleContext
    ) {
        let index = package.index

        // 无内容 token（分隔线）在 content guard 之前处理。
        if token.kind == .rule {
            // 分隔线：标记隐藏 + 上下留白；真实横线由 MuseLayoutFragment 绘制。
            storage.addAttributes([
                .paragraphStyle: theme.ruleParagraph(),
                .museBlock: BlockVisual.rule.rawValue,
            ], range: index.nsRange(package.lineStarts[token.line]..<token.markerRange.upperBound))
            return
        }

        guard let content = token.contentRange.map(index.nsRange) else { return }

        // 段落级样式必须覆盖整行（含 marker 字符）：NSTextStorage 的段落样式修复
        // （fixParagraphStyleAttribute）会把"同段内不一致的段落样式"统一——若 marker
        // 字符仍带 base 样式，整段会被修回 base，悬挂缩进/引用/标题间距全部失效。
        let wholeLine = { () -> NSRange in
            let end = token.contentRange?.upperBound ?? token.markerRange.upperBound
            let start = token.isBlockMarker ? package.lineStarts[token.line] : token.markerRange.lowerBound
            return index.nsRange(start..<end)
        }()
        let markerNS = index.nsRange(token.markerRange)
        let lineStart = index.utf16Offset(package.lineStarts[token.line])
        let listMarkerAttributes: [NSAttributedString.Key: Any] = [
            .museListMarkerLocation: NSNumber(value: markerNS.location - lineStart),
            .museListMarkerLength: NSNumber(value: markerNS.length),
        ]

        func listParagraph(depth: Int) -> NSParagraphStyle {
            let prefixRange = NSRange(
                location: lineStart,
                length: markerNS.location - lineStart + markerNS.length
            )
            return theme.listParagraph(
                depth: depth,
                sourcePrefixText: context.source.substring(with: prefixRange)
            )
        }

        switch token.kind {
        case .heading(let level):
            storage.addAttributes([
                .font: theme.titleFont(level: level),
                .paragraphStyle: theme.headingParagraph(level: level),
                .museBlock: BlockVisual.heading.rawValue,
            ], range: wholeLine)

        case let .unorderedListItem(depth):
            storage.addAttributes(listMarkerAttributes.merging([
                .paragraphStyle: listParagraph(depth: depth),
                .museBlock: BlockVisual.list.rawValue + ":u",
                .museListDepth: NSNumber(value: depth),
            ]) { _, new in new }, range: wholeLine)

        case let .orderedListItem(depth, number):
            storage.addAttributes(listMarkerAttributes.merging([
                .paragraphStyle: listParagraph(depth: depth),
                .museBlock: BlockVisual.list.rawValue + ":o",
                .museListDepth: NSNumber(value: depth),
                .museListNumber: NSNumber(value: number),
            ]) { _, new in new }, range: wholeLine)

        case let .taskListItem(depth, checked):
            storage.addAttributes(listMarkerAttributes.merging([
                .paragraphStyle: listParagraph(depth: depth),
                .museBlock: BlockVisual.list.rawValue + ":t",
                .museListDepth: NSNumber(value: depth),
                .museTaskChecked: NSNumber(value: checked),
            ]) { _, new in new }, range: wholeLine)
            // [ ] / [x] 用代码字体区分（源码模式下可见；渲染态被折叠字体覆盖）。
            storage.addAttributes([.font: theme.codeFont()], range: index.nsRange(token.markerRange))

        case .blockquote:
            storage.addAttributes([
                .foregroundColor: theme.quoteText,
                .paragraphStyle: theme.quoteParagraph(),
                .backgroundColor: theme.quoteBackground,
            ], range: wholeLine)
            // 块标记覆盖整行（含 "> " marker 字符）：绘制层在行首即可读到。
            let lineEnd = token.contentRange?.upperBound ?? token.markerRange.upperBound
            storage.addAttributes(
                [.museBlock: BlockVisual.quote.rawValue],
                range: index.nsRange(package.lineStarts[token.line]..<lineEnd)
            )

        case .codeFence:
            // 闭栏行也纳入整块样式（开栏行用弱化色 + 背景作为语法提示，不隐藏）。
            var upper = token.contentRange?.upperBound ?? token.markerRange.upperBound
            var lastBlockLine = token.line
            if let contentEnd = token.contentRange?.upperBound, contentEnd < package.index.utf8Length {
                // 闭合行（content 终止处所在行）整行并入样式
                let closeLine = lineIndex(atUTF8: contentEnd, package: package)
                // lineEndUTF8 同时覆盖“闭栏行是最后一行”和“闭栏行后还有内容”两种情况。
                upper = max(upper, lineEndUTF8(closeLine, package: package))
                lastBlockLine = max(lastBlockLine, closeLine)
            }
            let fullRange = package.lineStarts[token.line]..<upper
            storage.addAttributes([
                .font: theme.codeFont(),
                .foregroundColor: theme.codeText,
                .backgroundColor: theme.codeBackground,
                .museBlock: BlockVisual.codeFence.rawValue,
            ], range: index.nsRange(fullRange))
            storage.addAttributes([
                .font: theme.codeFont(),
                .foregroundColor: theme.markerText,
            ], range: index.nsRange(token.markerRange))

            // 首/末行写块角色与段落样式：绘制层据此画带垂直内边距的圆角背景。
            for line in token.line...lastBlockLine {
                let isFirst = line == token.line
                let isLast = line == lastBlockLine
                let role = switch (isFirst, isLast) {
                case (true, true): "open+close"
                case (true, false): "open"
                case (false, true): "close"
                case (false, false): ""
                }
                var lineAttributes: [NSAttributedString.Key: Any] = [
                    .paragraphStyle: theme.fenceParagraph(isFirstLine: isFirst, isLastLine: isLast)
                ]
                if !role.isEmpty {
                    lineAttributes[.museBlockRole] = role
                }
                storage.addAttributes(
                    lineAttributes,
                    range: index.nsRange(package.lineStarts[line]..<lineEndUTF8(line, package: package))
                )
            }

        case .table(let lastLine):
            applyTableStyle(token, lastLine: lastLine, package: package, into: storage, context: context)

        case .strong:
            // 合并字形特征而非覆盖：嵌套（粗体里的斜体、斜体里的粗体）应得到组合样式。
            let existing = storage.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont ?? theme.baseFont()
            storage.addAttributes([.font: theme.derivedFont(from: existing, adding: .boldFontMask)], range: content)

        case .emphasis:
            let existing = storage.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont ?? theme.baseFont()
            storage.addAttributes([.font: theme.derivedFont(from: existing, adding: .italicFontMask)], range: content)

        case .strikethrough:
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.text,
                .foregroundColor: theme.mutedText,
            ], range: content)

        case .inlineCode:
            storage.addAttributes([
                .font: theme.codeFont(),
                .foregroundColor: theme.codeText,
                .backgroundColor: theme.codeBackground,
            ], range: content)

        case .link:
            storage.addAttributes([
                .foregroundColor: theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.linkColor,
            ], range: content)
            if let destRange = token.linkDestination {
                let destNS = index.nsRange(destRange)
                guard destNS.location >= 0, destNS.location + destNS.length <= storage.length else { return }
                let destString = storage.attributedSubstring(from: destNS).string
                if let url = URL(string: destString) {
                    storage.addAttributes([.link: url], range: content)
                }
            }

        case .image:
            applyImageStyle(token, package: package, into: storage, context: context)

        case .rule:
            break // 已在 content guard 之前处理（分隔线无内容区间）
        }
    }

    // MARK: - 图片

    /// 图片语法的样式与「块图片」判定。
    ///
    /// `![标签](目的地)` 独占一行时按块图片呈现：整行折叠、行高撑到图片的呈现
    /// 高度、图形由 `MuseLayoutFragment` 画在这块保留区里。
    ///
    /// 为什么不用 `NSTextAttachment`：`.attachment` 只在 U+FFFC 上成立——
    /// `NSTextStorage` 的属性修复（`endEditing` → `fixAttachmentAttribute`）会把它
    /// 从任何其他字符上抹掉（实测见 `RendererTests.attachmentAttributeIsStrippedFromOrdinaryCharacter`）。
    /// 而「只写属性、不改字符」不允许插入 U+FFFC，所以行内图片只能走绘制层，
    /// 正是 tech-plan §4.7 给 Phase 2 定的首选路线。
    ///
    /// 夹在正文中间的图片（不独占一行）仍按语法样式呈现：撑高一整行去放一张
    /// 图会毁掉这段的排版，标签保留可读、点击弹预览。
    private func applyImageStyle(
        _ token: Token,
        package: Package,
        into storage: NSTextStorage,
        context: StyleContext
    ) {
        let index = package.index
        let source = context.source
        let markerNS = index.nsRange(token.markerRange)
        let tailNS = token.closingMarkerRange.map(index.nsRange)
        let span = NSRange(
            location: markerNS.location,
            length: (tailNS ?? markerNS).upperBound - markerNS.location
        )
        guard span.location >= 0, span.upperBound <= source.length else { return }

        // 语法样式（两种呈现共用）：`![` 与 `](目的地)` 弱化，标签保持正文色。
        storage.addAttributes([.foregroundColor: theme.mutedText], range: markerNS)
        if let tailNS {
            storage.addAttributes([.foregroundColor: theme.mutedText], range: tailNS)
        }
        guard let destinationRange = token.linkDestination else { return }
        let destination = source.substring(with: index.nsRange(destinationRange))
        storage.addAttributes([.museImageDestination: destination], range: span)

        guard token.isBlockImage else { return }
        let lineNS = index.nsRange(
            package.lineStarts[token.line]..<lineEndUTF8(token.line, package: package)
        )
        guard lineNS.length > 0, lineNS.upperBound <= source.length else { return }

        // 样式层只写「输入」：目的地、解析后的路径、呈现尺寸。块角色与撑高的行高
        // 由显隐层按状态**独家**决定（见 applyInlineImageVisibility）——两处都写过一版，
        // 结果是任一处坏掉都被另一处补上，测试再也测不出问题。
        var attributes: [NSAttributedString.Key: Any] = [.museImageDestination: destination]
        let displaySize: NSSize
        if let resolved = context.image(destination: destination) {
            displaySize = ImageResolver.displaySize(for: resolved.image.size)
            attributes[.museImagePath] = resolved.url.standardizedFileURL.path
        } else {
            // 加载不到（文件缺失或远程地址）：仍然按块呈现，绘制层画一个带
            // 目的地文字的占位框——比把源码摊在正文里更能说明「这里是一张图」。
            displaySize = Theme.imagePlaceholderSize
        }
        attributes[.museImageSize] = [
            NSNumber(value: Double(displaySize.width)),
            NSNumber(value: Double(displaySize.height)),
        ]
        storage.addAttributes(attributes, range: lineNS)
    }

    // MARK: - 表格

    /// GFM 表格：列宽在这里算好写进属性，绘制层照着画单元格线与底色。
    ///
    /// 分工的理由是 fragment 只看得见自己那一行——列宽是**跨行**的最大值，
    /// 绘制层没有能力算，只能由属性层算完随行携带（`.museTableColumns`）。
    private func applyTableStyle(
        _ token: Token,
        lastLine: Int,
        package: Package,
        into storage: NSTextStorage,
        context: StyleContext
    ) {
        let index = package.index
        let fullRange = package.lineStarts[token.line]..<lineEndUTF8(lastLine, package: package)
        // 表格用正文字体（对标 Typora：表格不是代码）；列对齐由 kern 负责，
        // 不再依赖等宽字体去凑源码列。
        storage.addAttributes([
            .font: theme.baseFont(),
            .foregroundColor: theme.text,
            .museBlock: BlockVisual.table.rawValue,
        ], range: index.nsRange(fullRange))

        guard let structure = package.table(headerLine: token.line) else {
            applyPlainTableStyle(from: token.line, to: lastLine, package: package, into: storage)
            return
        }

        let layout = TableLayout.compute(
            structure: structure,
            source: context.source,
            index: index,
            // 单元格里的行内标记（`**`、`` ` `` 等）在渲染态是近零宽的，
            // 度量列宽必须把它们排除掉。
            hiddenRanges: context.hiddenInlineRanges(in: fullRange),
            headerFont: theme.boldFont(),
            bodyFont: theme.baseFont()
        )
        guard layout.isAlignable else {
            // 结构区放不下 kern 的承载字符（完全不留空格的 `|a|b|` 写法）：
            // 列对不齐时不画格线，避免线与文字错位——比硬画一个歪的表格好。
            applyPlainTableStyle(from: token.line, to: lastLine, package: package, into: storage)
            return
        }
        let boundaries = layout.columnBoundaries.map { NSNumber(value: Double($0)) }

        for (rowIndex, row) in structure.rows.enumerated() {
            let lineRange = index.nsRange(
                package.lineStarts[row.line]..<lineEndUTF8(row.line, package: package)
            )
            var attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: theme.tableParagraph(isLast: row.line == lastLine),
                .museTableColumns: boundaries,
                .museTableRow: NSNumber(value: rowIndex),
            ]
            if rowIndex == 0 {
                attributes[.font] = theme.boldFont()
                attributes[.museBlockRole] = "head"
            } else if row.line == lastLine {
                attributes[.museBlockRole] = "close"
            }
            storage.addAttributes(attributes, range: lineRange)
        }

        // 分隔行（`|---|---|`）：整行是表格的 marker，隐藏态折叠成近零宽。
        // 它**不能**带 minimumLineHeight，否则折叠后仍占一整行高度。
        let delimiterStart = package.lineStarts[structure.delimiterLine]
        let delimiterEnd = lineEndUTF8(structure.delimiterLine, package: package)
        let delimiterRange = index.nsRange(delimiterStart..<delimiterEnd)
        storage.addAttributes([
            .paragraphStyle: theme.tableDelimiterParagraph(),
            .foregroundColor: theme.markerText,
            .museBlockRole: "delimiter",
        ], range: delimiterRange)

        // 列内边距挂在每段结构区的首字符上（结构区随 marker 显隐折叠成近零宽）。
        for adjustment in layout.adjustments {
            guard adjustment.range.length > 0,
                  adjustment.range.location + adjustment.range.length <= storage.length else { continue }
            storage.addAttribute(
                .kern,
                value: NSNumber(value: Double(adjustment.kern)),
                range: adjustment.range
            )
        }
    }

    /// 无法对齐成网格时的保守呈现：整块弱化底色 + 表头加粗，不画格线。
    private func applyPlainTableStyle(
        from firstLine: Int,
        to lastLine: Int,
        package: Package,
        into storage: NSTextStorage
    ) {
        let index = package.index
        for line in firstLine...lastLine {
            var attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: theme.tableParagraph(isLast: line == lastLine)
            ]
            if line == firstLine {
                attributes[.font] = theme.boldFont()
                attributes[.museBlockRole] = "head"
            } else if line == firstLine + 1 {
                attributes[.paragraphStyle] = theme.tableDelimiterParagraph()
                attributes[.museBlockRole] = "delimiter"
            } else if line == lastLine {
                attributes[.museBlockRole] = "close"
            }
            storage.addAttributes(
                attributes,
                range: index.nsRange(package.lineStarts[line]..<lineEndUTF8(line, package: package))
            )
        }
    }

    /// 全量写显隐（供 render 使用；增量路径由协调器 diff 后写入）。
    private func applyVisibility(
        package: Package,
        selection: NSRange?,
        into storage: NSTextStorage,
        forceAll: Bool,
        imageBaseURL: URL?
    ) {
        for entry in computedVisibility(package: package, selection: selection) {
            apply(entry, imageBaseURL: imageBaseURL, into: storage, skipHiddenListParagraph: true)
        }
    }

    /// 应用一个显隐条目。
    ///
    /// 块图片、列表、普通 marker 三种条目的写入规则不同，而全量渲染与协调器的
    /// 增量 reconcile 都要用同一套规则——分成两份实现过一次，结果是光标流从不
    /// 走块图片那条路（图片行进出光标时不还原）。只留这一个入口。
    ///
    /// - Parameter skipHiddenListParagraph: 首次全量渲染时 `applyStyle` 已经写好
    ///   了列表的隐藏态段落样式，大文档没必要为每一项重建一次；只有回显态需要
    ///   在这里补偿行首原点。
    public func apply(
        _ entry: VisibilityEntry,
        imageBaseURL: URL?,
        into storage: NSTextStorage,
        skipHiddenListParagraph: Bool = false
    ) {
        if let inline = entry.inlineImageRange {
            applyInlineImageVisibility(
                state: entry.state,
                span: inline,
                markerSubRange: entry.imageMarkerSubRange,
                closingSubRange: entry.imageClosingSubRange,
                imageBaseURL: imageBaseURL,
                into: storage
            )
            return
        }
        if entry.listDepth != nil, !(skipHiddenListParagraph && entry.state == .hidden) {
            applyMarkerVisibility(
                state: entry.state,
                markerNS: entry.markerNS,
                listDepth: entry.listDepth,
                into: storage
            )
            return
        }
        storage.addAttributes(Self.markerVisibilityAttributes(state: entry.state), range: entry.markerNS)
    }

    // MARK: - 区间工具

    /// token 覆盖的行区间。普通 token 从实际 UTF-8 源码范围推导，支持 soft line break。
    private func tokenLineRange(_ token: Token, package: Package) -> ClosedRange<Int> {
        switch token.kind {
        case .codeFence:
            let end = token.contentRange?.upperBound ?? token.markerRange.upperBound
            let closeLine = lineIndex(atUTF8: end, package: package)
            return token.line...closeLine
        case .table(let lastLine):
            return token.line...lastLine
        default:
            let range = token.sourceRange
            let lower = lineIndex(atUTF8: range.lowerBound, package: package)
            let lastByte = range.isEmpty ? range.lowerBound : range.upperBound - 1
            let upper = lineIndex(atUTF8: lastByte, package: package)
            return lower...upper
        }
    }

    func markerIdentity(
        for range: Range<Int>,
        package: Package
    ) -> (line: Int, relOffset: Int) {
        let line = lineIndex(atUTF8: range.lowerBound, package: package)
        return (line, range.lowerBound - package.lineStarts[line])
    }

    private func blockRange(_ token: Token, package: Package) -> NSRange {
        let lines = tokenLineRange(token, package: package)
        let lower = package.lineStarts[lines.lowerBound]
        let upper = lineEndUTF8(lines.upperBound, package: package)
        return package.index.nsRange(lower..<upper)
    }

    private func lineSpan(containing utf16Range: NSRange, package: Package) -> ClosedRange<Int> {
        let lower = lineIndex(atUTF16: utf16Range.location, package: package)
        let upperBound = utf16Range.location + utf16Range.length
        let upper = upperBound > utf16Range.location
            ? lineIndex(atUTF16: upperBound - 1, package: package)
            : lower
        return lower...upper
    }

    private func lineEndUTF8(_ line: Int, package: Package) -> Int {
        if line + 1 < package.lineStarts.count {
            // 行尾 = 下一行起点（含换行符），增量重置把换行符本身也算进本带。
            return package.lineStarts[line + 1]
        }
        return package.index.utf8Length
    }

    private func lineIndex(atUTF16 location: Int, package: Package) -> Int {
        lineIndex(atUTF8: package.index.utf8Offset(location), package: package)
    }

    private func lineIndex(atUTF8 offset: Int, package: Package) -> Int {
        var lo = 0
        var hi = package.lineStarts.count - 1
        let clamped = min(max(offset, 0), package.index.utf8Length)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if package.lineStarts[mid] <= clamped {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// 空选区（纯光标）按"落在区间内"判定（上界开区间：紧贴区间右端不算触及），
    /// 非空选区按区间相交判定。
    private func touches(_ range: NSRange, selection: NSRange) -> Bool {
        if selection.length == 0 {
            return selection.location >= range.location && selection.location < range.location + range.length
        }
        let rangeEnd = range.location + range.length
        let selectionEnd = selection.location + selection.length
        return range.location < selectionEnd && selection.location < rangeEnd
    }
}
