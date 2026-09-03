import Foundation

nonisolated struct WorkspaceProject: Identifiable, Hashable, Sendable {
    let rootURL: URL

    var id: URL { rootURL }
    var name: String { rootURL.lastPathComponent }

    func relativePath(to itemURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let itemComponents = itemURL.standardizedFileURL.pathComponents
        guard itemComponents.count >= rootComponents.count,
              zip(rootComponents, itemComponents).allSatisfy(==)
        else { return nil }

        let relativeComponents = itemComponents.dropFirst(rootComponents.count)
        return relativeComponents.isEmpty ? "." : relativeComponents.joined(separator: "/")
    }
}
