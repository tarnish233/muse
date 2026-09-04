import Foundation

enum WorkspaceOperationError: LocalizedError {
    case invalidName
    case unsupportedDocument
    case missingProjectBookmark
    case clipboardWriteFailed
    case clipboardContainsNoFiles
    case itemOutsideProject
    case invalidPasteDestination
    case cannotCopyFolderIntoItself
    case trashLocationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "名称不能为空，也不能包含“/”。"
        case .unsupportedDocument:
            "Muse 目前只能打开 Markdown 或纯文本文件。"
        case .missingProjectBookmark:
            "项目书签缺失，已保留上一次成功保存的项目。"
        case .clipboardWriteFailed:
            "无法写入剪贴板。"
        case .clipboardContainsNoFiles:
            "剪贴板中没有可粘贴的文件或文件夹。"
        case .itemOutsideProject:
            "无法计算该项目项的相对路径。"
        case .invalidPasteDestination:
            "粘贴目标不是当前项目中的文件夹。"
        case .cannotCopyFolderIntoItself:
            "无法将文件夹复制到自身或它的子文件夹中。"
        case .trashLocationUnavailable:
            "项目项已移到废纸篓，但系统没有返回可用于撤销的位置。"
        }
    }
}
