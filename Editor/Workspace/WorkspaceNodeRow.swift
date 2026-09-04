import SwiftUI

struct WorkspaceNodeRow: View {
    let node: WorkspaceNode
    let selectedFileURL: URL?
    let actions: WorkspaceNodeActions
    @Binding var expansion: WorkspaceTreeExpansion
    @State private var isConfirmingDeletion = false

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
                        actions: actions,
                        expansion: $expansion
                    )
                    .padding(.leading, 16)
                }
            }
        }
        .contextMenu(menuItems: nodeMenu)
        .confirmationDialog(
            "将“\(node.name)”移到废纸篓？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                actions.delete(node)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(node.isFolder ? "文件夹及其中的内容都会被移到废纸篓。" : "该文件会被移到废纸篓。")
        }
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
            actions.openFile(node.url)
        }
    }

    @ViewBuilder
    private func nodeMenu() -> some View {
        if node.isFolder {
            Button("新建文件", systemImage: "doc.badge.plus") {
                actions.createFile(node.url)
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("新建文件夹", systemImage: "folder.badge.plus") {
                actions.createFolder(node.url)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
        } else {
            Button("打开", systemImage: "doc.text") {
                actions.openFile(node.url)
            }
            Divider()
        }

        Button("复制", systemImage: "doc.on.doc") {
            actions.copyItem(node)
        }
        .keyboardShortcut("c", modifiers: .command)
        Button("复制路径", systemImage: "link") {
            actions.copyPath(node)
        }
        Button("复制相对路径", systemImage: "arrow.turn.down.right") {
            actions.copyRelativePath(node)
        }
        Divider()
        Button("重命名", systemImage: "pencil") {
            actions.rename(node)
        }
        Button("删除", systemImage: "trash", role: .destructive) {
            isConfirmingDeletion = true
        }
        Divider()
        Button("在访达中显示", systemImage: "finder") {
            actions.revealInFinder(node.url)
        }
    }
}
