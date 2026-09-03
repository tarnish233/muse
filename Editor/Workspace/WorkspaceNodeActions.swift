import Foundation

struct WorkspaceNodeActions {
    let createFile: (URL) -> Void
    let createFolder: (URL) -> Void
    let openFile: (URL) -> Void
    let revealInFinder: (URL) -> Void
    let copyItem: (WorkspaceNode) -> Void
    let copyPath: (WorkspaceNode) -> Void
    let copyRelativePath: (WorkspaceNode) -> Void
    let rename: (WorkspaceNode) -> Void
    let delete: (WorkspaceNode) -> Void
    let focus: (WorkspaceNode) -> Void
}
