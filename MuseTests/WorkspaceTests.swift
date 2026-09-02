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

    @Test func createsProjectFolderAndMarkdownFile() async throws {
        let (workspace, root, defaults, suiteName) = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        try workspace.createProject(at: root)
        let notes = try workspace.createItem(.folder, named: "Notes", in: root)
        let document = try workspace.createItem(.file, named: "First", in: notes)
        await workspace.waitForRefresh()

        #expect(workspace.project?.rootURL == root)
        #expect(document.lastPathComponent == "First.md")
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(workspace.tree.first?.name == "Notes")
    }

    @Test func foldersSortBeforeFilesAndNamesUseFinderOrdering() async throws {
        let (workspace, root, _, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try workspace.createProject(at: root)
        _ = try workspace.createItem(.file, named: "10.md", in: root)
        _ = try workspace.createItem(.file, named: "2.md", in: root)
        _ = try workspace.createItem(.folder, named: "Archive", in: root)
        await workspace.waitForRefresh()

        let names = workspace.tree.map(\.name)
        #expect(names == ["Archive", "2.md", "10.md"])
    }

    @Test func removingProjectDoesNotDeleteItsDirectory() throws {
        let (workspace, root, _, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try workspace.createProject(at: root)
        workspace.closeProject()

        #expect(workspace.project == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func rejectsInvalidNamesAndUnsupportedFiles() async throws {
        let (workspace, root, _, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try workspace.createProject(at: root)
        await workspace.waitForRefresh()

        #expect(throws: WorkspaceOperationError.self) {
            try workspace.createItem(.file, named: "bad/name", in: root)
        }
        #expect(workspace.canOpen(root.appending(path: "note.md")))
        #expect(workspace.canOpen(root.appending(path: "image.png")) == false)
    }

    @Test func staleBookmarkRestoresProjectAndRewritesOnce() throws {
        let root = try makeDirectory(named: "Stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBookmark = Data([1])
        let refreshedBookmark = Data([9])
        let store = StoreRecorder(data: try encodedBookmark(oldBookmark))
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { url in
                    #expect(url.standardizedFileURL == root.standardizedFileURL)
                    return refreshedBookmark
                },
                resolve: { _ in WorkspaceBookmarkResolution(url: root, isStale: true) }
            ),
            projectStore: store.store
        )

        #expect(workspace.project?.rootURL == root.standardizedFileURL)
        #expect(store.saved.count == 1)
        #expect(try decodedBookmark(store.saved[0]) == refreshedBookmark)
    }

    @Test func failedStaleRegenerationRetainsPreviousBookmark() throws {
        let root = try makeDirectory(named: "StaleFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBookmark = Data([3])
        let store = StoreRecorder(data: try encodedBookmark(oldBookmark))
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in throw TestFailure.expected },
                resolve: { _ in WorkspaceBookmarkResolution(url: root, isStale: true) }
            ),
            projectStore: store.store
        )

        #expect(workspace.project?.rootURL == root.standardizedFileURL)
        #expect(store.saved.isEmpty)
        #expect(workspace.presentedError != nil)
    }

    @Test func corruptStoredProjectIsBackedUpBeforeSavingReplacement() throws {
        let root = try makeDirectory(named: "CorruptStore")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("not valid project JSON".utf8)
        let bookmark = Data([7])
        let store = StoreRecorder(data: original)
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in bookmark },
                resolve: { _ in throw TestFailure.expected }
            ),
            projectStore: store.store
        )

        #expect(store.data == original)
        #expect(store.backups[store.backupLocation] == original)
        #expect(workspace.presentedError?.contains(store.backupLocation) == true)

        try workspace.openProject(at: root)

        let saved = try #require(store.data)
        #expect(try decodedBookmark(saved) == bookmark)
        #expect(workspace.project?.rootURL == root.standardizedFileURL)
    }

    @Test func failedCorruptStoreBackupBlocksReplacementSave() throws {
        let root = try makeDirectory(named: "CorruptStoreBackupFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("not valid project JSON".utf8)
        let store = StoreRecorder(data: original)
        store.backupError = TestFailure.expected
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in Data([7]) },
                resolve: { _ in throw TestFailure.expected }
            ),
            projectStore: store.store
        )

        #expect(workspace.presentedError?.contains("保存已暂停") == true)
        #expect(store.backups.isEmpty)

        do {
            try workspace.openProject(at: root)
            Issue.record("备份失败后不应覆盖原项目数据")
        } catch {
            #expect(error.localizedDescription.contains("保存已暂停"))
        }

        #expect(store.data == original)
        #expect(store.saved.isEmpty)
        #expect(workspace.project == nil)
    }

    @Test func userDefaultsStoreWritesCorruptBackupUnderSeparateTimestampedKey() throws {
        let suiteName = "MuseWorkspaceStoreBackupTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "Muse.workspace.project.test"
        let original = Data("corrupt".utf8)
        let store = WorkspaceProjectStore.userDefaults(defaults, key: key)

        let backupLocation = try store.backupCorruptData(original)

        #expect(backupLocation.hasPrefix("\(key).corrupt-"))
        #expect(defaults.data(forKey: backupLocation) == original)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func missingStoredProjectIsSilentAndDoesNotBlockSaving() throws {
        let root = try makeDirectory(named: "MissingStore")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = Data([7])
        let store = StoreRecorder()
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in bookmark },
                resolve: { _ in throw TestFailure.expected }
            ),
            projectStore: store.store
        )

        #expect(workspace.presentedError == nil)

        try workspace.openProject(at: root)

        #expect(store.saved.count == 1)
        #expect(try decodedBookmark(store.saved[0]) == bookmark)
    }

    @Test func openingProjectCommitsOnlyAfterBookmarkCreationSucceeds() throws {
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
            try workspace.openProject(at: root)
        }
        #expect(workspace.project == nil)
        #expect(store.saved.isEmpty)
    }

    @Test func openingAnotherProjectReplacesTheCurrentProject() throws {
        let firstRoot = try makeDirectory(named: "FirstProject")
        let secondRoot = try makeDirectory(named: "SecondProject")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let firstBookmark = Data([5])
        let secondBookmark = Data([6])
        let store = StoreRecorder()
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { url in
                    url.standardizedFileURL == firstRoot.standardizedFileURL
                        ? firstBookmark
                        : secondBookmark
                },
                resolve: { _ in throw TestFailure.expected }
            ),
            projectStore: store.store
        )

        try workspace.openProject(at: firstRoot)
        try workspace.openProject(at: secondRoot)

        #expect(workspace.project?.rootURL == secondRoot.standardizedFileURL)
        #expect(store.saved.count == 2)
        #expect(try decodedBookmark(store.saved[1]) == secondBookmark)
    }

    @Test func separateWorkspaceInstancesKeepProjectsIndependent() throws {
        let firstRoot = try makeDirectory(named: "FirstWindow")
        let secondRoot = try makeDirectory(named: "SecondWindow")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let bookmarking = WorkspaceBookmarking(
            create: { url in Data(url.path.utf8) },
            resolve: { _ in throw TestFailure.expected }
        )
        let firstWorkspace = ProjectWorkspace(
            bookmarking: bookmarking,
            projectStore: StoreRecorder().store
        )
        let secondWorkspace = ProjectWorkspace(
            bookmarking: bookmarking,
            projectStore: StoreRecorder().store
        )

        try firstWorkspace.openProject(at: firstRoot)
        try secondWorkspace.openProject(at: secondRoot)

        #expect(firstWorkspace.project?.rootURL == firstRoot.standardizedFileURL)
        #expect(secondWorkspace.project?.rootURL == secondRoot.standardizedFileURL)
    }

    @Test func closingProjectPersistsAnEmptyWorkspaceWithoutDeletingDirectory() throws {
        let root = try makeDirectory(named: "CloseProject")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StoreRecorder()
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in Data([5]) },
                resolve: { _ in throw TestFailure.expected }
            ),
            projectStore: store.store
        )

        try workspace.openProject(at: root)
        workspace.closeProject()

        #expect(workspace.project == nil)
        let saved = try #require(store.saved.last)
        #expect(try decodedBookmark(saved) == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func rootEnumerationFailurePreservesPreviousSnapshot() async throws {
        let root = try makeDirectory(named: "RootFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "visible.md")
        try Data().write(to: file)
        let state = FileSystemState(root: root, entries: [file])
        let workspace = try await makeInjectedWorkspace(root: root, fileSystem: state.fileSystem)
        #expect(workspace.tree.map(\.name) == ["visible.md"])

        state.failRoot = true
        workspace.refreshProject()
        await workspace.waitForRefresh()

        #expect(workspace.tree.map(\.name) == ["visible.md"])
        #expect(workspace.presentedError != nil)
    }

    @Test func childMetadataFailureSkipsOnlyThatChild() async throws {
        let root = try makeDirectory(named: "MetadataFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appending(path: "bad.md")
        let good = root.appending(path: "good.md")
        let state = FileSystemState(root: root, entries: [bad, good])
        state.metadataFailures.insert(bad)

        let workspace = try await makeInjectedWorkspace(root: root, fileSystem: state.fileSystem)

        #expect(workspace.tree.map(\.name) == ["good.md"])
        #expect(workspace.presentedError != nil)
    }

    @Test func unreadableChildDirectoryRemainsVisibleWithSiblings() async throws {
        let root = try makeDirectory(named: "NestedFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        let file = root.appending(path: "visible.md")
        let state = FileSystemState(root: root, entries: [folder, file])
        state.directories.insert(folder)
        state.directoryFailures.insert(folder)

        let workspace = try await makeInjectedWorkspace(root: root, fileSystem: state.fileSystem)
        let nodes = workspace.tree

        #expect(nodes.map(\.name) == ["Folder", "visible.md"])
        #expect(nodes.first?.isFolder == true)
        #expect(nodes.first?.children == nil)
    }

    @Test func slowDirectoryRefreshDoesNotBlockMainActor() async throws {
        let root = try makeDirectory(named: "SlowRefresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "visible.md")
        let state = FileSystemState(root: root, entries: [file])
        let workspace = try await makeInjectedWorkspace(root: root, fileSystem: state.fileSystem)

        state.enumerationDelay = 0.25
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            workspace.refreshProject()
        }

        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        #expect(milliseconds < 50)
        await workspace.waitForRefresh()
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
    ) async throws -> ProjectWorkspace {
        let store = StoreRecorder()
        let workspace = ProjectWorkspace(
            bookmarking: WorkspaceBookmarking(
                create: { _ in Data([7]) },
                resolve: { _ in WorkspaceBookmarkResolution(url: root, isStale: false) }
            ),
            projectStore: store.store,
            fileSystem: fileSystem
        )
        try workspace.openProject(at: root)
        await workspace.waitForRefresh()
        return workspace
    }

    private func encodedBookmark(_ bookmark: Data?) throws -> Data {
        try JSONEncoder().encode(bookmark.map(ProjectWorkspace.StoredProject.init(bookmark:)))
    }

    private func decodedBookmark(_ data: Data) throws -> Data? {
        try JSONDecoder().decode(ProjectWorkspace.StoredProject?.self, from: data)?.bookmark
    }

    private enum TestFailure: Error {
        case expected
    }

    private final class StoreRecorder {
        var data: Data?
        var saved: [Data] = []
        var backups: [String: Data] = [:]
        var backupError: Error?
        let backupLocation = "Muse.workspace.project.corrupt-test"

        init(data: Data? = nil) {
            self.data = data
        }

        var store: WorkspaceProjectStore {
            WorkspaceProjectStore(
                load: { [weak self] in self?.data },
                save: { [weak self] data in
                    self?.data = data
                    self?.saved.append(data)
                },
                backupCorruptData: { [weak self] data in
                    guard let self else { throw TestFailure.expected }
                    if let backupError { throw backupError }
                    backups[backupLocation] = data
                    return backupLocation
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
        var enumerationDelay: TimeInterval = 0

        init(root: URL, entries: [URL]) {
            self.root = root.standardizedFileURL
            self.entries = entries
        }

        var fileSystem: WorkspaceFileSystem {
            WorkspaceFileSystem(
                contentsOfDirectory: { [weak self] url in
                    guard let self else { return [] }
                    if self.enumerationDelay > 0 {
                        Thread.sleep(forTimeInterval: self.enumerationDelay)
                    }
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
