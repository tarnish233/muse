import Foundation

enum WorkspaceOperationError: LocalizedError {
    case invalidName
    case unsupportedDocument
    case missingProjectBookmark

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "名称不能为空，也不能包含“/”。"
        case .unsupportedDocument:
            "Muse 目前只能打开 Markdown 或纯文本文件。"
        case .missingProjectBookmark:
            "项目书签缺失，已保留上一次成功保存的项目。"
        }
    }
}
