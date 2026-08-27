import Foundation

struct WorkspaceProject: Identifiable, Hashable {
    let rootURL: URL

    var id: URL { rootURL }
    var name: String { rootURL.lastPathComponent }
}
