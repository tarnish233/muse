import AppKit
import Observation

@MainActor
@Observable
final class ProjectWorkspace {
    struct StoredProject: Codable, Equatable {
        let bookmark: Data
    }

    private enum Constants {
        static let projectKey = "Muse.workspace.project"
        static let readableExtensions = Set(["md", "markdown", "mdown", "mkd", "txt", "text"])
    }

    private struct ProjectStoreRecoveryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var project: WorkspaceProject?
    private(set) var tree: [WorkspaceNode] = []
    var presentedError: String?

    private let fileManager: FileManager
    private let bookmarking: WorkspaceBookmarking
    private let projectStore: WorkspaceProjectStore
    private let treeLoader: WorkspaceTreeLoader
    private let fileOperations: WorkspaceFileOperations
    private var bookmark: Data?
    private var securityScopedURL: URL?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var unresolvedProjectStoreError: Error?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bookmarking: WorkspaceBookmarking? = nil,
        projectStore: WorkspaceProjectStore? = nil,
        fileSystem: WorkspaceFileSystem? = nil,
        fileOperations: WorkspaceFileOperations = WorkspaceFileOperations()
    ) {
        self.fileManager = fileManager
        self.bookmarking = bookmarking ?? .live()
        self.projectStore = projectStore ?? .userDefaults(defaults, key: Constants.projectKey)
        let resolvedFileSystem = fileSystem ?? .live(fileManager: fileManager)
        treeLoader = WorkspaceTreeLoader(fileSystem: resolvedFileSystem)
        self.fileOperations = fileOperations
        restoreProject()
    }

    func openProject(at rootURL: URL) throws {
        let url = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        if project?.rootURL == url {
            beginAccessing(url)
            refreshProject()
            return
        }

        let nextProject = WorkspaceProject(rootURL: url)
        let nextBookmark = try bookmarking.create(url)
        try saveSnapshot(project: nextProject, bookmark: nextBookmark)

        resetCurrentProjectState()
        project = nextProject
        bookmark = nextBookmark
        beginAccessing(url)
        refreshProject()
    }

    func createProject(at rootURL: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try openProject(at: rootURL)
    }

    func closeProject() {
        do {
            try saveSnapshot(project: nil, bookmark: nil)
        } catch {
            presentedError = error.localizedDescription
            return
        }

        resetCurrentProjectState()
        project = nil
        bookmark = nil
    }

    func refreshProject() {
        guard let root = project?.rootURL.standardizedFileURL else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()

        let loader = treeLoader
        refreshTask = Task { [weak self] in
            let outcome = await loader.loadTree(at: root)
            guard let self,
                  self.refreshGeneration == generation,
                  self.project?.rootURL == root
            else { return }

            switch outcome {
            case let .success(nodes, warnings):
                self.tree = nodes
                self.report(warnings)
            case let .failure(message):
                // 短暂的根目录错误不能破坏上一次成功树快照。
                self.presentedError = message
            case .cancelled:
                break
            }
            if self.refreshGeneration == generation {
                self.refreshTask = nil
            }
        }
    }

    /// 测试与需要强一致快照的调用方可等待当前（以及等待期间替换它的）刷新完成。
    func waitForRefresh() async {
        while let refreshTask {
            await refreshTask.value
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
        let name = try validatedName(rawName)
        let destination = node.url.deletingLastPathComponent().appending(
            path: name,
            directoryHint: node.isFolder ? .isDirectory : .notDirectory
        )
        guard destination.standardizedFileURL != node.url.standardizedFileURL else {
            return node.url
        }
        try fileManager.moveItem(at: node.url, to: destination)
        refreshProject(containing: destination)
        return destination
    }

    @discardableResult
    func moveToTrash(_ node: WorkspaceNode) throws -> URL? {
        let belongsToCurrentProject = project(containing: node.url) != nil
        var resultingURL: NSURL?
        try fileManager.trashItem(at: node.url, resultingItemURL: &resultingURL)
        if belongsToCurrentProject {
            refreshProject()
        }
        return resultingURL as URL?
    }

    @discardableResult
    func pasteItems(_ sourceURLs: [URL], into parentURL: URL) async throws -> [URL] {
        guard !sourceURLs.isEmpty else {
            throw WorkspaceOperationError.clipboardContainsNoFiles
        }
        guard let targetProject = project(containing: parentURL) else {
            throw WorkspaceOperationError.invalidPasteDestination
        }

        let targetRootURL = targetProject.rootURL.standardizedFileURL
        defer {
            if project?.rootURL == targetRootURL {
                refreshProject()
            }
        }
        return try await fileOperations.copyItems(sourceURLs, into: parentURL)
    }

    func canOpen(_ url: URL) -> Bool {
        Constants.readableExtensions.contains(url.pathExtension.lowercased())
    }

    func project(containing url: URL) -> WorkspaceProject? {
        guard let project else { return nil }
        let path = url.standardizedFileURL.path
        let rootPath = project.rootURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/") ? project : nil
    }

    func refreshProject(containing url: URL) {
        guard project(containing: url) != nil else { return }
        refreshProject()
    }

    private func validatedName(_ rawName: String, kind: WorkspaceCreationRequest.Kind) throws -> String {
        var name = try validatedName(rawName)
        if kind == .file, URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += ".md"
        }
        return name
    }

    private func validatedName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw WorkspaceOperationError.invalidName
        }
        return name
    }

    private func restoreProject() {
        guard let data = projectStore.load() else { return }
        let stored: StoredProject?
        do {
            stored = try JSONDecoder().decode(StoredProject?.self, from: data)
        } catch {
            do {
                let backupLocation = try projectStore.backupCorruptData(data)
                unresolvedProjectStoreError = nil
                report(["项目数据无法读取。原数据已备份到 \(backupLocation)。"])
            } catch {
                let message = "项目数据无法读取，且备份失败。为避免覆盖原数据，保存已暂停：\(error.localizedDescription)"
                unresolvedProjectStoreError = ProjectStoreRecoveryError(message: message)
                report([message])
            }
            return
        }

        guard let stored else { return }
        let resolution: WorkspaceBookmarkResolution
        do {
            resolution = try bookmarking.resolve(stored.bookmark)
        } catch {
            report([error.localizedDescription])
            return
        }

        let url = resolution.url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        var restoredBookmark = stored.bookmark
        var restorationErrors: [Error] = []
        if resolution.isStale {
            do {
                restoredBookmark = try bookmarking.create(url)
                try saveSnapshot(project: WorkspaceProject(rootURL: url), bookmark: restoredBookmark)
            } catch {
                // The resolved URL remains usable; preserve its last valid bookmark.
                restorationErrors.append(error)
            }
        }

        project = WorkspaceProject(rootURL: url)
        bookmark = restoredBookmark
        beginAccessing(url)
        refreshProject()
        report(restorationErrors.map(\.localizedDescription))
    }

    private func saveSnapshot(project: WorkspaceProject?, bookmark: Data?) throws {
        if let unresolvedProjectStoreError {
            throw unresolvedProjectStoreError
        }
        let stored: StoredProject?
        if project != nil {
            guard let bookmark else {
                throw WorkspaceOperationError.missingProjectBookmark
            }
            stored = StoredProject(bookmark: bookmark)
        } else {
            stored = nil
        }
        try projectStore.save(JSONEncoder().encode(stored))
    }

    private func report(_ messages: [String]) {
        guard let first = messages.first else { return }
        presentedError = first
    }

    private func resetCurrentProjectState() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        tree = []
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
    }

    private func beginAccessing(_ url: URL) {
        guard securityScopedURL != url, url.startAccessingSecurityScopedResource() else { return }
        securityScopedURL = url
    }
}
