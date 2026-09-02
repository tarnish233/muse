import Foundation

enum ClipboardCopyMode: String, CaseIterable, Identifiable {
    case plainText
    case markdownSource
    case normalizedMarkdown

    var id: Self { self }

    var title: String {
        switch self {
        case .plainText: "纯文本"
        case .markdownSource: "Markdown 源码"
        case .normalizedMarkdown: "规范化 Markdown"
        }
    }

    var detail: String {
        switch self {
        case .plainText:
            "移除 Markdown 语法，同时保留列表序号等可读含义。"
        case .markdownSource:
            "复制选区内的原始 Markdown 字符，不做改写。"
        case .normalizedMarkdown:
            "保留 Markdown 结构，并移除标题中重复的粗体标记。"
        }
    }
}
