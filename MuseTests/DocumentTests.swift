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

    // MARK: - 行终止符（缺陷 P3 / D5）
    //
    // 存储层一律 LF，编辑层因此只需要认一种终止符；文件原本的终止符在写回时还原，
    // 这样 Windows 协作者的 CRLF 文件保存后字节不变，不会变成整文件 diff。

    @Test(arguments: ["\r\n", "\r"])
    func nonLFTerminatorsAreNormalizedInStorageAndRestoredOnWrite(terminator: String) throws {
        let document = MuseDocument()
        let lines = ["# 标题", "", "- 列表项", "正文"]
        let onDisk = lines.joined(separator: terminator) + terminator
        try document.read(from: Data(onDisk.utf8), ofType: markdownType)

        // 存储里只有 LF：编辑层不必懂 CRLF。
        #expect(document.buffer.string == lines.joined(separator: "\n") + "\n")
        #expect(document.buffer.string.contains("\r") == false)

        // 写回时还原成文件原本的终止符，字节级往返一致。
        let written = try document.data(ofType: markdownType)
        #expect(written == Data(onDisk.utf8))
    }

    @Test func lfDocumentsStayLFOnWrite() throws {
        let document = MuseDocument()
        let source = "# 标题\n\n- 列表项\n"
        try document.read(from: Data(source.utf8), ofType: markdownType)

        let written = try document.data(ofType: markdownType)
        #expect(written == Data(source.utf8))
    }

    /// 编辑之后写回，新插入的 LF 也要跟着还原成 CRLF——否则文件会变成混合终止符。
    @Test func editsInheritTheDocumentTerminatorOnWrite() throws {
        let document = MuseDocument()
        try document.read(from: Data("- item\r\n".utf8), ofType: markdownType)
        let storage = document.buffer.textStorage
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "- next\n")

        let written = try document.data(ofType: markdownType)
        #expect(written == Data("- item\r\n- next\r\n".utf8))
        #expect(String(data: written, encoding: .utf8)?.contains("\n\n") == false)
    }

    @Test func documentStorageNormalizesEverySupportedSeparatorToLF() throws {
        let document = MuseDocument()
        let source = "a\r\nb\rc\nd\u{0085}e\u{2028}f\u{2029}g"

        try document.read(from: Data(source.utf8), ofType: markdownType)

        #expect(document.buffer.string == "a\nb\nc\nd\ne\nf\ng")
    }

    /// 混合终止符按**多数**归类，不是按第一处出现——否则一个 99% 是 LF、
    /// 只有一处 CRLF 的文件会被整体改写成 CRLF。
    @Test func mixedTerminatorsFollowTheMajority() throws {
        let mostlyLF = "a\nb\nc\r\nd\ne\n"
        #expect(MuseDocument.dominantLineEnding(in: mostlyLF) == .lf)

        let mostlyCRLF = "a\r\nb\r\nc\nd\r\n"
        #expect(MuseDocument.dominantLineEnding(in: mostlyCRLF) == .crlf)

        // 平票时取最早出现的那一种。
        #expect(MuseDocument.dominantLineEnding(in: "a\r\nb\n") == .crlf)
        #expect(MuseDocument.dominantLineEnding(in: "a\nb\r\n") == .lf)

        // 没有终止符、以及 NEL/LS/PS（都不是 CommonMark 的换行）都落到 LF。
        #expect(MuseDocument.dominantLineEnding(in: "no newline") == .lf)
        #expect(MuseDocument.dominantLineEnding(in: "a\u{2028}b\u{0085}c") == .lf)

        // 归一之后统一成主流终止符，这是刻意的保真度取舍。
        let document = MuseDocument()
        try document.read(from: Data(mostlyLF.utf8), ofType: markdownType)
        #expect(document.buffer.string == "a\nb\nc\nd\ne\n")
        #expect(try document.data(ofType: markdownType) == Data("a\nb\nc\nd\ne\n".utf8))
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

    @Test(arguments: ["utf8-bom", "utf16-le", "utf16-be"])
    func commonPlainTextEncodingsRoundTripWithoutConversion(encoding: String) throws {
        let source = "# 编码\r\n\r\n正文 😀\r\n"
        let data: Data
        switch encoding {
        case "utf8-bom":
            data = Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8)
        case "utf16-le":
            data = Data([0xFF, 0xFE])
                + (try #require(source.data(using: .utf16LittleEndian)))
        default:
            data = Data([0xFE, 0xFF])
                + (try #require(source.data(using: .utf16BigEndian)))
        }

        let document = MuseDocument()
        try document.read(from: data, ofType: "public.plain-text")
        #expect(document.buffer.string == source.replacingOccurrences(of: "\r\n", with: "\n"))
        #expect(try document.data(ofType: "public.plain-text") == data)
    }

    @Test func malformedEncodedTextIsRejected() throws {
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

    /// M6 崩溃恢复的自动化守卫：in-place autosave 是 AppKit 崩溃恢复的载体
    /// （崩溃后由系统从 autosave 版本恢复），其开关必须保持开启。
    @Test func crashRecoveryRidesOnAutosaveInPlace() {
        #expect(MuseDocument.autosavesInPlace)
        #expect(MuseDocument.readableTypes.contains("net.daringfireball.markdown"))
        #expect(MuseDocument.writableTypes.contains("net.daringfireball.markdown"))
        #expect(MuseDocument.readableTypes.contains("public.text") == false)
    }

    @Test func newUntitledDocumentWithSampleIsCleanAfterMakingWindowControllers() {
        let previousFactory = MuseDocument.windowControllerFactory
        MuseDocument.windowControllerFactory = nil
        defer { MuseDocument.windowControllerFactory = previousFactory }

        let document = MuseDocument()
        #expect(document.isDocumentEdited)

        document.makeWindowControllers()

        #expect(document.isDocumentEdited == false)
    }

    @Test func autosavedRecoveryRemainsDirtyAfterMakingWindowControllers() throws {
        let previousFactory = MuseDocument.windowControllerFactory
        MuseDocument.windowControllerFactory = nil
        defer { MuseDocument.windowControllerFactory = previousFactory }

        let document = MuseDocument()
        document.autosavedContentsFileURL = FileManager.default.temporaryDirectory
            .appending(path: "MuseRecovered-\(UUID().uuidString).md")
        try load("# 恢复的草稿\n\n正文", into: document)
        // `init(for:withContentsOf:ofType:)` 会在 read 后做同一笔 change-count 更新；
        // 这里显式模拟它，让测试只聚焦 makeWindowControllers 不得擦掉恢复态。
        document.updateChangeCount(.changeReadOtherContents)
        #expect(document.isDocumentEdited)

        document.makeWindowControllers()

        #expect(document.isDocumentEdited)
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

    @Test func locationTracksSavedURLAndRendererBase() async {
        let document = MuseDocument()
        document.fileType = markdownType
        let file = FileManager.default.temporaryDirectory
            .appending(path: "MuseLocationTests")
            .appending(path: "note.md")

        document.fileURL = file
        await Task.yield()

        #expect(document.location.fileURL == file.standardizedFileURL)
        #expect(document.location.directoryURL == file.deletingLastPathComponent().standardizedFileURL)
        #expect(document.renderer.imageBaseURL == document.location.directoryURL)
        #expect(document.location.displayName == "note.md")
    }

    @Test func rapidFileURLChangesApplyOnlyLatestLocation() async {
        let document = MuseDocument()
        document.fileType = markdownType
        let root = FileManager.default.temporaryDirectory.appending(path: "MuseRapidLocationTests")
        let first = root.appending(path: "first.md")
        let second = root.appending(path: "second.md")
        let third = root.appending(path: "third.md")

        document.fileURL = first
        document.fileURL = second
        document.fileURL = third
        await Task.yield()
        await Task.yield()

        #expect(document.location.fileURL == third.standardizedFileURL)
        #expect(document.renderer.imageBaseURL == third.deletingLastPathComponent().standardizedFileURL)
        #expect(document.location.displayName == "third.md")
    }

    @Test func locationUsesStandardizedFileURL() async {
        let document = MuseDocument()
        document.fileType = markdownType
        let root = FileManager.default.temporaryDirectory
        let unstandardized = root
            .appending(path: "folder")
            .appending(path: "..")
            .appending(path: "standard.md")

        document.fileURL = unstandardized
        await Task.yield()

        #expect(document.location.fileURL == unstandardized.standardizedFileURL)
    }
}
