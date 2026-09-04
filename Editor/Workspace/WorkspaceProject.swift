import Foundation

nonisolated struct WorkspaceProject: Identifiable, Hashable, Sendable {
    let rootURL: URL

    var id: URL { rootURL }
    var name: String { rootURL.lastPathComponent }

    func relativePath(to itemURL: URL) -> String? {
        WorkspacePath.relativePath(from: rootURL, to: itemURL)
    }
}
