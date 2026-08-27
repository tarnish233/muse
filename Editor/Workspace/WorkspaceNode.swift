import Foundation

struct WorkspaceNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case file
    }

    let url: URL
    let kind: Kind
    let children: [WorkspaceNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isFolder: Bool { kind == .folder }
}
