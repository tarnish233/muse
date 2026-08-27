import Foundation

/// 源码 token 扫描器：按行扫描，输出 UTF-8 字节区间。
///
/// 职责边界（v0.2 4.1）：这里只做"精确源码定位"，不做语义判读——
/// 语义 AST（swift-markdown，M2 引入，见 MarkdownSemantics）提供链接锚点与
/// 行级块分类；本扫描器负责精确的标记字符定位。
/// 支持：ATX 标题、列表（无序/有序/任务）、引用、代码围栏、行内代码、
/// 强调（CommonMark 式分隔符 run 匹配：`*a **b** c*`、`***` 均正确）、
/// 删除线（~ 简单配对）、转义字符（跳过 \\x）、未闭合语法（不生成 token，保持记号可见）。
///
/// 已知简化（M2 接受，后续处理）：
/// - 行内扫描以行为界（不跨软换行）；`_` 不做强调（仅 `*`）；
/// - 链接标签/目的地边界由 MarkdownSemantics 提供，本扫描器只消费保护区间；
/// - 软换行内嵌套块的精确语义以差异测试与 AST 对齐为准。
/// nonisolated：在后台解析任务中运行。
public nonisolated struct TokenScanner {
    public struct Line {
        /// 本行内容 [start, end)，不含换行符；next 为下一行起点（= end + 换行宽度）。
        public let start: Int
        public let end: Int
        public let next: Int
        public let index: Int
    }

    /// - Parameters:
    ///   - excludingRanges: 行内扫描的保护区间（如链接目的地区域），
    ///     其中的标记字符不做任何解析（UTF-8 字节）。
    ///   - semanticListLines / semanticQuoteLines / semanticFenceLines:
    ///     由 swift-markdown AST 提供的结构行。CommonMark 的列表/引用可以有
    ///     超过 3 个空格或使用 tab 缩进；扫描器只在 AST 已确认的行上放宽缩进，
    ///     避免把普通缩进代码误判为列表。
    public init() {}

    public func scan(
        _ source: String,
        excludingRanges: [Range<Int>] = [],
        semanticListLines: Set<Int> = [],
        semanticQuoteLines: Set<Int> = [],
        semanticFenceLines: Set<Int> = []
    ) -> [Token] {
        let bytes = Array(source.utf8)
        let lines = lines(source)
        var tokens: [Token] = []

        var inFence = false
        // 开栏状态：token 下标 + 正文起点（= 开栏行行尾换行符之后）。
        var openFenceToken = 0
        var openFenceBodyStart = 0

        for line in lines {
            let isFenceLine = scanFenceMarker(
                bytes,
                line,
                allowExtendedIndent: semanticFenceLines.contains(line.index)
            )
            if !inFence {
                if let fence = isFenceLine {
                    inFence = true
                    tokens.append(Token(
                        kind: .codeFence,
                        markerRange: fence,
                        closingMarkerRange: nil,
                        contentRange: nil,
                        line: line.index
                    ))
                    openFenceToken = tokens.count - 1
                    openFenceBodyStart = line.next
                    continue
                }
                scanBlockAndInline(
                    bytes,
                    line,
                    excludingRanges: excludingRanges,
                    allowExtendedIndent: semanticListLines.contains(line.index)
                        || semanticQuoteLines.contains(line.index),
                    into: &tokens
                )
            } else if isFenceLine != nil {
                inFence = false
                // 闭合围栏：内容 = 开栏行行尾之后 到 闭合行行首（M0 简化，闭合行样式并入整块）。
                let bodyStart = max(openFenceBodyStart, line.start)
                let open = tokens[openFenceToken]
                tokens[openFenceToken] = Token(
                    kind: .codeFence,
                    markerRange: open.markerRange,
                    closingMarkerRange: isFenceLine,
                    contentRange: openFenceBodyStart..<bodyStart,
                    line: open.line
                )
            }
        }
        // 未闭合围栏：内容一直延伸到文档末尾。
        if inFence {
            let open = tokens[openFenceToken]
            tokens[openFenceToken] = Token(
                kind: .codeFence,
                markerRange: open.markerRange,
                closingMarkerRange: nil,
                contentRange: openFenceBodyStart..<bytes.count,
                line: open.line
            )
        }

        // 按位置排序：嵌套行内（如 ***）外层先应用，风格合并顺序稳定。
        tokens.sort { $0.markerRange.lowerBound < $1.markerRange.lowerBound }
        return tokens
    }

    // MARK: - 行结构

    /// 每行字节区间，供渲染层计算"光标所在行"。
    public func lines(_ source: String) -> [Line] {
        computeLines(Array(source.utf8))
    }

    private func computeLines(_ bytes: [UInt8]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var index = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x0A { // \n
                lines.append(Line(start: start, end: i, next: i + 1, index: index))
                start = i + 1
                index += 1
            } else if b == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { // \r\n
                lines.append(Line(start: start, end: i, next: i + 2, index: index))
                start = i + 2
                index += 1
                i += 1 // 连同 \r 一起跳过，外层 i += 1 跳过 \n
            }
            i += 1
        }
        lines.append(Line(start: start, end: bytes.count, next: bytes.count, index: index))
        return lines
    }

    // MARK: - 块级

    /// 行首代码围栏：``` 起 3 个及以上反引号（允许 ≤3 空格缩进）。
    /// 返回整段围栏行，令 info string 与反引号一起参与显隐。
    private func scanFenceMarker(
        _ bytes: [UInt8],
        _ line: Line,
        allowExtendedIndent: Bool
    ) -> Range<Int>? {
        var i = line.start
        let indentLimit = allowExtendedIndent ? line.end : min(line.start + 3, line.end)
        while i < indentLimit {
            if bytes[i] == 0x20 || (allowExtendedIndent && bytes[i] == 0x09) {
                i += 1
            } else {
                break
            }
        }
        guard i < line.end, bytes[i] == 0x60 else { return nil }
        let runStart = i
        while i < line.end, bytes[i] == 0x60 { i += 1 }
        guard i - runStart >= 3 else { return nil }
        return runStart..<line.end
    }

    private func scanBlockAndInline(
        _ bytes: [UInt8],
        _ line: Line,
        excludingRanges: [Range<Int>],
        allowExtendedIndent: Bool,
        into tokens: inout [Token]
    ) {
        var i = line.start
        let indentLimit = allowExtendedIndent ? line.end : min(line.start + 3, line.end)
        while i < indentLimit {
            if bytes[i] == 0x20 || (allowExtendedIndent && bytes[i] == 0x09) {
                i += 1
            } else {
                break
            }
        }
        guard i < line.end else { return }

        let b = bytes[i]

        // 分隔线：--- / *** / ___ 起 ≥3 个同字符（允许中间夹空格，如 - - -），其后仅空白
        if b == 0x2D || b == 0x2A || b == 0x5F {
            var j = i
            var count = 0
            while j < line.end {
                if bytes[j] == b {
                    count += 1
                    j += 1
                } else if bytes[j] == 0x20 || bytes[j] == 0x09 {
                    j += 1
                } else {
                    break
                }
            }
            if count >= 3, j == line.end {
                tokens.append(Token(
                    kind: .rule,
                    markerRange: i..<j,
                    closingMarkerRange: nil,
                    contentRange: nil,
                    line: line.index
                ))
                return
            }
        }

        // ATX 标题：# 1..6 个 + 空格或行尾
        if b == 0x23 { // #
            var j = i
            while j < line.end, bytes[j] == 0x23, j - i < 6 { j += 1 }
            let level = j - i
            if (j < line.end && bytes[j] == 0x20) || j == line.end {
                let markerEnd = j < line.end ? j + 1 : j
                tokens.append(Token(
                    kind: .heading(level: level),
                    markerRange: i..<markerEnd,
                    closingMarkerRange: nil,
                    contentRange: markerEnd..<line.end,
                    line: line.index
                ))
                // 标题内容同样参与行内语法（# **标题**）
                scanInline(bytes, range: markerEnd..<line.end, line: line.index,
                           excluded: excludingRanges, into: &tokens)
                return
            }
        }

        // 任务列表：-  或 *  + 空格 + [ ] / [x]
        if (b == 0x2D || b == 0x2A || b == 0x2B), i + 2 <= line.end, bytes[i + 1] == 0x20 {
            if b == 0x2D, i + 6 <= line.end,
               bytes[i + 2] == 0x5B, (bytes[i + 3] == 0x20 || bytes[i + 3] == 0x78 || bytes[i + 3] == 0x58),
               bytes[i + 4] == 0x5D, bytes[i + 5] == 0x20 {
                let checked = bytes[i + 3] != 0x20
                tokens.append(Token(
                    kind: .taskListItem(checked: checked),
                    markerRange: i..<(i + 6),
                    closingMarkerRange: nil,
                    contentRange: (i + 6)..<line.end,
                    line: line.index
                ))
                scanInline(bytes, range: (i + 6)..<line.end, line: line.index,
                           excluded: excludingRanges, into: &tokens)
                return
            }
            tokens.append(Token(
                kind: .unorderedListItem,
                markerRange: i..<(i + 2),
                closingMarkerRange: nil,
                contentRange: (i + 2)..<line.end,
                line: line.index
            ))
            // 列表内容参与行内语法（- **粗体**）
            scanInline(bytes, range: (i + 2)..<line.end, line: line.index,
                       excluded: excludingRanges, into: &tokens)
            return
        }

        // 有序列表：1-9 位数字 + . + 空格
        if b >= 0x30, b <= 0x39 {
            var j = i
            while j < line.end, bytes[j] >= 0x30, bytes[j] <= 0x39, j - i < 9 { j += 1 }
            if j - i >= 1, j + 1 < line.end, bytes[j] == 0x2E, bytes[j + 1] == 0x20 {
                tokens.append(Token(
                    kind: .orderedListItem,
                    markerRange: i..<(j + 2),
                    closingMarkerRange: nil,
                    contentRange: (j + 2)..<line.end,
                    line: line.index
                ))
                scanInline(bytes, range: (j + 2)..<line.end, line: line.index,
                           excluded: excludingRanges, into: &tokens)
                return
            }
        }

        // 引用：> + 可选空格
        if b == 0x3E { // >
            let markerEnd = i + 1 < line.end && bytes[i + 1] == 0x20 ? i + 2 : i + 1
            tokens.append(Token(
                kind: .blockquote,
                markerRange: i..<markerEnd,
                closingMarkerRange: nil,
                contentRange: markerEnd..<line.end,
                line: line.index
            ))
            scanInline(bytes, range: markerEnd..<line.end, line: line.index,
                       excluded: excludingRanges, into: &tokens)
            return
        }

        // 普通段落：行内扫描
        scanInline(bytes, range: line.start..<line.end, line: line.index,
                   excluded: excludingRanges, into: &tokens)
    }

    // MARK: - 行内

    private func scanInline(_ bytes: [UInt8], range: Range<Int>, line: Int, excluded: [Range<Int>], into tokens: inout [Token]) {
        // 1) 行内代码 span：先扫并登记保护区间（代码内的 * 不做强调）
        var protected = excluded
        scanCodeSpans(bytes, range: range, line: line, excluded: excluded, into: &tokens, protected: &protected)
        // 2) 强调分隔符 run（CommonMark 式匹配）
        scanStarRuns(bytes, range: range, line: line, protected: protected, into: &tokens)
        // 3) 删除线：~~ 简单配对（GFM 语义，转义感知）
        scanStrikethrough(bytes, range: range, line: line, protected: protected, into: &tokens)
    }

    private func scanCodeSpans(
        _ bytes: [UInt8],
        range: Range<Int>,
        line: Int,
        excluded: [Range<Int>],
        into tokens: inout [Token],
        protected: inout [Range<Int>]
    ) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            if let inert = excluded.first(where: { $0.contains(i) }) {
                i = min(inert.upperBound, end)
                continue
            }
            let b = bytes[i]
            if b == 0x5C { // \ 转义：跳过下一个字符
                i += 2
                continue
            }
            if b == 0x60 { // `
                let runLen = runLength(of: 0x60, at: i, in: bytes, upTo: end)
                if let close = findRun(of: 0x60, length: runLen, from: i + runLen, in: bytes, upTo: end) {
                    tokens.append(Token(
                        kind: .inlineCode,
                        markerRange: i..<(i + runLen),
                        closingMarkerRange: close..<(close + runLen),
                        contentRange: (i + runLen)..<close,
                        line: line
                    ))
                    protected.append(i..<(close + runLen))
                    i = close + runLen
                    continue
                }
                i += runLen
                continue
            }
            i += 1
        }
    }

    /// CommonMark 强调的简化实现：分隔符 run（`*`）+ flanking 判定 + 就近配对 +
    /// mod-3 例外（`*a **b** c*` 的正确解析依赖它）。
    /// 开符从 run 尾消耗、闭符从 run 头消耗（`***foo***` → 内层先成对）。
    private struct StarRun {
        let start: Int
        var remaining: Int
        var openCursor: Int  // 从 run 尾部向前消耗
        var closeCursor: Int // 从 run 头部向后消耗
        let canOpen: Bool
        let canClose: Bool
    }

    private func scanStarRuns(_ bytes: [UInt8], range: Range<Int>, line: Int, protected: [Range<Int>], into tokens: inout [Token]) {
        // 收集
        var runs: [StarRun] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            if !protected.isEmpty, let inert = protected.first(where: { $0.contains(i) }) {
                i = min(inert.upperBound, end)
                continue
            }
            let b = bytes[i]
            if b == 0x5C {
                i += 2
                continue
            }
            if b == 0x2A {
                let start = i
                while i < end, bytes[i] == 0x2A { i += 1 }
                let len = i - start

                let prevClass = charClass(bytes, before: start)
                let nextClass = charClass(bytes, at: i)
                // CommonMark 对 `*`：left-flanking 且（非 right-flanking 或前为标点）→ 可开；
                // right-flanking 且（非 left-flanking 或后为标点）→ 可闭。
                let leftFlanking = !nextClass.whitespace && (!nextClass.punctuation || prevClass.whitespace || prevClass.punctuation)
                let rightFlanking = !prevClass.whitespace && (!prevClass.punctuation || nextClass.whitespace || nextClass.punctuation)
                let canOpen = leftFlanking && (!rightFlanking || prevClass.punctuation)
                let canClose = rightFlanking && (!leftFlanking || nextClass.punctuation)
                if canOpen || canClose {
                    runs.append(StarRun(start: start, remaining: len, openCursor: start + len, closeCursor: start,
                                        canOpen: canOpen, canClose: canClose))
                }
                continue
            }
            i += 1
        }

        // 匹配
        var stack: [Int] = []
        var ci = 0
        while ci < runs.count {
            var matchedThisClose = false
            if runs[ci].canClose, runs[ci].remaining > 0 {
                var search = stack.count - 1
                while search >= 0 {
                    let oi = stack[search]
                    if runs[oi].remaining > 0, mod3OK(runs[oi], runs[ci]) {
                        let use = (runs[oi].remaining >= 2 && runs[ci].remaining >= 2) ? 2 : 1
                        let openStart = runs[oi].openCursor - use
                        let openEnd = runs[oi].openCursor
                        let closeStart = runs[ci].closeCursor
                        let closeEnd = closeStart + use
                        runs[oi].remaining -= use
                        runs[oi].openCursor -= use
                        runs[ci].remaining -= use
                        runs[ci].closeCursor += use
                        tokens.append(Token(
                            kind: use == 2 ? .strong : .emphasis,
                            markerRange: openStart..<openEnd,
                            closingMarkerRange: closeStart..<closeEnd,
                            contentRange: openEnd..<closeStart,
                            line: line
                        ))
                        if runs[oi].remaining == 0 || !runs[oi].canOpen {
                            stack.remove(at: search)
                        }
                        matchedThisClose = true
                        break
                    }
                    search -= 1
                }
                // 同一闭合 run 还有剩余且可闭合 → 再次尝试（嵌套，如 ***）
                if matchedThisClose, runs[ci].remaining > 0, runs[ci].canClose {
                    continue
                }
            }
            if runs[ci].canOpen, runs[ci].remaining > 0 {
                stack.append(ci)
            }
            ci += 1
        }
    }

    private func scanStrikethrough(_ bytes: [UInt8], range: Range<Int>, line: Int, protected: [Range<Int>], into tokens: inout [Token]) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            if !protected.isEmpty, let inert = protected.first(where: { $0.contains(i) }) {
                i = min(inert.upperBound, end)
                continue
            }
            let b = bytes[i]
            if b == 0x5C {
                i += 2
                continue
            }
            if b == 0x7E, i + 1 < end, bytes[i + 1] == 0x7E { // ~~
                if let close = findSequence(0x7E, 0x7E, from: i + 2, in: bytes, upTo: end, protected: protected) {
                    tokens.append(Token(
                        kind: .strikethrough,
                        markerRange: i..<(i + 2),
                        closingMarkerRange: close..<(close + 2),
                        contentRange: (i + 2)..<close,
                        line: line
                    ))
                    i = close + 2
                    continue
                }
            }
            i += 1
        }
    }

    /// mod-3 例外（CommonMark）：当某一侧分隔符 run 既可开又可闭时，
    /// 两侧长度之和不能是 3 的倍数（除非两侧长度都是 3 的倍数）。
    private func mod3OK(_ opener: StarRun, _ closer: StarRun) -> Bool {
        if !(opener.canOpen && opener.canClose) && !(closer.canOpen && closer.canClose) {
            return true
        }
        let sum = opener.remaining + closer.remaining
        if sum % 3 != 0 { return true }
        return opener.remaining % 3 == 0 && closer.remaining % 3 == 0
    }

    // MARK: - 字符分类

    private struct CharClass {
        let whitespace: Bool
        let punctuation: Bool
    }

    private static let whitespaceSet = CharacterSet.whitespacesAndNewlines
    /// 按标点类参与 flanking 判定的字符集。有意偏离 CommonMark 的"词内限制"：
    /// 补充 CJK 表意文字/假名/谚文/全角符号为"标点类"——中文没有空格分词，
    /// 用户普遍期望 `**强调**直接`（闭合符后紧跟汉字）能成对。
    /// 拉丁词内（`a*b*c`）仍按 CommonMark 保持字面量。
    /// 进程级单例：构建含数万标量的 CharacterSet 约 20–30ms，不能每次扫描重建。
    private static let punctuationSet: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        // 符号（含 emoji：So 类）按标点类参与 flanking：`😀**粗**` 需要能加粗
        set.formUnion(CharacterSet.symbols)
        let ranges: [ClosedRange<UInt32>] = [
            0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK 扩展 A/基本/兼容
            0x20000...0x2A6DF,                                  // CJK 扩展 B
            0x3040...0x30FF,                                    // 平假名/片假名
            0xAC00...0xD7AF,                                    // 谚文
            0xFF00...0xFFEF,                                    // 全角/半角形式
        ]
        for range in ranges {
            let scalars: [Unicode.Scalar] = range.compactMap { Unicode.Scalar($0) }
            set.insert(charactersIn: String(String.UnicodeScalarView(scalars)))
        }
        return set
    }()

    /// index 前一字符的类别；行/文档边界视为空白。
    private func charClass(_ bytes: [UInt8], before index: Int) -> CharClass {
        var i = index - 1
        if i < 0 { return CharClass(whitespace: true, punctuation: false) }
        while i > 0, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        let len = utf8SequenceLength(bytes[i]) ?? 1
        guard i + len <= bytes.count else { return CharClass(whitespace: true, punctuation: false) }
        let scalar = String(decoding: bytes[i..<(i + len)], as: UTF8.self).unicodeScalars.first
        return classify(scalar)
    }

    /// index 处字符的类别；文档边界视为空白。
    private func charClass(_ bytes: [UInt8], at index: Int) -> CharClass {
        guard index < bytes.count else { return CharClass(whitespace: true, punctuation: false) }
        let len = utf8SequenceLength(bytes[index]) ?? 1
        guard index + len <= bytes.count else { return CharClass(whitespace: true, punctuation: false) }
        let scalar = String(decoding: bytes[index..<(index + len)], as: UTF8.self).unicodeScalars.first
        return classify(scalar)
    }

    private func classify(_ scalar: Unicode.Scalar?) -> CharClass {
        guard let scalar else { return CharClass(whitespace: true, punctuation: false) }
        return CharClass(whitespace: Self.whitespaceSet.contains(scalar), punctuation: Self.punctuationSet.contains(scalar))
    }

    private func utf8SequenceLength(_ lead: UInt8) -> Int? {
        if lead < 0x80 { return 1 }
        if lead & 0xE0 == 0xC0 { return 2 }
        if lead & 0xF0 == 0xE0 { return 3 }
        if lead & 0xF8 == 0xF0 { return 4 }
        return nil
    }

    // MARK: - 字节工具

    private func runLength(of byte: UInt8, at start: Int, in bytes: [UInt8], upTo end: Int) -> Int {
        var i = start
        while i < end, bytes[i] == byte { i += 1 }
        return i - start
    }

    /// 在 [from, upTo) 内寻找长度恰为 length 的 byte 连续 run，返回其起点。
    /// 转义序列（\x）不参与匹配（被转义的字符不会成为分隔符）。
    private func findRun(of byte: UInt8, length: Int, from start: Int, in bytes: [UInt8], upTo end: Int) -> Int? {
        var i = start
        while i < end {
            if bytes[i] == 0x5C { // \ 转义：跳过一对
                i += 2
                continue
            }
            if bytes[i] == byte {
                let run = runLength(of: byte, at: i, in: bytes, upTo: end)
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// 双字节序列查找，跳过转义对与保护区间。
    private func findSequence(_ a: UInt8, _ b: UInt8, from start: Int, in bytes: [UInt8], upTo end: Int, protected: [Range<Int>]) -> Int? {
        var i = start
        while i + 1 < end {
            if !protected.isEmpty, let inert = protected.first(where: { $0.contains(i) }) {
                i = min(inert.upperBound, end)
                continue
            }
            if bytes[i] == 0x5C { // \ 转义：跳过一对
                i += 2
                continue
            }
            if bytes[i] == a, bytes[i + 1] == b { return i }
            i += 1
        }
        return nil
    }
}
