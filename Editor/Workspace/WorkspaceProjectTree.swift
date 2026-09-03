import SwiftUI

struct WorkspaceProjectTree: View {
    let project: WorkspaceProject
    let nodes: [WorkspaceNode]
    let selectedFileURL: URL?
    let nodeActions: WorkspaceNodeActions
    let revealInFinder: (URL) -> Void
    let refreshProject: () -> Void
    let removeProject: () -> Void

    @State private var expansion = WorkspaceTreeExpansion()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            projectRow

            if expansion.isProjectExpanded {
                ForEach(nodes) { node in
                    WorkspaceNodeRow(
                        node: node,
                        selectedFileURL: selectedFileURL,
                        actions: nodeActions,
                        expansion: $expansion
                    )
                    .padding(.leading, 17)
                }
            }
        }
        .contextMenu(menuItems: projectMenu)
    }

    private var projectRow: some View {
        HStack(spacing: 2) {
            Button(action: toggleProject) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expansion.isProjectExpanded ? 90 : 0))
                        .frame(width: 10, height: 18)

                    Image(systemName: WorkspaceTreeIcon.systemName(
                        isFolder: true,
                        isExpanded: expansion.isProjectExpanded
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            WorkspaceProjectActionButton(
                title: "新建文件",
                systemImage: "doc.badge.plus",
                action: createFileInProject
            )
            WorkspaceProjectActionButton(
                title: "新建文件夹",
                systemImage: "folder.badge.plus",
                action: createFolderInProject
            )
            WorkspaceProjectActionButton(
                title: "刷新项目",
                systemImage: "arrow.clockwise",
                action: refreshProject
            )
            WorkspaceProjectActionButton(
                title: "全部折叠",
                systemImage: "rectangle.stack.badge.minus",
                action: collapseAllFolders
            )
        }
        .padding(.horizontal, 7)
        .frame(height: 29)
        .contentShape(.rect)
        .background(Color.clear, in: .rect(cornerRadius: 9))
    }

    @ViewBuilder
    private func projectMenu() -> some View {
        Button("在访达中显示", systemImage: "finder") {
            revealInFinder(project.rootURL)
        }
        Button("从侧边栏移除", systemImage: "minus.circle", action: removeProject)
    }

    private func toggleProject() {
        expansion.toggleProject()
    }

    private func createFileInProject() {
        nodeActions.createFile(project.rootURL)
    }

    private func createFolderInProject() {
        nodeActions.createFolder(project.rootURL)
    }

    private func collapseAllFolders() {
        expansion.collapseAllFolders()
    }
}
