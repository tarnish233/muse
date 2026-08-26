import Foundation
import Testing

/// P0 风险项：UTF-8 字节偏移 ↔ UTF-16 偏移的转换正确性。
/// 覆盖中文、emoji、ZWJ 序列、组合字符、CRLF 与边界情况。
@Suite struct SourceIndexTests {
    @Test func ascii() {
        let index = SourceIndex("abc")
        #expect(index.utf8Length == 3)
        #expect(index.utf16Length == 3)
        #expect(index.utf16Offset(0) == 0)
        #expect(index.utf16Offset(3) == 3)
        #expect(index.utf8Offset(2) == 2)
    }

    @Test func chinese() throws {
        let string = "你好世界"
        let index = SourceIndex(string)
        #expect(index.utf8Length == 12)
        #expect(index.utf16Length == 4)
        // 每个汉字的 UTF-8 起点
        #expect(index.utf16Offset(0) == 0)
        #expect(index.utf16Offset(3) == 1)
        #expect(index.utf16Offset(6) == 2)
        #expect(index.utf16Offset(9) == 3)
        // 第 3 个汉字（世）的 NSRange
        let range = index.nsRange(6..<9)
        #expect(range == NSRange(location: 2, length: 1))
        // 反向
        #expect(index.utf8Range(NSRange(location: 2, length: 1)) == 6..<9)
    }

    @Test func emoji() {
        // 😀 = 4 UTF-8 字节 = 2 UTF-16 单元
        let index = SourceIndex("a😀b")
        #expect(index.utf8Length == 6)
        #expect(index.utf16Length == 4)
        #expect(index.utf16Offset(1) == 1)   // 😀 起点
        #expect(index.utf16Offset(5) == 3)   // b 起点
        #expect(index.nsRange(1..<5) == NSRange(location: 1, length: 2))
        #expect(index.utf8Range(NSRange(location: 1, length: 2)) == 1..<5)
    }

    @Test func zwjFamilyEmoji() {
        // 👨‍👩‍👧‍👦：4 个 emoji（4×4=16 字节）+ 3 个 ZWJ（3 字节）= 25 字节；UTF-16 = 4×2 + 3×1 = 11 单元
        let string = "x👨‍👩‍👧‍👦y"
        let index = SourceIndex(string)
        #expect(index.utf8Length == 27)
        #expect(index.utf16Length == 13)
        #expect(index.utf16Offset(26) == 12) // y 的起点
        #expect(index.utf8Offset(12) == 26)
    }

    @Test func combiningMarks() {
        // e + U+0301 + x：scalar 边界 0 / 1(ex) / 3(x)
        let index = SourceIndex("e\u{301}x")
        #expect(index.utf16Length == 3)
        #expect(index.utf16Offset(0) == 0)
        #expect(index.utf16Offset(1) == 1) // 组合符起点
        #expect(index.utf16Offset(3) == 2) // x 起点
        // 落在多字节字符中间：向下取整到所在标量起点
        #expect(index.utf16Offset(2) == 1)
        // UTF-16 偏移 2 是合法位置（x 的起点），反查应精确命中
        #expect(index.utf8Offset(2) == 3)
    }

    @Test func crlfAndMultiLine() {
        let index = SourceIndex("a\r\nb\n中文")
        // 字节：a(1) \r(1) \n(1) b(1) \n(1) 中(3) 文(3) = 11；UTF-16：7 单元
        #expect(index.utf8Length == 11)
        #expect(index.utf16Length == 7)
        #expect(index.utf16Offset(3) == 3) // "b" 起点（跳过 \r\n）
        #expect(index.utf16Offset(4) == 4) // b 后的 \n
        #expect(index.utf16Offset(5) == 5) // "中" 起点
        #expect(index.nsRange(5..<8) == NSRange(location: 5, length: 1))
    }

    @Test func emptyAndOutOfBounds() {
        let empty = SourceIndex("")
        #expect(empty.utf8Length == 0)
        #expect(empty.utf16Length == 0)
        #expect(empty.utf16Offset(5) == 0)

        let index = SourceIndex("ab")
        #expect(index.utf16Offset(-3) == 0)   // 越界钳制
        #expect(index.utf16Offset(99) == 2)
        #expect(index.utf8Offset(-1) == 0)
        #expect(index.utf8Offset(99) == 2)
    }

    @Test func surrogatePairMidPoints() {
        // UTF-16 偏移落在 surrogate 对中间 → 归入该 emoji
        let index = SourceIndex("a😀")
        #expect(index.utf8Offset(2) == 1) // 落在低 surrogate 上
    }
}
