import AppKit
import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var workspace: ProjectWorkspace
    let selectedFileURL: URL?
    let openFile: (URL) -> Void

    @State private var creationRequest: WorkspaceCreationRequest?
    @State private var alert: WorkspaceAlert?

    var body: some View {
        CodexSidebarSurface {
            if let project = workspace.project {
                ScrollView {
                    WorkspaceProjectTree(
                        project: project,
                        nodes: workspace.tree,
                        selectedFileURL: selectedFileURL,
                        createFile: { requestCreation(.file, in: $0) },
                        createFolder: { requestCreation(.folder, in: $0) },
                        openFile: selectFile,
                        revealInFinder: revealInFinder,
                        refreshProject: workspace.refreshProject,
                        removeProject: workspace.closeProject
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .museSoftScrollEdges()
            } else {
                emptyState
            }
        }
        .sheet(item: $creationRequest) { request in
            WorkspaceNameSheet(
                request: request,
                onCancel: dismissCreation,
                onSubmit: createRequestedItem
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
            }
        } catch {
            alert = WorkspaceAlert(message: error.localizedDescription)
        }
    }

    private func selectFile(_ url: URL) {
        guard workspace.canOpen(url) else {
            alert = WorkspaceAlert(message: WorkspaceOperationError.unsupportedDocument.localizedDescription)
            return
        }

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
}
