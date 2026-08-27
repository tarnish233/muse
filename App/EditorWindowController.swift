import AppKit
import MuseKit
import SwiftUI

/// Owns the AppKit document window while SwiftUI provides its split-view content.
@MainActor
final class EditorWindowController: NSWindowController {
    init(document: MuseDocument) {
        let chromeState = EditorChromeState()
        let hosting = NSHostingController(rootView: EditorShellView(document: document, chromeState: chromeState))
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting

        super.init(window: window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 960, height: 520)
        window.title = document.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
