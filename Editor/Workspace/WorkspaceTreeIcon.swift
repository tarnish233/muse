enum WorkspaceTreeIcon {
    static func systemName(isFolder: Bool, isExpanded: Bool) -> String {
        guard isFolder else { return "doc.text" }
        return isExpanded ? "folder.fill" : "folder"
    }
}
