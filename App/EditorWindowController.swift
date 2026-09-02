import AppKit
import MuseKit
import SwiftUI

/// Owns the AppKit document window while SwiftUI provides its split-view content.
@MainActor
final class EditorWindowController: NSWindowController {
    private let chromeState: EditorChromeState
    private let workspace: ProjectWorkspace
    private let navigation: EditorDocumentNavigation
    private let hostingController: NSHostingController<EditorShellView>
    private var activeDocument: MuseDocument
    private let openStateMachine = DocumentOpenStateMachine()
    private var closeCheckGeneration: Int?

    var isSourceMode: Bool { chromeState.isSourceMode }

    init(document: MuseDocument) {
        let chromeState = EditorChromeState()
        let workspace = ProjectWorkspace()
        let navigation = EditorDocumentNavigation()
        let hosting = NSHostingController(
            rootView: EditorShellView(
                document: document,
                chromeState: chromeState,
                workspace: workspace,
                navigation: navigation
            )
        )
        self.chromeState = chromeState
        self.workspace = workspace
        self.navigation = navigation
        hostingController = hosting
        activeDocument = document

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting

        super.init(window: window)
        navigation.openHandler = { [weak self] url in
            self?.requestOpenDocument(at: url)
        }
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 960, height: 520)
        window.title = document.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        // 标题栏控件要和红绿灯同一条中心线，所以几何必须从窗口读、不能写死。
        // 只在进出全屏时重测：中心线与组右缘都贴着窗口左上角，缩放窗口不会改变它们
        // （已实测 1pt 高与 760pt 高的内容区都给出同一个 16.00pt）。
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowControlsGeometryDidChange),
                name: name,
                object: window
            )
        }
        refreshWindowControlsGeometry()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowControlsGeometryDidChange() {
        refreshWindowControlsGeometry()
    }

    private func refreshWindowControlsGeometry() {
        guard let window else { return }
        chromeState.windowControls = WindowControlsGeometry.measured(in: window) ?? .unavailable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func requestOpenDocument(at url: URL) {
        perform(
            openStateMachine.requestOpen(
                at: url,
                currentURL: activeDocument.fileURL
            )
        )
    }

    @objc private func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let generation = closeCheckGeneration else { return }
        closeCheckGeneration = nil
        perform(
            openStateMachine.closeCheckCompleted(
                shouldClose,
                generation: generation,
                currentURL: activeDocument.fileURL
            )
        )
    }

    private func perform(_ step: DocumentOpenStateMachine.Step) {
        switch step {
        case .none:
            return
        case .activateCurrent:
            window?.makeKeyAndOrderFront(nil)
        case .checkCanClose(let request):
            if activeDocument.windowControllers.count > 1 {
                perform(
                    openStateMachine.closeCheckCompleted(
                        true,
                        generation: request.generation,
                        currentURL: activeDocument.fileURL
                    )
                )
                return
            }
            closeCheckGeneration = request.generation
            activeDocument.canClose(
                withDelegate: self,
                shouldClose: #selector(document(_:shouldClose:contextInfo:)),
                contextInfo: nil
            )
        case .open(let request):
            open(request)
        }
    }

    private func open(_ request: DocumentOpenStateMachine.Request) {
        NSDocumentController.shared.openDocument(
            withContentsOf: request.url,
            display: false
        ) { [weak self] document, wasAlreadyOpen, error in
            guard let self else {
                Self.discardIfOrphan(document, wasAlreadyOpen: wasAlreadyOpen)
                return
            }

            let result = DocumentOpenStateMachine.OpenResult(
                succeeded: error == nil && document != nil,
                wasAlreadyOpen: wasAlreadyOpen,
                isSupportedDocument: document is MuseDocument,
                hasDocument: document != nil
            )
            let decision = self.openStateMachine.openCompleted(
                generation: request.generation,
                result: result,
                currentURL: self.activeDocument.fileURL
            )
            self.handle(
                decision.disposition,
                document: document,
                wasAlreadyOpen: wasAlreadyOpen,
                error: error
            )
            self.perform(decision.next)
        }
    }

    private func handle(
        _ disposition: DocumentOpenStateMachine.CompletionDisposition,
        document: NSDocument?,
        wasAlreadyOpen: Bool,
        error: Error?
    ) {
        switch disposition {
        case .ignore:
            return
        case .discardNewDocument:
            Self.discardIfOrphan(document, wasAlreadyOpen: wasAlreadyOpen)
        case .presentError:
            presentOpenError(error ?? WorkspaceOperationError.unsupportedDocument)
        case .discardNewDocumentAndPresentError:
            Self.discardIfOrphan(document, wasAlreadyOpen: wasAlreadyOpen)
            presentOpenError(error ?? WorkspaceOperationError.unsupportedDocument)
        case .activateExistingDocument:
            guard let targetDocument = document as? MuseDocument else {
                presentOpenError(WorkspaceOperationError.unsupportedDocument)
                return
            }
            if targetDocument.windowControllers.isEmpty {
                targetDocument.makeWindowControllers()
            }
            targetDocument.showWindows()
            targetDocument.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        case .adoptNewDocument:
            guard let targetDocument = document as? MuseDocument else {
                Self.discardIfOrphan(document, wasAlreadyOpen: wasAlreadyOpen)
                presentOpenError(WorkspaceOperationError.unsupportedDocument)
                return
            }
            adopt(targetDocument)
        }
    }

    private static func discardIfOrphan(_ document: NSDocument?, wasAlreadyOpen: Bool) {
        guard !wasAlreadyOpen, let document, document.windowControllers.isEmpty else { return }
        document.close()
    }

    private func adopt(_ document: MuseDocument) {
        let previousDocument = activeDocument
        previousDocument.removeWindowController(self)
        document.addWindowController(self)
        activeDocument = document
        document.synchronizeLocation()

        hostingController.rootView = EditorShellView(
            document: document,
            chromeState: chromeState,
            workspace: workspace,
            navigation: navigation
        )
        window?.title = document.displayName
        window?.makeKeyAndOrderFront(nil)

        // canClose 在异步 open 开始前完成；加载期间旧文档仍可编辑，所以这里必须
        // 重新读取实时 dirty 状态，不能用先前的关闭许可直接 close。
        if DocumentOpenStateMachine.shouldClosePreviousDocument(
            isSameDocument: previousDocument === document,
            remainingWindowControllerCount: previousDocument.windowControllers.count,
            isDocumentEdited: previousDocument.isDocumentEdited
        ) {
            previousDocument.close()
        }
    }

    private func presentOpenError(_ error: Error) {
        guard let window else {
            NSApp.presentError(error)
            return
        }
        NSApp.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    }

    func toggleSourceMode() {
        chromeState.isSourceMode.toggle()
    }
}
