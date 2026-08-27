import AppKit
import Observation

@MainActor
@Observable
final class ProjectWorkspace {
    static let shared = ProjectWorkspace()

    private struct StoredProject: Codable {
        let bookmark: Data
    }

    private enum Constants {
        static let projectsKey = "Muse.workspace.projects"
        static let readableExtensions = Set(["md", "markdown", "mdown", "mkd", "txt", "text"])
    }

    private(set) var projects: [WorkspaceProject] = []
    private(set) var trees: [URL: [WorkspaceNode]] = [:]
    var presentedError: String?

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var securityScopedURLs: Set<URL> = []

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        restoreProjects()
    }

    func addProject(at rootURL: URL) throws {
        let url = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        if !projects.contains(where: { $0.rootURL == url }) {
            projects.append(WorkspaceProject(rootURL: url))
            projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        beginAccessing(url)
        refreshProject(at: url)
        persistProjects()
    }

    func createProject(at rootURL: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try addProject(at: rootURL)
    }

    func removeProject(_ project: WorkspaceProject) {
        projects.removeAll { $0.id == project.id }
        trees[project.rootURL] = nil
        if securityScopedURLs.remove(project.rootURL) != nil {
            project.rootURL.stopAccessingSecurityScopedResource()
        }
        persistProjects()
    }

    func children(of project: WorkspaceProject) -> [WorkspaceNode] {
        trees[project.rootURL] ?? []
    }

    func refreshAll() {
        for project in projects {
            refreshProject(at: project.rootURL)
        }
    }

    func refreshProject(at rootURL: URL) {
        do {
            trees[rootURL] = try loadChildren(of: rootURL)
        } catch {
            trees[rootURL] = []
            presentedError = error.localizedDescription
        }
    }

    @discardableResult
    func createItem(_ kind: WorkspaceCreationRequest.Kind, named rawName: String, in parentURL: URL) throws -> URL {
        let name = try validatedName(rawName, kind: kind)
        let destination = parentURL.appending(path: name, directoryHint: kind == .folder ? .isDirectory : .notDirectory)

        switch kind {
        case .folder:
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        case .file:
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try Data().write(to: destination, options: .atomic)
        }

        refreshProjectContaining(destination)
        return destination
    }

    @discardableResult
    func rename(_ node: WorkspaceNode, to rawName: String) throws -> URL {
        let name = try validatedName(rawName, kind: node.isFolder ? .folder : .file)
        let destination = node.url.deletingLastPathComponent().appending(path: name)
        try fileManager.moveItem(at: node.url, to: destination)
        refreshProjectContaining(destination)
        return destination
    }

    func moveToTrash(_ node: WorkspaceNode) throws {
        _ = try fileManager.trashItem(at: node.url, resultingItemURL: nil)
        refreshProjectContaining(node.url)
    }

    func canOpen(_ url: URL) -> Bool {
        Constants.readableExtensions.contains(url.pathExtension.lowercased())
    }

    func project(containing url: URL) -> WorkspaceProject? {
        let path = url.standardizedFileURL.path
        return projects
            .filter { path == $0.rootURL.path || path.hasPrefix($0.rootURL.path + "/") }
            .max { $0.rootURL.path.count < $1.rootURL.path.count }
    }

    private func refreshProjectContaining(_ url: URL) {
        guard let project = project(containing: url) else { return }
        refreshProject(at: project.rootURL)
    }

    private func loadChildren(of directoryURL: URL) throws -> [WorkspaceNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true, values.isPackage != true {
                return WorkspaceNode(url: url, kind: .folder, children: try loadChildren(of: url))
            }
            if values.isRegularFile == true {
                return WorkspaceNode(url: url, kind: .file, children: nil)
            }
            return nil
        }
        .sorted(by: Self.nodeSort)
    }

    private static func nodeSort(_ lhs: WorkspaceNode, _ rhs: WorkspaceNode) -> Bool {
        if lhs.kind != rhs.kind { return lhs.isFolder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func validatedName(_ rawName: String, kind: WorkspaceCreationRequest.Kind) throws -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw WorkspaceOperationError.invalidName
        }
        if kind == .file, URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += ".md"
        }
        return name
    }

    private func restoreProjects() {
        guard let data = defaults.data(forKey: Constants.projectsKey),
              let stored = try? JSONDecoder().decode([StoredProject].self, from: data)
        else { return }

        for item in stored {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: item.bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            try? addRestoredProject(at: url, shouldPersist: isStale)
        }
    }

    private func addRestoredProject(at url: URL, shouldPersist: Bool) throws {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        projects.append(WorkspaceProject(rootURL: standardizedURL))
        beginAccessing(standardizedURL)
        refreshProject(at: standardizedURL)
        if shouldPersist { persistProjects() }
    }

    private func persistProjects() {
        let stored = projects.compactMap { project -> StoredProject? in
            guard let bookmark = try? project.rootURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            return StoredProject(bookmark: bookmark)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Constants.projectsKey)
    }

    private func beginAccessing(_ url: URL) {
        guard !securityScopedURLs.contains(url), url.startAccessingSecurityScopedResource() else { return }
        securityScopedURLs.insert(url)
    }
}
