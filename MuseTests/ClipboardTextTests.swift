import AppKit
import Testing

@Suite @MainActor struct ClipboardTextTests {
    @Test func emptySelectionCanExpandToWholeLine() throws {
        let source: NSString = "第一行\n第二行\n第三行"
        let caret = source.range(of: "二").location

        let range = try #require(ClipboardText.effectiveCopyRange(
            in: source,
            selection: NSRange(location: caret, length: 0),
            copiesWholeLineWhenEmpty: true
        ))

        #expect(source.substring(with: range) == "第二行\n")
    }

    @Test func emptySelectionStaysEmptyWhenWholeLineCopyIsDisabled() throws {
        let source: NSString = "一行"
        let selection = NSRange(location: 1, length: 0)
        let range = try #require(ClipboardText.effectiveCopyRange(
            in: source,
            selection: selection,
            copiesWholeLineWhenEmpty: false
        ))

        #expect(range == selection)
    }

    @Test func renderedPlainTextDropsMarkdownSyntaxAndPreservesListMeaning() {
        let source = "# 标题\n\n- **粗体**\n1. [链接](https://example.com)\n- [x] 完成"
        let range = NSRange(location: 0, length: (source as NSString).length)

        let result = ClipboardText.renderedPlainText(from: source, range: range)

        #expect(result == "标题\n\n• 粗体\n1. 链接\n☑ 完成")
    }

    @Test func partialSelectionUsesDocumentLevelMarkdownSemantics() {
        let source = "前缀 **粗体** 后缀"
        let range = (source as NSString).range(of: "**粗体**")

        #expect(ClipboardText.renderedPlainText(from: source, range: range) == "粗体")
    }

    @Test func normalizedMarkdownRemovesOnlyRedundantHeadingStrongMarkers() {
        let source = "# **Muse · M0 技术验证**\n\n正文 **仍然粗体**\n## *仍然斜体*"
        let range = NSRange(location: 0, length: (source as NSString).length)

        let result = ClipboardText.normalizedMarkdown(from: source, range: range)

        #expect(result == "# Muse · M0 技术验证\n\n正文 **仍然粗体**\n## *仍然斜体*")
    }

    @Test func normalizedMarkdownDoesNotRewritePartialStrongDelimiterSelection() {
        let source = "# **标题**"
        let range = (source as NSString).range(of: "*标题*")

        #expect(ClipboardText.normalizedMarkdown(from: source, range: range) == "*标题*")
    }

    @Test func normalizedMarkdownCopyPublishesOnlyNormalizedPlainText() {
        let source = "# **Muse · M0 技术验证**"
        let storage = NSTextStorage(string: source)
        let textView = EditorTextView.make(textStorage: storage)
        let pasteboard = NSPasteboard(name: .init("MuseTests.NormalizedMarkdown.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data("stale rich text".utf8), forType: .rtf)
        textView.clipboardPasteboard = pasteboard
        textView.clipboardCopyMode = .normalizedMarkdown
        textView.setSelectedRange(NSRange(location: 0, length: storage.length))

        textView.copy(nil)

        #expect(pasteboard.string(forType: .string) == "# Muse · M0 技术验证")
        #expect(pasteboard.data(forType: .rtf) == nil)
        #expect(pasteboard.data(forType: .html) == nil)
    }
}
