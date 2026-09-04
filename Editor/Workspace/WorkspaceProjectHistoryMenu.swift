import SwiftUI

struct WorkspaceProjectHistoryMenu: View {
    let canUndo: Bool
    let canRedo: Bool
    let undoTitle: String
    let redoTitle: String
    let undo: () -> Void
    let redo: () -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            Button(undoTitle, systemImage: "arrow.uturn.backward", action: undo)
                .disabled(!canUndo)
            Button(redoTitle, systemImage: "arrow.uturn.forward", action: redo)
                .disabled(!canRedo)
        } label: {
            Label("文件操作历史", systemImage: "arrow.counterclockwise")
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    isHovered ? Color.primary.opacity(0.07) : .clear,
                    in: .rect(cornerRadius: 5)
                )
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("文件操作历史")
        .disabled(!canUndo && !canRedo)
    }
}
