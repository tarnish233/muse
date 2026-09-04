import AppKit
import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var workspace: ProjectWorkspace
    let selectedFileURL: URL?
    let isPresented: Bool
    let openFile: (URL) -> Void
    let restoreEditorFocus: () -> Void

    @State private var creationRequest: WorkspaceCreationRequest?
    @State private var renamingNode: WorkspaceNode?
    @State private var pasteRequest: PasteRequest?
    @State private var alert: WorkspaceAlert?
    @State private var shortcutFocusGeneration = 0
    private let clipboard = WorkspaceClipboard()

    var body: some View {
        CodexSidebarSurface {
            if let project = workspace.project {
                ScrollView {
                    WorkspaceProjectTree(
                        project: project,
                        nodes: workspace.tree,
                        selectedFileURL: selectedFileURL,
                        nodeActions: nodeActions,
                        canUndoFileOperation: workspace.canUndoFileOperation,
                        canRedoFileOperation: workspace.canRedoFileOperation,
                        undoFileOperationTitle: workspace.undoFileOperationTitle,
                        redoFileOperationTitle: workspace.redoFileOperationTitle,
                        undoFileOperation: workspace.undoFileOperation,
                        redoFileOperation: workspace.redoFileOperation,
                        refreshProject: workspace.refreshProject,
                        removeProject: workspace.closeProject
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .contextMenu {
                    WorkspaceBackgroundMenu(
                        paste: { requestPaste(into: project.rootURL) },
                        createFile: { requestCreation(.file, in: project.rootURL) },
                        createFolder: { requestCreation(.folder, in: project.rootURL) },
                        refresh: workspace.refreshProject
                    )
                }
                .museSoftScrollEdges()
            } else {
                emptyState
            }
        }
        .background {
            WorkspaceShortcutResponder(
                isActive: isPresented && workspace.project != nil,
                focusGeneration: shortcutFocusGeneration,
                canCopyItem: selectedNode != nil,
                canPasteItems: canPasteItems,
                canCreateItem: workspace.project != nil,
                canUndo: { workspace.canUndoFileOperation },
                canRedo: { workspace.canRedoFileOperation },
                copyItem: copySelectedNode,
                pasteItems: pasteIntoProjectRoot,
                createFile: createFileInProjectRoot,
                createFolder: createFolderInProjectRoot,
                undo: workspace.undoFileOperation,
                redo: workspace.redoFileOperation,
                restoreEditorFocus: restoreEditorFocus
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(item: $creationRequest) { request in
            WorkspaceNameSheet(
                title: request.kind.title,
                prompt: request.kind.prompt,
                initialName: request.kind.initialName,
                submitTitle: "创建",
                onCancel: dismissCreation,
                onSubmit: createRequestedItem
            )
        }
        .sheet(item: $renamingNode) { node in
            WorkspaceNameSheet(
                title: "重命名",
                prompt: "输入新名称",
                initialName: node.name,
                submitTitle: "重命名",
                onCancel: dismissRename,
                onSubmit: { renameRequestedItem(node, to: $0) }
            )
        }
        .alert(item: $alert) { alert in
            Alert(title: Text("操作失败"), message: Text(alert.message))
        }
        .onChange(of: workspace.presentedError) { _, message in
            guard let message else { return }
            alert = WorkspaceAlert(message: message)
            workspace.presentedError = nil
        }
        .task(id: pasteRequest?.id) {
            await performPasteRequest()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还没有项目", systemImage: "folder.badge.plus")
                .font(.system(size: 13, weight: .medium))

            Text("新建项目，或打开一个已有文件夹。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                compactAction("新建项目", action: createProject)
                compactAction("打开项目…", action: openProject)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var nodeActions: WorkspaceNodeActions {
        WorkspaceNodeActions(
            createFile: { requestCreation(.file, in: $0) },
            createFolder: { requestCreation(.folder, in: $0) },
            openFile: selectFile,
            revealInFinder: revealInFinder,
            copyItem: copyItem,
            copyPath: copyPath,
            copyRelativePath: copyRelativePath,
            rename: requestRename,
            delete: deleteNode
        )
    }

    private var selectedNode: WorkspaceNode? {
        workspace.node(at: selectedFileURL)
    }

    private func compactAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(0.055), in: .rect(cornerRadius: 8))
    }

    private func createProject() {
        let panel = NSSavePanel()
        panel.title = "新建项目"
        panel.prompt = "创建"
        panel.nameFieldLabel = "项目名称："
        panel.nameFieldStringValue = "Muse Project"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try workspace.createProject(at: url) }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.title = "打开项目"
        panel.prompt = "打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try workspace.openProject(at: url) }
    }

    private func requestCreation(_ kind: WorkspaceCreationRequest.Kind, in parentURL: URL) {
        creationRequest = WorkspaceCreationRequest(kind: kind, parentURL: parentURL)
    }

    private func dismissCreation() {
        creationRequest = nil
    }

    private func createRequestedItem(named name: String) {
        guard let request = creationRequest else { return }
        do {
            let url = try workspace.createItem(request.kind, named: name, in: request.parentURL)
            creationRequest = nil
            if request.kind == .file {
                selectFile(url)
            } else {
                requestShortcutFocus()
            }
        } catch {
            alert = WorkspaceAlert(message: error.localizedDescription)
        }
    }

    private func requestRename(_ node: WorkspaceNode) {
        renamingNode = node
    }

    private func dismissRename() {
        renamingNode = nil
    }

    private func renameRequestedItem(_ node: WorkspaceNode, to name: String) {
        do {
            try workspace.rename(node, to: name)
            renamingNode = nil
            requestShortcutFocus()
        } catch {
            alert = WorkspaceAlert(message: error.localizedDescription)
        }
    }

    private func deleteNode(_ node: WorkspaceNode) {
        perform {
            try workspace.moveToTrash(node)
            requestShortcutFocus()
        }
    }

    private func copyItem(_ node: WorkspaceNode) {
        perform { try clipboard.copyItem(at: node.url) }
    }

    private func copyPath(_ node: WorkspaceNode) {
        perform { try clipboard.copyText(node.url.path) }
    }

    private func copyRelativePath(_ node: WorkspaceNode) {
        perform {
            guard let relativePath = workspace.project?.relativePath(to: node.url) else {
                throw WorkspaceOperationError.itemOutsideProject
            }
            try clipboard.copyText(relativePath)
        }
    }

    private func requestPaste(into parentURL: URL) {
        let sourceURLs = clipboard.fileURLs()
        guard !sourceURLs.isEmpty else {
            alert = WorkspaceAlert(message: WorkspaceOperationError.clipboardContainsNoFiles.localizedDescription)
            return
        }
        pasteRequest = PasteRequest(sourceURLs: sourceURLs, parentURL: parentURL)
    }

    private func requestShortcutFocus() {
        shortcutFocusGeneration &+= 1
    }

    private func copySelectedNode() {
        guard let selectedNode else { return }
        copyItem(selectedNode)
    }

    private func canPasteItems() -> Bool {
        !clipboard.fileURLs().isEmpty
    }

    private func pasteIntoProjectRoot() {
        guard let rootURL = workspace.project?.rootURL else { return }
        requestPaste(into: rootURL)
    }

    private func createFileInProjectRoot() {
        guard let rootURL = workspace.project?.rootURL else { return }
        requestCreation(.file, in: rootURL)
    }

    private func createFolderInProjectRoot() {
        guard let rootURL = workspace.project?.rootURL else { return }
        requestCreation(.folder, in: rootURL)
    }

    private func performPasteRequest() async {
        guard let request = pasteRequest else { return }
        do {
            try await workspace.pasteItems(request.sourceURLs, into: request.parentURL)
            guard Self.shouldApplyPasteCompletion(
                completedRequestID: request.id,
                currentRequestID: pasteRequest?.id,
                isCancelled: Task.isCancelled
            ) else { return }
            pasteRequest = nil
            if workspace.project(containing: request.parentURL) != nil {
                requestShortcutFocus()
            }
        } catch is CancellationError {
            // SwiftUI 会在侧边栏消失或下一次粘贴开始时取消当前任务。
        } catch {
            alert = WorkspaceAlert(message: error.localizedDescription)
        }
    }

    private func selectFile(_ url: URL) {
        guard workspace.canOpen(url) else {
            alert = WorkspaceAlert(message: WorkspaceOperationError.unsupportedDocument.localizedDescription)
            return
        }

        // A previous rename/delete/paste may have deliberately focused the workspace
        // responder so ⌘Z targets its file-operation undo stack. File activation returns
        // command routing to the editor before same-window document navigation begins.
        restoreEditorFocus()
        openFile(url)
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            alert = WorkspaceAlert(message: error.localizedDescription)
        }
    }

    private struct PasteRequest {
        let id = UUID()
        let sourceURLs: [URL]
        let parentURL: URL
    }

    static func shouldApplyPasteCompletion(
        completedRequestID: UUID,
        currentRequestID: UUID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && completedRequestID == currentRequestID
    }
}
