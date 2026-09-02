import Testing

struct WorkspaceTreeIconTests {
    @Test func expandedFolderUsesFilledFolderIcon() {
        #expect(WorkspaceTreeIcon.systemName(isFolder: true, isExpanded: true) == "folder.fill")
    }

    @Test func collapsedFolderUsesOutlineFolderIcon() {
        #expect(WorkspaceTreeIcon.systemName(isFolder: true, isExpanded: false) == "folder")
    }

    @Test func fileIconDoesNotDependOnExpansionState() {
        #expect(WorkspaceTreeIcon.systemName(isFolder: false, isExpanded: false) == "doc.text")
        #expect(WorkspaceTreeIcon.systemName(isFolder: false, isExpanded: true) == "doc.text")
    }
}
