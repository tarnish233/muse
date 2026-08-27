import Foundation

struct WorkspaceCreationRequest: Identifiable {
    enum Kind {
        case file
        case folder

        var title: String {
            switch self {
            case .file: "新建文件"
            case .folder: "新建文件夹"
            }
        }

        var prompt: String {
            switch self {
            case .file: "输入 Markdown 文件名"
            case .folder: "输入文件夹名称"
            }
        }

        var initialName: String {
            switch self {
            case .file: "Untitled.md"
            case .folder: "新建文件夹"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let parentURL: URL
}
