import Foundation

nonisolated struct WorkspaceNode: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
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
