import Foundation
import Testing
@testable import MuseKit

/// M1：NSDocument 序列化与数据所有权。
@Suite @MainActor struct DocumentTests {
    private let markdownType = "net.daringfireball.markdown"

    private func temporaryDocumentURL() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return (directory, directory.appendingPathComponent("note.md"))
    }

    private func load(_ source: String, into document: MuseDocument) throws {
        try document.read(from: Data(source.utf8), ofType: markdownType)
    }

    private func autosave(_ document: MuseDocument, to url: URL) async throws {
        document.fileURL = url
        document.fileType = markdownType
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.autosave(withImplicitCancellability: false) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

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
        #expect(!document.isDocumentEdited)
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
        try load(source, into: document)

        // 触发一次渲染（storage 编辑回调），然后断言源码不变。
        let full = NSRange(location: 0, length: document.buffer.string.utf16.count)
        document.buffer.textStorage.replaceCharacters(in: full, with: source + "\n")
        #expect(document.buffer.string == source + "\n")
    }

    @Test func autosaveWritesToDisk() async throws {
        let paths = try temporaryDocumentURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }

        let document = MuseDocument()
        let source = "# 草稿\n\n初稿"
        let edited = source + "\n\n已编辑"
        try load(source, into: document)
        let full = NSRange(location: 0, length: document.buffer.textStorage.length)
        document.buffer.textStorage.replaceCharacters(in: full, with: edited)

        try await autosave(document, to: paths.file)

        let onDisk = try String(contentsOf: paths.file, encoding: .utf8)
        #expect(onDisk == edited)
    }

    @Test func reopenRestoresContent() async throws {
        let paths = try temporaryDocumentURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }

        let document = MuseDocument()
        let edited = "保存后重新打开\n\n- 一致"
        try load("临时内容", into: document)
        document.buffer.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: document.buffer.textStorage.length),
            with: edited
        )
        try await autosave(document, to: paths.file)

        let reopened = try MuseDocument(contentsOf: paths.file, ofType: markdownType)
        #expect(reopened.buffer.string == edited)
    }

    @Test func renderingDoesNotMarkDocumentDirty() throws {
        let document = MuseDocument()
        let source = "**只写属性**\n\n- 列表"
        try load(source, into: document)
        let engine = RenderEngine()
        let package = engine.prepare(source)

        _ = engine.render(
            package: package,
            selection: NSRange(location: 0, length: 0),
            into: document.buffer.textStorage
        )

        #expect(document.buffer.string == source)
        #expect(document.isDocumentEdited == false)
    }

    @Test func sourceModeToggleDoesNotChangeOrDirtyDocument() throws {
        let document = MuseDocument()
        let source = "# 标题\n\n- 列表\n\n**粗体**"
        try load(source, into: document)
        let package = RenderEngine().prepare(source)
        document.renderer.adoptPackage(package)

        document.renderer.setPresentationMode(.source)
        #expect(document.buffer.string == source)
        #expect(!document.isDocumentEdited)

        document.renderer.setPresentationMode(.rendered)
        #expect(document.buffer.string == source)
        #expect(!document.isDocumentEdited)
    }

    @Test func textEditMarksDocumentDirty() throws {
        let document = MuseDocument()
        try load("正文", into: document)

        document.buffer.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "新")

        #expect(document.isDocumentEdited)
    }
}
