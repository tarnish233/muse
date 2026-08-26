import Foundation

/// M0 版源码 token 扫描器：按行扫描，输出 UTF-8 字节区间。
///
/// 职责边界（v0.2 4.1）：这里只做"精确源码定位"，不做语义判读——
/// 语义 AST（swift-markdown）在 M2 引入；M0 的扫描规则刻意保持简单，行为由单元测试固化。
/// 支持：ATX 标题、列表（无序/有序/任务）、引用、代码围栏、粗体、斜体、行内代码、删除线、
/// 转义字符（跳过 \\x）、未闭合语法（不生成 token，保持记号可见）。
///
/// 已知简化（M0/M1 接受，M2 处理）：
/// - 强调分隔符不做 CommonMark 式 run 分析：
///   `***` 按 `**`+`*` 处理；单星号闭合查找不区分内部 `**` run，
///   因此 `*a **b** c*` 解析为三段单星强调，而非"斜体包粗体"；
/// - 行内扫描以行为界（不跨软换行）、链接语法未参与。
/// nonisolated：在后台解析任务中运行。
nonisolated struct TokenScanner {
    struct Line {
        /// 本行内容 [start, end)，不含换行符；next 为下一行起点（= end + 换行宽度）。
        let start: Int
        let end: Int
        let next: Int
        let index: Int
    }

    func scan(_ source: String) -> [Token] {
        let bytes = Array(source.utf8)
        let lines = lines(source)
        var tokens: [Token] = []

        var inFence = false
        // 开栏状态：token 下标 + 正文起点（= 开栏行行尾换行符之后）。
        var openFenceToken = 0
        var openFenceBodyStart = 0

        for line in lines {
            let isFenceLine = scanFenceMarker(bytes, line)
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
                scanBlockAndInline(bytes, line, into: &tokens)
            } else if isFenceLine != nil {
                inFence = false
                // 闭合围栏：内容 = 开栏行行尾之后 到 闭合行行首（M0 简化，闭合行样式并入整块）。
                let bodyEnd = line.start
                let bodyStart = max(openFenceBodyStart, bodyEnd)
                let open = tokens[openFenceToken]
                tokens[openFenceToken] = Token(
                    kind: .codeFence,
                    markerRange: open.markerRange,
                    closingMarkerRange: nil,
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
        return tokens
    }

    // MARK: - 行结构

    /// 每行字节区间，供渲染层计算"光标所在行"。
    func lines(_ source: String) -> [Line] {
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

    /// 行首代码围栏：``` 起 3 个及以上反引号（允许 ≤3 空格缩进）。返回 marker 区间。
    private func scanFenceMarker(_ bytes: [UInt8], _ line: Line) -> Range<Int>? {
        var i = line.start
        let indentLimit = min(line.start + 3, line.end)
        while i < indentLimit, bytes[i] == 0x20 { i += 1 }
        guard i < line.end, bytes[i] == 0x60 else { return nil }
        let runStart = i
        while i < line.end, bytes[i] == 0x60 { i += 1 }
        guard i - runStart >= 3 else { return nil }
        return runStart..<i
    }

    private func scanBlockAndInline(_ bytes: [UInt8], _ line: Line, into tokens: inout [Token]) {
        var i = line.start
        let indentLimit = min(line.start + 3, line.end)
        while i < indentLimit, bytes[i] == 0x20 { i += 1 }
        guard i < line.end else { return }

        let b = bytes[i]

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
                scanInline(bytes, range: markerEnd..<line.end, line: line.index, into: &tokens)
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
                scanInline(bytes, range: (i + 6)..<line.end, line: line.index, into: &tokens)
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
            scanInline(bytes, range: (i + 2)..<line.end, line: line.index, into: &tokens)
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
                scanInline(bytes, range: (j + 2)..<line.end, line: line.index, into: &tokens)
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
            scanInline(bytes, range: markerEnd..<line.end, line: line.index, into: &tokens)
            return
        }

        // 普通段落：行内扫描
        scanInline(bytes, range: line.start..<line.end, line: line.index, into: &tokens)
    }

    // MARK: - 行内

    private func scanInline(_ bytes: [UInt8], range: Range<Int>, line: Int, into tokens: inout [Token]) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
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
                    i = close + runLen
                    continue
                }
                i += runLen
                continue
            }
            if b == 0x2A { // *
                let runLen = runLength(of: 0x2A, at: i, in: bytes, upTo: end)
                if runLen >= 2 {
                    if let close = findSequence(0x2A, 0x2A, from: i + 2, in: bytes, upTo: end) {
                        tokens.append(Token(
                            kind: .strong,
                            markerRange: i..<(i + 2),
                            closingMarkerRange: close..<(close + 2),
                            contentRange: (i + 2)..<close,
                            line: line
                        ))
                        scanInline(bytes, range: (i + 2)..<close, line: line, into: &tokens)
                        i = close + 2
                        continue
                    }
                    i += runLen
                    continue
                }
                if let close = findScalar(0x2A, from: i + 1, in: bytes, upTo: end) {
                    tokens.append(Token(
                        kind: .emphasis,
                        markerRange: i..<(i + 1),
                        closingMarkerRange: close..<(close + 1),
                        contentRange: (i + 1)..<close,
                        line: line
                    ))
                    scanInline(bytes, range: (i + 1)..<close, line: line, into: &tokens)
                    i = close + 1
                    continue
                }
                i += 1
                continue
            }
            if b == 0x7E, i + 1 < end, bytes[i + 1] == 0x7E { // ~~
                if let close = findSequence(0x7E, 0x7E, from: i + 2, in: bytes, upTo: end) {
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

    private func findScalar(_ byte: UInt8, from start: Int, in bytes: [UInt8], upTo end: Int) -> Int? {
        var i = start
        while i < end {
            if bytes[i] == 0x5C { // \ 转义：跳过一对
                i += 2
                continue
            }
            if bytes[i] == byte { return i }
            i += 1
        }
        return nil
    }

    private func findSequence(_ a: UInt8, _ b: UInt8, from start: Int, in bytes: [UInt8], upTo end: Int) -> Int? {
        var i = start
        while i + 1 < end {
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
