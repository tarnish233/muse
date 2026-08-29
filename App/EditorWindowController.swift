import AppKit
import MuseKit
import SwiftUI

/// Owns the AppKit document window while SwiftUI provides its split-view content.
@MainActor
final class EditorWindowController: NSWindowController {
    private let chromeState: EditorChromeState
    private let navigation: EditorDocumentNavigation
    private let hostingController: NSHostingController<EditorShellView>
    private var activeDocument: MuseDocument
    private var pendingOpenURL: URL?
    private var isCheckingCurrentDocument = false

    var isSourceMode: Bool { chromeState.isSourceMode }

    init(document: MuseDocument) {
        let chromeState = EditorChromeState()
        let navigation = EditorDocumentNavigation()
        let hosting = NSHostingController(
            rootView: EditorShellView(
                document: document,
                chromeState: chromeState,
                navigation: navigation
            )
        )
        self.chromeState = chromeState
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
        let normalizedURL = url.standardizedFileURL
        guard activeDocument.fileURL?.standardizedFileURL != normalizedURL else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        pendingOpenURL = normalizedURL
        guard !isCheckingCurrentDocument else { return }
        isCheckingCurrentDocument = true
        activeDocument.canClose(
            withDelegate: self,
            shouldClose: #selector(document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        isCheckingCurrentDocument = false
        guard shouldClose, let url = pendingOpenURL else {
            pendingOpenURL = nil
            return
        }
        pendingOpenURL = nil

        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [weak self] document, _, error in
            guard let self else { return }
            if let error {
                self.presentOpenError(error)
                return
            }
            guard let targetDocument = document as? MuseDocument else {
                self.presentOpenError(WorkspaceOperationError.unsupportedDocument)
                return
            }
            self.adopt(targetDocument)
        }
    }

    private func adopt(_ document: MuseDocument) {
        let previousDocument = activeDocument
        previousDocument.removeWindowController(self)
        document.addWindowController(self)
        activeDocument = document

        hostingController.rootView = EditorShellView(
            document: document,
            chromeState: chromeState,
            navigation: navigation
        )
        window?.title = document.displayName
        window?.makeKeyAndOrderFront(nil)

        if previousDocument !== document {
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
