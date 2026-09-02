import SwiftUI

struct WorkspaceNodeRow: View {
    let node: WorkspaceNode
    let selectedFileURL: URL?
    let createFile: (URL) -> Void
    let createFolder: (URL) -> Void
    let openFile: (URL) -> Void
    let revealInFinder: (URL) -> Void
    @Binding var expansion: WorkspaceTreeExpansion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: activate) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(node.isFolder && isExpanded ? 90 : 0))
                        .opacity(node.isFolder ? 1 : 0)
                        .frame(width: 9, height: 18)

                    Image(systemName: WorkspaceTreeIcon.systemName(
                        isFolder: node.isFolder,
                        isExpanded: isExpanded
                    ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text(node.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: 29)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(isSelected ? Color.primary.opacity(0.09) : .clear, in: .rect(cornerRadius: 9))

            if node.isFolder && isExpanded {
                ForEach(node.children ?? []) { child in
                    WorkspaceNodeRow(
                        node: child,
                        selectedFileURL: selectedFileURL,
                        createFile: createFile,
                        createFolder: createFolder,
                        openFile: openFile,
                        revealInFinder: revealInFinder,
                        expansion: $expansion
                    )
                    .padding(.leading, 16)
                }
            }
        }
        .contextMenu(menuItems: nodeMenu)
    }

    private var isSelected: Bool {
        selectedFileURL == node.url.standardizedFileURL
    }

    private var isExpanded: Bool {
        node.isFolder && expansion.containsFolder(node.url)
    }

    private func activate() {
        if node.isFolder {
            expansion.toggleFolder(node.url)
        } else {
            openFile(node.url)
        }
    }

    @ViewBuilder
    private func nodeMenu() -> some View {
        if node.isFolder {
            Button("新建文件", systemImage: "doc.badge.plus") {
                createFile(node.url)
            }
            Button("新建文件夹", systemImage: "folder.badge.plus") {
                createFolder(node.url)
            }
            Divider()
        } else {
            Button("打开", systemImage: "doc.text") {
                openFile(node.url)
            }
        }
        Button("在访达中显示", systemImage: "finder") {
            revealInFinder(node.url)
        }
    }
}
