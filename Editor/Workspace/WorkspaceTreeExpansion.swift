import Foundation

nonisolated struct WorkspaceTreeExpansion: Equatable, Sendable {
    private(set) var isProjectExpanded = true
    private var expandedFolderURLs: Set<URL> = []

    var hasExpandedFolders: Bool { expandedFolderURLs.isEmpty == false }

    func containsFolder(_ url: URL) -> Bool {
        expandedFolderURLs.contains(url.standardizedFileURL)
    }

    mutating func toggleProject() {
        isProjectExpanded.toggle()
    }

    mutating func toggleFolder(_ url: URL) {
        let normalized = url.standardizedFileURL
        if expandedFolderURLs.remove(normalized) == nil {
            expandedFolderURLs.insert(normalized)
        }
    }

    mutating func collapseAllFolders() {
        expandedFolderURLs.removeAll()
    }
}
