import Foundation

/// Routes workspace file selections back to the AppKit window controller.
/// The controller remains responsible for NSDocument lifecycle and save prompts.
@MainActor
final class EditorDocumentNavigation {
    var openHandler: ((URL) -> Void)?

    func open(_ url: URL) {
        openHandler?(url)
    }
}
