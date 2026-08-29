import Foundation
import Testing

@Suite @MainActor struct WorkspaceTests {
    private func makeWorkspace() throws -> (ProjectWorkspace, URL, UserDefaults, String) {
        let suiteName = "MuseWorkspaceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MuseWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (ProjectWorkspace(defaults: defaults), root, defaults, suiteName)
    }

    @Test func createsProjectFolderAndMarkdownFile() throws {
        let (workspace, root, defaults, suiteName) = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        try workspace.createProject(at: root)
        let notes = try workspace.createItem(.folder, named: "Notes", in: root)
        let document = try workspace.createItem(.file, named: "First", in: notes)

        #expect(workspace.projects.map(\.rootURL) == [root])
        #expect(document.lastPathComponent == "First.md")
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(workspace.children(of: workspace.projects[0]).first?.name == "Notes")
    }

    @Test func foldersSortBeforeFilesAndNamesUseFinderOrdering() throws {
        let (workspace, root, _, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try workspace.createProject(at: root)
        _ = try workspace.createItem(.file, named: "10.md", in: root)
        _ = try workspace.createItem(.file, named: "2.md", in: root)
        _ = try workspace.createItem(.folder, named: "Archive", in: root)

        let names = workspace.children(of: workspace.projects[0]).map(\.name)
        #expect(names == ["Archive", "2.md", "10.md"])
    }

    @Test func removingProjectDoesNotDeleteItsDirectory() throws {
        let (workspace, root, _, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try workspace.createProject(at: root)
        let project = try #require(workspace.projects.first)
        workspace.removeProject(project)

        #expect(workspace.projects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func rejectsInvalidNamesAndUnsupportedFiles() throws {
        let (workspace, root, _, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try workspace.createProject(at: root)

        #expect(throws: WorkspaceOperationError.self) {
            try workspace.createItem(.file, named: "bad/name", in: root)
        }
        #expect(workspace.canOpen(root.appending(path: "note.md")))
        #expect(!workspace.canOpen(root.appending(path: "image.png")))
    }

    @Test func staleBookmarksRestoreCompleteSnapshotWithOneWrite() throws {
        let firstRoot = try makeDirectory(named: "First")
        let secondRoot = try makeDirectory(named: "Second")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let oldFirst = Data([1])
        let oldSecond = Data([2])
        let refreshedFirst = Data([9])
        let store = StoreRecorder(data: try encodedBookmarks([oldFirst, oldSecond]))
        let bookmarking = WorkspaceBookmarking(
            create: { url in
                #expect(url.standardizedFileURL == firstRoot.standardizedFileURL)
                return refreshedFirst
            },
            resolve: { data in
                if data == oldFirst {
                    return WorkspaceBookmarkResolution(url: firstRoot, isStale: true)
                }
                return WorkspaceBookmarkResolution(url: secondRoot, isStale: false)
            }
        )

        let workspace = ProjectWorkspace(
            bookmarking: bookmarking,
            projectStore: store.store
        )

        let restoredURLs = workspace.projects.map(\.rootURL).sorted { $0.path < $1.path }
        let expectedURLs = [firstRoot.standardizedFileURL, secondRoot.standardizedFileURL]
            .sorted { $0.path < $1.path }
        #expect(restoredURLs == expectedURLs)
        #expect(store.saved.count == 1)
        #expect(try decodedBookmarks(store.saved[0]) == [refreshedFirst, oldSecond])
    }

    @Test func failedStaleRegenerationRetainsPreviousBookmark() throws {
        let firstRoot = try makeDirectory(named: "FirstFailure")
        let secondRoot = try makeDirectory(named: "SecondRefresh")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let oldFirst = Data([3])
        let oldSecond = Data([4])
        let refreshedSecond = Data([8])
        let store = StoreRecorder(data: try encodedBookmarks([oldFirst, oldSecond]))
        let bookmarking = WorkspaceBookmarking(
            create: { url in
                if url.standardizedFileURL == firstRoot.standardizedFileURL {
                    throw TestFailure.expected
                }
                return refreshedSecond
            },
            resolve: { data in
                WorkspaceBookmarkResolution(
                    url: data == oldFirst ? firstRoot : secondRoot,
                    isStale: true
                )
            }
        )

        let workspace = ProjectWorkspace(
            bookmarking: bookmarking,
            projectStore: store.store
        )

        #expect(workspace.projects.count == 2)
        #expect(store.saved.count == 1)
        #expect(try decodedBookmarks(store.saved[0]) == [oldFirst, refreshedSecond])
    }

    @Test func addingProjectCommitsOnlyAfterBookmarkCreationSucceeds() throws {
        let root = try makeDirectory(named: "BookmarkFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StoreRecorder()
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in throw TestFailure.expected },
                resolve: { _ in throw TestFailure.expected }
            ),
            projectStore: store.store
        )

        #expect(throws: TestFailure.self) {
            try workspace.addProject(at: root)
        }
        #expect(workspace.projects.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test func removingProjectDeletesOnlyMatchingBookmark() throws {
        let firstRoot = try makeDirectory(named: "RemoveFirst")
        let secondRoot = try makeDirectory(named: "KeepSecond")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let firstBookmark = Data([5])
        let secondBookmark = Data([6])
        let store = StoreRecorder(data: try encodedBookmarks([firstBookmark, secondBookmark]))
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in throw TestFailure.expected },
                resolve: { data in
                    WorkspaceBookmarkResolution(
                        url: data == firstBookmark ? firstRoot : secondRoot,
                        isStale: false
                    )
                }
            ),
            projectStore: store.store
        )

        let firstProject = try #require(workspace.projects.first { $0.rootURL == firstRoot.standardizedFileURL })
        workspace.removeProject(firstProject)

        #expect(workspace.projects.map(\.rootURL) == [secondRoot.standardizedFileURL])
        #expect(store.saved.count == 1)
        #expect(try decodedBookmarks(store.saved[0]) == [secondBookmark])
    }

    @Test func rootEnumerationFailurePreservesPreviousSnapshot() throws {
        let root = try makeDirectory(named: "RootFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "visible.md")
        try Data().write(to: file)
        let state = FileSystemState(root: root, entries: [file])
        let workspace = try makeInjectedWorkspace(root: root, fileSystem: state.fileSystem)
        let project = try #require(workspace.projects.first)
        #expect(workspace.children(of: project).map(\.name) == ["visible.md"])

        state.failRoot = true
        workspace.refreshProject(at: root)

        #expect(workspace.children(of: project).map(\.name) == ["visible.md"])
        #expect(workspace.presentedError != nil)
    }

    @Test func childMetadataFailureSkipsOnlyThatChild() throws {
        let root = try makeDirectory(named: "MetadataFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appending(path: "bad.md")
        let good = root.appending(path: "good.md")
        let state = FileSystemState(root: root, entries: [bad, good])
        state.metadataFailures.insert(bad)

        let workspace = try makeInjectedWorkspace(root: root, fileSystem: state.fileSystem)
        let project = try #require(workspace.projects.first)

        #expect(workspace.children(of: project).map(\.name) == ["good.md"])
        #expect(workspace.presentedError != nil)
    }

    @Test func unreadableChildDirectoryRemainsVisibleWithSiblings() throws {
        let root = try makeDirectory(named: "NestedFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        let file = root.appending(path: "visible.md")
        let state = FileSystemState(root: root, entries: [folder, file])
        state.directories.insert(folder)
        state.directoryFailures.insert(folder)

        let workspace = try makeInjectedWorkspace(root: root, fileSystem: state.fileSystem)
        let project = try #require(workspace.projects.first)
        let nodes = workspace.children(of: project)

        #expect(nodes.map(\.name) == ["Folder", "visible.md"])
        #expect(nodes.first?.isFolder == true)
        #expect(nodes.first?.children == nil)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MuseWorkspaceTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeInjectedWorkspace(
        root: URL,
        fileSystem: WorkspaceFileSystem
    ) throws -> ProjectWorkspace {
        let store = StoreRecorder()
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in Data([7]) },
                resolve: { _ in WorkspaceBookmarkResolution(url: root, isStale: false) }
            ),
            projectStore: store.store,
            fileSystem: fileSystem
        )
        try workspace.addProject(at: root)
        return workspace
    }

    private func encodedBookmarks(_ bookmarks: [Data]) throws -> Data {
        try JSONEncoder().encode(bookmarks.map(ProjectWorkspace.StoredProject.init(bookmark:)))
    }

    private func decodedBookmarks(_ data: Data) throws -> [Data] {
        try JSONDecoder().decode([ProjectWorkspace.StoredProject].self, from: data).map(\.bookmark)
    }

    private enum TestFailure: Error {
        case expected
    }

    private final class StoreRecorder {
        var data: Data?
        var saved: [Data] = []

        init(data: Data? = nil) {
            self.data = data
        }

        var store: WorkspaceProjectStore {
            WorkspaceProjectStore(
                load: { [weak self] in self?.data },
                save: { [weak self] data in
                    self?.data = data
                    self?.saved.append(data)
                }
            )
        }
    }

    private final class FileSystemState {
        let root: URL
        let entries: [URL]
        var failRoot = false
        var metadataFailures: Set<URL> = []
        var directoryFailures: Set<URL> = []
        var directories: Set<URL> = []

        init(root: URL, entries: [URL]) {
            self.root = root.standardizedFileURL
            self.entries = entries
        }

        var fileSystem: WorkspaceFileSystem {
            WorkspaceFileSystem(
                contentsOfDirectory: { [weak self] url in
                    guard let self else { return [] }
                    let normalized = url.standardizedFileURL
                    if (normalized == self.root && self.failRoot)
                        || self.directoryFailures.contains(normalized) {
                        throw TestFailure.expected
                    }
                    return normalized == self.root ? self.entries : []
                },
                metadata: { [weak self] url in
                    guard let self else { throw TestFailure.expected }
                    let normalized = url.standardizedFileURL
                    if self.metadataFailures.contains(normalized) {
                        throw TestFailure.expected
                    }
                    let isDirectory = self.directories.contains(normalized)
                    return WorkspaceEntryMetadata(
                        isDirectory: isDirectory,
                        isRegularFile: !isDirectory,
                        isPackage: false
                    )
                }
            )
        }
    }
}
