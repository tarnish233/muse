import Foundation

/// 在 UTF-8 字节偏移（swift-markdown / cmark 的世界）与 UTF-16 偏移（AppKit 的世界）之间转换。
///
/// 实现：为每个 Unicode scalar 的起始位置建立 (utf8, utf16) 条目表，查询为 O(log n)。
/// M0 直接全量表（200KB 文档约 1～3 MB），需要更省内存时再改为"行缓存 + 行内重走"。
///
/// 非标量边界（落在多字节字符中间、或 surrogate 对中间）的查询按"向下取整到所在标量起点"处理，
/// 由调用方保证 token 边界落在标量边界（tokenizer 只识别 ASCII 标记，天然满足）。
/// nonisolated：在后台解析任务中构建与查询。
public nonisolated struct SourceIndex: Sendable {
    private struct Entry: Sendable {
        let utf8: Int
        let utf16: Int
    }

    private let entries: [Entry]
    public let utf8Length: Int
    public let utf16Length: Int

    public init(_ string: String) {
        let bytes = Array(string.utf8)
        var entries: [Entry] = []
        entries.reserveCapacity(bytes.count / 2 + 2)

        var i = 0
        var utf16 = 0
        while i < bytes.count {
            entries.append(Entry(utf8: i, utf16: utf16))
            let lead = bytes[i]
            let scalarLength: Int
            if lead < 0x80 {
                scalarLength = 1
            } else if lead & 0xE0 == 0xC0 {
                scalarLength = 2
            } else if lead & 0xF0 == 0xE0 {
                scalarLength = 3
            } else {
                scalarLength = 4
            }
            utf16 += scalarLength == 4 ? 2 : 1
            i += scalarLength
        }
        entries.append(Entry(utf8: bytes.count, utf16: utf16)) // 末尾哨兵

        self.entries = entries
        utf8Length = bytes.count
        utf16Length = utf16
    }

    // MARK: - UTF-8 → UTF-16

    /// 字节偏移 → UTF-16 偏移。非边界位置向下取整到所在标量起点；越界钳制到两端。
    public func utf16Offset(_ utf8: Int) -> Int {
        let clamped = min(max(utf8, 0), utf8Length)
        // 向下取整到所在标量起点（落在多字节字符中间时归属该字符）。
        return floorEntry(byUTF8: clamped).utf16
    }

    public func nsRange(_ utf8Range: Range<Int>) -> NSRange {
        let lower = utf16Offset(utf8Range.lowerBound)
        let upper = utf16Offset(utf8Range.upperBound)
        return NSRange(location: lower, length: upper - lower)
    }

    // MARK: - UTF-16 → UTF-8

    /// UTF-16 偏移 → 字节偏移。落在 surrogate 对中间时向下取整到该标量起点。
    public func utf8Offset(_ utf16: Int) -> Int {
        let clamped = min(max(utf16, 0), utf16Length)
        return floorEntry(byUTF16: clamped).utf8
    }

    public func utf8Range(_ nsRange: NSRange) -> Range<Int> {
        let lower = utf8Offset(nsRange.location)
        let upper = utf8Offset(nsRange.location + nsRange.length)
        return lower..<upper
    }

    // MARK: - 内部

    private func floorEntry(byUTF8 offset: Int) -> Entry {
        var lo = 0
        var hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if entries[mid].utf8 <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return entries[lo]
    }

    private func floorEntry(byUTF16 offset: Int) -> Entry {
        var lo = 0
        var hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if entries[mid].utf16 <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return entries[lo]
    }
}
