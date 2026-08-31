import AppKit
import Observation

@MainActor
@Observable
final class ProjectWorkspace {
    static let shared = ProjectWorkspace()

    struct StoredProject: Codable, Equatable {
        let bookmark: Data
    }

    private enum Constants {
        static let projectsKey = "Muse.workspace.projects"
        static let readableExtensions = Set(["md", "markdown", "mdown", "mkd", "txt", "text"])
    }

    private(set) var projects: [WorkspaceProject] = []
    private(set) var trees: [URL: [WorkspaceNode]] = [:]
    var presentedError: String?

    private let fileManager: FileManager
    private let bookmarking: WorkspaceBookmarking
    private let projectStore: WorkspaceProjectStore
    private let treeLoader: WorkspaceTreeLoader
    private var bookmarksByURL: [URL: Data] = [:]
    private var securityScopedURLs: Set<URL> = []
    private var refreshTasks: [URL: Task<Void, Never>] = [:]
    private var refreshGenerations: [URL: Int] = [:]
    private var unresolvedProjectStoreError: Error?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bookmarking: WorkspaceBookmarking? = nil,
        projectStore: WorkspaceProjectStore? = nil,
        fileSystem: WorkspaceFileSystem? = nil
    ) {
        self.fileManager = fileManager
        self.bookmarking = bookmarking ?? .live()
        self.projectStore = projectStore ?? .userDefaults(defaults, key: Constants.projectsKey)
        let resolvedFileSystem = fileSystem ?? .live(fileManager: fileManager)
        self.treeLoader = WorkspaceTreeLoader(fileSystem: resolvedFileSystem)
        restoreProjects()
    }

    func addProject(at rootURL: URL) throws {
        let url = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard !projects.contains(where: { $0.rootURL == url }) else {
            beginAccessing(url)
            refreshProject(at: url)
            return
        }

        let bookmark = try bookmarking.create(url)
        var nextProjects = projects
        nextProjects.append(WorkspaceProject(rootURL: url))
        nextProjects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var nextBookmarks = bookmarksByURL
        nextBookmarks[url] = bookmark
        try saveSnapshot(projects: nextProjects, bookmarks: nextBookmarks)

        projects = nextProjects
        bookmarksByURL = nextBookmarks
        beginAccessing(url)
        refreshProject(at: url)
    }

    func createProject(at rootURL: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try addProject(at: rootURL)
    }

    func removeProject(_ project: WorkspaceProject) {
        let url = project.rootURL.standardizedFileURL
        let nextProjects = projects.filter { $0.id != project.id }
        var nextBookmarks = bookmarksByURL
        nextBookmarks[url] = nil

        do {
            try saveSnapshot(projects: nextProjects, bookmarks: nextBookmarks)
        } catch {
            presentedError = error.localizedDescription
            return
        }

        projects = nextProjects
        bookmarksByURL = nextBookmarks
        trees[url] = nil
        refreshTasks[url]?.cancel()
        refreshTasks[url] = nil
        refreshGenerations[url] = nil
        if securityScopedURLs.remove(url) != nil {
            url.stopAccessingSecurityScopedResource()
        }
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
        let root = rootURL.standardizedFileURL
        let generation = (refreshGenerations[root] ?? 0) + 1
        refreshGenerations[root] = generation
        refreshTasks[root]?.cancel()

        let loader = treeLoader
        refreshTasks[root] = Task { [weak self] in
            let outcome = await loader.loadTree(at: root)
            guard let self,
                  self.refreshGenerations[root] == generation,
                  self.projects.contains(where: { $0.rootURL == root })
            else { return }

            switch outcome {
            case let .success(nodes, warnings):
                self.trees[root] = nodes
                self.report(warnings)
            case let .failure(message):
                // 短暂的根目录错误不能破坏上一次成功树快照。
                self.presentedError = message
            case .cancelled:
                break
            }
            if self.refreshGenerations[root] == generation {
                self.refreshTasks[root] = nil
            }
        }
    }

    /// 测试与需要强一致快照的调用方可等待当前（以及等待期间替换它的）刷新完成。
    func waitForRefresh(at rootURL: URL) async {
        let root = rootURL.standardizedFileURL
        while let task = refreshTasks[root] {
            await task.value
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

        refreshProject(containing: destination)
        return destination
    }

    @discardableResult
    func rename(_ node: WorkspaceNode, to rawName: String) throws -> URL {
        let name = try validatedName(rawName, kind: node.isFolder ? .folder : .file)
        let destination = node.url.deletingLastPathComponent().appending(path: name)
        try fileManager.moveItem(at: node.url, to: destination)
        refreshProject(containing: destination)
        return destination
    }

    func moveToTrash(_ node: WorkspaceNode) throws {
        _ = try fileManager.trashItem(at: node.url, resultingItemURL: nil)
        refreshProject(containing: node.url)
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

    func refreshProject(containing url: URL) {
        guard let project = project(containing: url) else { return }
        refreshProject(at: project.rootURL)
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
        guard let data = projectStore.load() else { return }
        let stored: [StoredProject]
        do {
            stored = try JSONDecoder().decode([StoredProject].self, from: data)
        } catch {
            unresolvedProjectStoreError = error
            report([error.localizedDescription])
            return
        }

        var restoredProjects: [WorkspaceProject] = []
        var restoredBookmarks: [URL: Data] = [:]
        var restorationErrors: [Error] = []
        var needsRewrite = false

        for item in stored {
            let resolution: WorkspaceBookmarkResolution
            do {
                resolution = try bookmarking.resolve(item.bookmark)
            } catch {
                restorationErrors.append(error)
                continue
            }

            let url = resolution.url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  restoredBookmarks[url] == nil
            else { continue }

            var bookmark = item.bookmark
            if resolution.isStale {
                do {
                    bookmark = try bookmarking.create(url)
                    needsRewrite = true
                } catch {
                    // The resolved URL remains usable; preserve its last valid bookmark.
                    restorationErrors.append(error)
                }
            }

            restoredProjects.append(WorkspaceProject(rootURL: url))
            restoredBookmarks[url] = bookmark
        }

        restoredProjects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        projects = restoredProjects
        bookmarksByURL = restoredBookmarks

        for project in projects {
            beginAccessing(project.rootURL)
            refreshProject(at: project.rootURL)
        }

        if needsRewrite {
            do {
                try persistProjects()
            } catch {
                restorationErrors.append(error)
            }
        }
        report(restorationErrors.map(\.localizedDescription))
    }

    private func persistProjects() throws {
        try saveSnapshot(projects: projects, bookmarks: bookmarksByURL)
    }

    private func saveSnapshot(projects: [WorkspaceProject], bookmarks: [URL: Data]) throws {
        if let unresolvedProjectStoreError {
            throw unresolvedProjectStoreError
        }
        let stored = try projects.map { project -> StoredProject in
            guard let bookmark = bookmarks[project.rootURL.standardizedFileURL] else {
                throw WorkspaceOperationError.incompleteProjectBookmarks
            }
            return StoredProject(bookmark: bookmark)
        }
        let data = try JSONEncoder().encode(stored)
        try projectStore.save(data)
    }

    private func report(_ messages: [String]) {
        guard let first = messages.first else { return }
        if messages.count == 1 {
            presentedError = first
        } else {
            presentedError = "\(first)\n另有 \(messages.count - 1) 个项目条目无法读取。"
        }
    }

    private func beginAccessing(_ url: URL) {
        guard !securityScopedURLs.contains(url), url.startAccessingSecurityScopedResource() else { return }
        securityScopedURLs.insert(url)
    }
}
