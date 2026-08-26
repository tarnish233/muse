import Foundation
import Testing

/// M1：NSDocument 序列化与数据所有权。
@Suite struct DocumentTests {
    @Test func roundTripPreservesSource() throws {
        let document = MuseDocument()
        let source = "# 标题\n\n**粗体** 与 `code`\n- 列表\n"
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")

        #expect(document.buffer.string == source)

        let out = try document.data(ofType: "net.daringfireball.markdown")
        #expect(String(data: out, encoding: .utf8) == source)
    }

    @Test func readReplacesWholeContent() throws {
        let document = MuseDocument()
        // 初始被示例文档填充，read 应整体覆盖。
        try document.read(from: Data("只有一行".utf8), ofType: "net.daringfireball.markdown")
        #expect(document.buffer.string == "只有一行")
    }

    @Test func nonUTF8IsRejected() throws {
        let document = MuseDocument()
        #expect(throws: CocoaError.self) {
            try document.read(from: Data([0xFF, 0xFE, 0x00]), ofType: "net.daringfireball.markdown")
        }
    }

    @Test func renderNeverChangesDocumentSource() throws {
        let document = MuseDocument()
        let source = SampleMarkdown.text
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")

        // 触发一次渲染（storage 编辑回调），然后断言源码不变。
        let full = NSRange(location: 0, length: document.buffer.string.utf16.count)
        document.buffer.textStorage.replaceCharacters(in: full, with: source + "\n")
        #expect(document.buffer.string == source + "\n")
    }
}
