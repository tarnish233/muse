import SwiftUI

struct WorkspaceShortcutResponder: NSViewRepresentable {
    let focusGeneration: Int
    let canCopyItem: Bool
    let copyItem: () -> Void
    let pasteItems: () -> Void
    let createFile: () -> Void
    let createFolder: () -> Void

    func makeNSView(context: Context) -> WorkspaceCommandResponder {
        let responder = WorkspaceCommandResponder()
        responder.focusGeneration = focusGeneration
        configure(responder)
        return responder
    }

    func updateNSView(_ responder: WorkspaceCommandResponder, context: Context) {
        configure(responder)
        guard responder.focusGeneration != focusGeneration else { return }
        responder.focusGeneration = focusGeneration

        Task { @MainActor [weak responder] in
            await Task.yield()
            guard let responder, responder.focusGeneration == focusGeneration else { return }
            responder.window?.makeFirstResponder(responder)
        }
    }

    private func configure(_ responder: WorkspaceCommandResponder) {
        responder.configure(
            canCopyItem: canCopyItem,
            copyItem: copyItem,
            pasteItems: pasteItems,
            createFile: createFile,
            createFolder: createFolder
        )
    }
}
