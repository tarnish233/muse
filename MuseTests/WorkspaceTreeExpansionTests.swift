import Foundation
import Testing

struct WorkspaceTreeExpansionTests {
    @Test func toggleTracksFolderExpansion() {
        let folder = URL(filePath: "/tmp/project/folder", directoryHint: .isDirectory)
        var expansion = WorkspaceTreeExpansion()

        expansion.toggleFolder(folder)
        #expect(expansion.containsFolder(folder))

        expansion.toggleFolder(folder)
        #expect(expansion.containsFolder(folder) == false)
    }

    @Test func togglingProjectPreservesExpandedFolders() {
        let folder = URL(filePath: "/tmp/project/folder", directoryHint: .isDirectory)
        var expansion = WorkspaceTreeExpansion()
        expansion.toggleFolder(folder)

        expansion.toggleProject()
        #expect(expansion.isProjectExpanded == false)
        #expect(expansion.containsFolder(folder))

        expansion.toggleProject()
        #expect(expansion.isProjectExpanded)
        #expect(expansion.containsFolder(folder))
    }

    @Test func collapseAllClearsEveryExpandedFolder() {
        var expansion = WorkspaceTreeExpansion()
        expansion.toggleFolder(URL(filePath: "/tmp/project/first", directoryHint: .isDirectory))
        expansion.toggleFolder(URL(filePath: "/tmp/project/second", directoryHint: .isDirectory))

        expansion.collapseAllFolders()

        #expect(expansion.hasExpandedFolders == false)
        #expect(expansion.isProjectExpanded)
    }
}
