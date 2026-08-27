import SwiftUI

struct WorkspaceProjectTree: View {
    let project: WorkspaceProject
    let nodes: [WorkspaceNode]
    let selectedFileURL: URL?
    let createFile: (URL) -> Void
    let createFolder: (URL) -> Void
    let openFile: (URL) -> Void
    let revealInFinder: (URL) -> Void
    let removeProject: () -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            projectRow

            if isExpanded {
                ForEach(nodes) { node in
                    WorkspaceNodeRow(
                        node: node,
                        selectedFileURL: selectedFileURL,
                        createFile: createFile,
                        createFolder: createFolder,
                        openFile: openFile,
                        revealInFinder: revealInFinder
                    )
                    .padding(.leading, 17)
                }
            }
        }
        .contextMenu(menuItems: projectMenu)
    }

    private var projectRow: some View {
        HStack(spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text(project.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            Menu(content: projectMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 7)
        .frame(height: 29)
        .contentShape(.rect)
        .background(Color.clear, in: .rect(cornerRadius: 9))
        .onTapGesture {
            isExpanded.toggle()
        }
    }

    @ViewBuilder
    private func projectMenu() -> some View {
        Button("新建文件", systemImage: "doc.badge.plus") {
            createFile(project.rootURL)
        }
        Button("新建文件夹", systemImage: "folder.badge.plus") {
            createFolder(project.rootURL)
        }
        Divider()
        Button("在访达中显示", systemImage: "finder") {
            revealInFinder(project.rootURL)
        }
        Button("从侧边栏移除", systemImage: "minus.circle", action: removeProject)
    }
}
