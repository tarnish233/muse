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
}
