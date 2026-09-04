import SwiftUI

struct WorkspaceShortcutResponder: NSViewRepresentable {
    let isActive: Bool
    let focusGeneration: Int
    let canCopyItem: Bool
    let canPasteItems: () -> Bool
    let canCreateItem: Bool
    let canUndo: () -> Bool
    let canRedo: () -> Bool
    let copyItem: () -> Void
    let pasteItems: () -> Void
    let createFile: () -> Void
    let createFolder: () -> Void
    let undo: () -> Void
    let redo: () -> Void
    let restoreEditorFocus: () -> Void

    func makeNSView(context: Context) -> WorkspaceCommandResponder {
        let responder = WorkspaceCommandResponder()
        responder.focusGeneration = focusGeneration
        configure(responder)
        return responder
    }

    func updateNSView(_ responder: WorkspaceCommandResponder, context: Context) {
        configure(responder)
        responder.synchronizeFocus(generation: focusGeneration)
    }

    static func dismantleNSView(_ responder: WorkspaceCommandResponder, coordinator: ()) {
        // Root-view replacement can dismantle the old document's sidebar while a new
        // editor is being installed. Do not pull focus back to the outgoing document.
        responder.deactivate(restoringEditorFocus: false)
    }

    private func configure(_ responder: WorkspaceCommandResponder) {
        responder.configure(
            isActive: isActive,
            canCopyItem: canCopyItem,
            canPasteItems: canPasteItems,
            canCreateItem: canCreateItem,
            canUndo: canUndo,
            canRedo: canRedo,
            copyItem: copyItem,
            pasteItems: pasteItems,
            createFile: createFile,
            createFolder: createFolder,
            undo: undo,
            redo: redo,
            restoreEditorFocus: restoreEditorFocus
        )
    }
}
