import AppKit

@MainActor
struct WorkspaceClipboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func copyItem(at url: URL) throws {
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            throw WorkspaceOperationError.clipboardWriteFailed
        }
    }

    func copyText(_ text: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw WorkspaceOperationError.clipboardWriteFailed
        }
    }

    func fileURLs() -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [NSURL])?.map { $0 as URL } ?? []
    }
}
