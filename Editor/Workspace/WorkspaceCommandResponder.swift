import AppKit

final class WorkspaceCommandResponder: NSView, NSUserInterfaceValidations {
    var focusGeneration = 0

    private var isActive = false
    private var canCopyItem = false
    private var canPasteItems: () -> Bool = { false }
    private var canCreateItem = false
    private var canUndo: () -> Bool = { false }
    private var canRedo: () -> Bool = { false }
    private var copyItemAction: () -> Void = {}
    private var pasteItemsAction: () -> Void = {}
    private var createFileAction: () -> Void = {}
    private var createFolderAction: () -> Void = {}
    private var undoAction: () -> Void = {}
    private var redoAction: () -> Void = {}
    private var restoreEditorFocusAction: () -> Void = {}

    override var acceptsFirstResponder: Bool { isActive }

    func configure(
        isActive: Bool,
        canCopyItem: Bool,
        canPasteItems: @escaping () -> Bool,
        canCreateItem: Bool,
        canUndo: @escaping () -> Bool,
        canRedo: @escaping () -> Bool,
        copyItem: @escaping () -> Void,
        pasteItems: @escaping () -> Void,
        createFile: @escaping () -> Void,
        createFolder: @escaping () -> Void,
        undo: @escaping () -> Void,
        redo: @escaping () -> Void,
        restoreEditorFocus: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.canCopyItem = canCopyItem
        self.canPasteItems = canPasteItems
        self.canCreateItem = canCreateItem
        self.canUndo = canUndo
        self.canRedo = canRedo
        copyItemAction = copyItem
        pasteItemsAction = pasteItems
        createFileAction = createFile
        createFolderAction = createFolder
        undoAction = undo
        redoAction = redo
        restoreEditorFocusAction = restoreEditorFocus
    }

    func synchronizeFocus(generation: Int) {
        guard isActive else {
            focusGeneration = generation
            restoreEditorFocusIfNeeded()
            return
        }
        guard focusGeneration != generation else { return }
        focusGeneration = generation
        window?.makeFirstResponder(self)
    }

    func deactivate(restoringEditorFocus: Bool) {
        isActive = false
        guard restoringEditorFocus else { return }
        restoreEditorFocusIfNeeded()
    }

    @objc func copy(_ sender: Any?) {
        guard isActive, canCopyItem else { return }
        copyItemAction()
    }

    @objc func paste(_ sender: Any?) {
        guard isActive, canPasteItems() else { return }
        pasteItemsAction()
    }

    @objc func newWorkspaceFile(_ sender: Any?) {
        guard isActive, canCreateItem else { return }
        createFileAction()
    }

    @objc func newWorkspaceFolder(_ sender: Any?) {
        guard isActive, canCreateItem else { return }
        createFolderAction()
    }

    @objc func undo(_ sender: Any?) {
        guard isActive, canUndo() else { return }
        undoAction()
    }

    @objc func redo(_ sender: Any?) {
        guard isActive, canRedo() else { return }
        redoAction()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard isActive else { return false }
        return switch item.action {
        case #selector(copy(_:)):
            canCopyItem
        case #selector(paste(_:)):
            canPasteItems()
        case #selector(newWorkspaceFile(_:)), #selector(newWorkspaceFolder(_:)):
            canCreateItem
        case #selector(undo(_:)):
            canUndo()
        case #selector(redo(_:)):
            canRedo()
        default:
            false
        }
    }

    private func restoreEditorFocusIfNeeded() {
        guard let window, window.firstResponder === self else { return }
        restoreEditorFocusAction()
        if window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }
}
