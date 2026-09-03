import SwiftUI

struct WorkspaceBackgroundMenu: View {
    let paste: () -> Void
    let createFile: () -> Void
    let createFolder: () -> Void
    let refresh: () -> Void

    var body: some View {
        Button("粘贴", systemImage: "doc.on.clipboard", action: paste)
            .keyboardShortcut("v", modifiers: .command)

        Divider()

        Button("新建文件", systemImage: "doc.badge.plus", action: createFile)
            .keyboardShortcut("n", modifiers: .command)
        Button("新建文件夹", systemImage: "folder.badge.plus", action: createFolder)
            .keyboardShortcut("n", modifiers: [.command, .shift])

        Divider()

        Button("刷新", systemImage: "arrow.clockwise", action: refresh)
    }
}
