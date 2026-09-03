import AppKit

final class WorkspaceCommandResponder: NSView, NSUserInterfaceValidations {
    var focusGeneration = 0

    private var canCopyItem = false
    private var copyItemAction: () -> Void = {}
    private var pasteItemsAction: () -> Void = {}
    private var createFileAction: () -> Void = {}
    private var createFolderAction: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    func configure(
        canCopyItem: Bool,
        copyItem: @escaping () -> Void,
        pasteItems: @escaping () -> Void,
        createFile: @escaping () -> Void,
        createFolder: @escaping () -> Void
    ) {
        self.canCopyItem = canCopyItem
        copyItemAction = copyItem
        pasteItemsAction = pasteItems
        createFileAction = createFile
        createFolderAction = createFolder
    }

    @objc func copy(_ sender: Any?) {
        guard canCopyItem else { return }
        copyItemAction()
    }

    @objc func paste(_ sender: Any?) {
        pasteItemsAction()
    }

    @objc func newWorkspaceFile(_ sender: Any?) {
        createFileAction()
    }

    @objc func newWorkspaceFolder(_ sender: Any?) {
        createFolderAction()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return canCopyItem
        }
        return true
    }
}
