import AppKit

/// M2-lite 渲染引擎：AST 语义之外的"属性层"。
/// 铁律（v0.2）：只写属性、不改字符 —— 不改字符数、不插入附件字符。
///
/// 两条应用路径：
/// - `render`：整篇全量应用（首次装载/基准测试；同步）。
/// - `applyDirty`：只重置+重排受影响行的属性（输入热路径；配合后台解析见 RenderCoordinator）。
/// 行级粒度与线式 tokenizer 一致（行内语法以行为界），是"变化块增量"的第一版近似。
public struct RenderEngine {
    private final class ScanResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var tokens: [Token] = []
    }

    private final class IndexResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var index: SourceIndex?
    }

    /// 后台解析产物：纯值、Sendable，可跨线程（v0.2 RenderSnapshot 的第一版形态）。
    public nonisolated struct Package: Sendable {
        public let tokens: [Token]
        public let index: SourceIndex
        /// 每行起点的 UTF-8 字节偏移。
        public let lineStarts: [Int]

        public init(tokens: [Token], index: SourceIndex, lineStarts: [Int]) {
            self.tokens = tokens
            self.index = index
            self.lineStarts = lineStarts
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
        let speculativeScan = ScanResult()
        let speculativeIndex = IndexResult()
        DispatchQueue.global(qos: .userInitiated).async {
            speculativeScan.tokens = TokenScanner().scan(source)
            speculativeScan.semaphore.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            speculativeIndex.index = SourceIndex(source)
            speculativeIndex.semaphore.signal()
        }
        let sourceLines = scanner.lines(source)
        let lineStarts = sourceLines.map(\.start)

        // AST 是语义与源码定位的唯一来源。即使文档没有链接或深层缩进，也必须
        // 构建语义层，避免候选行短路让同一 Markdown 在不同输入形态下走两套规则。
        let semantics = MarkdownSemantics(source, lines: sourceLines)
        speculativeScan.semaphore.wait()
        var tokens = speculativeScan.tokens

        // 普通行的 scanner 结果与 AST 的块结论一致时直接复用并行结果；链接保护区
        // 或 AST 确认的扩展缩进存在时再用完整语义参数重扫，保证这些边界不靠猜测。
        if !semantics.links.isEmpty || requiresSemanticRescan(source, semantics: semantics, lines: sourceLines) {
            tokens = scanner.scan(
                source,
                excludingRanges: semantics.links.flatMap(\.inertRanges),
                semanticListLines: semantics.listItemLines,
                semanticQuoteLines: semantics.quoteLines,
                semanticFenceLines: semantics.fenceLines
            )
        }
        speculativeIndex.semaphore.wait()

        var unorderedDepthByLine: [Int: Int] = [:]
        var orderedInfoByLine: [Int: (depth: Int, number: Int)] = [:]
        var taskInfoByLine: [Int: (depth: Int, checked: Bool)] = [:]
        var quoteDepthByLine: [Int: Int] = [:]
        for block in semantics.blocks {
            switch block.kind {
            case let .unorderedList(depth):
                unorderedDepthByLine[block.line] = depth
            case let .orderedList(depth, number):
                orderedInfoByLine[block.line] = (depth, number)
            case let .taskList(depth, checked):
                taskInfoByLine[block.line] = (depth, checked)
            case let .blockquote(depth):
                quoteDepthByLine[block.line] = depth
            case .heading, .codeFence:
                break
            }
        }
        tokens = tokens.map { token in
            switch token.kind {
            case .unorderedListItem:
                guard let depth = unorderedDepthByLine[token.line] else { return token }
                return replacing(token, kind: .unorderedListItem(depth: depth))
            case .orderedListItem:
                guard let info = orderedInfoByLine[token.line] else { return token }
                return replacing(token, kind: .orderedListItem(depth: info.depth, number: info.number))
            case .taskListItem:
                guard let info = taskInfoByLine[token.line] else { return token }
                return replacing(token, kind: .taskListItem(depth: info.depth, checked: info.checked))
            case .blockquote:
                guard let depth = quoteDepthByLine[token.line] else { return token }
                return replacing(token, kind: .blockquote(depth: depth))
            default:
                return token
            }
        }

        for link in semantics.links {
            tokens.append(Token(
                kind: .link,
                markerRange: link.openBracket,
                closingMarkerRange: link.tail,
                contentRange: link.label,
                linkDestination: link.destination,
                line: lineIndex(ofByte: link.label.lowerBound, lineStarts: lineStarts)
            ))
        }
        tokens.sort { $0.markerRange.lowerBound < $1.markerRange.lowerBound }

        return Package(tokens: tokens, index: speculativeIndex.index!, lineStarts: lineStarts)
    }

    private nonisolated func replacing(_ token: Token, kind: Token.Kind) -> Token {
        Token(
            kind: kind,
            markerRange: token.markerRange,
            closingMarkerRange: token.closingMarkerRange,
            contentRange: token.contentRange,
            linkDestination: token.linkDestination,
            line: token.line
        )
    }

    private nonisolated func requiresSemanticRescan(
        _ source: String,
        semantics: MarkdownSemantics,
        lines: [TokenScanner.Line]
    ) -> Bool {
        guard !semantics.blocks.isEmpty else { return false }
        let bytes = Array(source.utf8)
        for block in semantics.blocks {
            guard block.line < lines.count else { continue }
            let line = lines[block.line]
            var index = line.start
            while index < line.end, bytes[index] == 0x20 || bytes[index] == 0x09 {
                index += 1
            }
            if index - line.start > 3 || bytes[line.start..<index].contains(0x09) {
                return true
            }
        }
        return false
    }

    private nonisolated func lineIndex(ofByte offset: Int, lineStarts: [Int]) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    // MARK: - 全量渲染（首次装载/基准）

    public func render(package: Package, selection: NSRange?, into storage: NSTextStorage) -> Stats {
        let full = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes(), range: full)
        for token in package.tokens {
            applyStyle(token, package: package, into: storage)
        }
        applyVisibility(package: package, selection: selection, into: storage, forceAll: true)
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
        into storage: NSTextStorage
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

        storage.beginEditing()
        storage.setAttributes(baseAttributes(), range: span)
        for token in package.tokens where tokenLineRange(token, package: package).overlaps(dirtyLines) {
            applyStyle(token, package: package, into: storage)
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
        let oldFences = fenceRanges(of: previousPackage)
        let newFences = fenceRanges(of: package)
        let oldQuotes = quoteLines(of: previousPackage)
        let newQuotes = quoteLines(of: package)

        // 围栏整块：旧/新围栏与脏区相接（含相邻 1 行）→ 整块纳入。
        // 重复直到稳定（围栏串接的场景），纯区间运算，必然终止。
        var extended = true
        while extended {
            extended = false
            for fence in oldFences + newFences
            where fence.lowerBound <= dirtyLines.upperBound + 1 && dirtyLines.lowerBound <= fence.upperBound + 1 {
                guard !dirtyLines.contains(fence.lowerBound) else { continue }
                dirtyLines = min(dirtyLines.lowerBound, fence.lowerBound)...max(dirtyLines.upperBound, fence.upperBound)
                extended = true
            }
        }

        // 引用归属变化（编辑是局部的，只查脏区邻近行）
        let lastLine = package.lineStarts.count - 1
        let near = max(0, dirtyLines.lowerBound - 2)...min(lastLine, dirtyLines.upperBound + 2)
        for line in near where oldQuotes.contains(line) != newQuotes.contains(line) {
            dirtyLines = min(dirtyLines.lowerBound, line)...max(dirtyLines.upperBound, line)
        }
    }

    private func fenceRanges(of package: Package?) -> [ClosedRange<Int>] {
        guard let package else { return [] }
        return package.tokens.filter { $0.kind == .codeFence }.map { tokenLineRange($0, package: package) }
    }

    private func quoteLines(of package: Package?) -> Set<Int> {
        guard let package else { return [] }
        return Set(package.tokens.compactMap { token in
            if case .blockquote = token.kind { return token.line }
            return nil
        })
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
    }

    /// 纯函数：给定 package 与选区，计算所有 marker 的显隐状态。不触碰 storage。
    public func computedVisibility(package: Package, selection: NSRange?) -> [VisibilityEntry] {
        func makeEntries(_ token: Token, state: MarkerState) -> [VisibilityEntry] {
            token.allMarkerRanges.map { range in
                VisibilityEntry(
                    line: token.line,
                    markerRelOffset: range.lowerBound - package.lineStarts[token.line],
                    markerNS: package.index.nsRange(range),
                    state: state
                )
            }
        }

        func defaultState(_ token: Token) -> MarkerState {
            .hidden
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
                if token.kind == .codeFence {
                    onCaret = tokenLineRange(token, package: package).contains(caretLine) // 光标在围栏块任意行
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

    // MARK: - 样式

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: theme.baseFont(),
            .foregroundColor: theme.text,
            .paragraphStyle: theme.baseParagraph(),
        ]
    }

    private func applyStyle(_ token: Token, package: Package, into storage: NSTextStorage) {
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

        switch token.kind {
        case .heading(let level):
            storage.addAttributes([
                .font: theme.titleFont(level: level),
                .paragraphStyle: theme.headingParagraph(level: level),
            ], range: wholeLine)

        case let .unorderedListItem(depth):
            storage.addAttributes([
                .paragraphStyle: theme.listParagraph(depth: depth),
                .museBlock: BlockVisual.list.rawValue + ":u",
                .museListDepth: NSNumber(value: depth),
            ], range: wholeLine)

        case let .orderedListItem(depth, number):
            storage.addAttributes([
                .paragraphStyle: theme.listParagraph(depth: depth),
                .museBlock: BlockVisual.list.rawValue + ":o",
                .museListDepth: NSNumber(value: depth),
                .museListNumber: NSNumber(value: number),
            ], range: wholeLine)

        case let .taskListItem(depth, _):
            storage.addAttributes([
                .paragraphStyle: theme.listParagraph(depth: depth),
                .museBlock: BlockVisual.list.rawValue + ":t",
                .museListDepth: NSNumber(value: depth),
            ], range: wholeLine)
            // [ ] / [x] 用代码字体区分（点击切换留到 M4）。
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
            if let contentEnd = token.contentRange?.upperBound, contentEnd < package.index.utf8Length {
                // 闭合行（content 终止处所在行）整行并入样式
                let closeLine = lineIndex(atUTF8: contentEnd, package: package)
                // lineEndUTF8 同时覆盖“闭栏行是最后一行”和“闭栏行后还有内容”两种情况。
                upper = max(upper, lineEndUTF8(closeLine, package: package))
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

        case .rule:
            break // 已在 content guard 之前处理（分隔线无内容区间）
        }
    }

    /// 全量写显隐（供 render 使用；增量路径由协调器 diff 后写入）。
    private func applyVisibility(package: Package, selection: NSRange?, into storage: NSTextStorage, forceAll: Bool) {
        let entries = computedVisibility(package: package, selection: selection)
        for entry in entries {
            storage.addAttributes(Self.markerVisibilityAttributes(state: entry.state), range: entry.markerNS)
        }
    }

    // MARK: - 区间工具

    /// token 覆盖的行区间（代码围栏跨多行，其余 token 单行）。
    private func tokenLineRange(_ token: Token, package: Package) -> ClosedRange<Int> {
        if token.kind == .codeFence {
            let end = token.contentRange?.upperBound ?? token.markerRange.upperBound
            let closeLine = lineIndex(atUTF8: end, package: package)
            return token.line...closeLine
        }
        return token.line...token.line
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
