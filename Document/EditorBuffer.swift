import AppKit

/// 编辑期唯一可变正文（v0.2：数据所有权边界）。
/// `MuseDocument` 只负责持有本对象、序列化与文档生命周期；
/// 不允许文档层再维护第二份可变 String。
public final class EditorBuffer {
    public let textStorage: NSTextStorage

    public init() {
        textStorage = NSTextStorage()
    }

    public var string: String { textStorage.string }
}
