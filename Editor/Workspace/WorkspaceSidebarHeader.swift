import SwiftUI

struct WorkspaceSidebarHeader: View {
    let createProject: () -> Void
    let openProject: () -> Void

    var body: some View {
        HStack {
            Text("项目")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu(content: menuContent) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("新建或打开项目")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func menuContent() -> some View {
        Button("新建项目…", systemImage: "folder.badge.plus", action: createProject)
        Button("打开项目…", systemImage: "folder", action: openProject)
    }
}
