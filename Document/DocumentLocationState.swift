import Foundation
import Observation

/// Main-actor mirror of NSDocument's location for SwiftUI and rendering clients.
/// NSDocument.fileURL remains the writable lifecycle authority.
@MainActor
@Observable
public final class DocumentLocationState {
    public private(set) var fileURL: URL?
    public private(set) var displayName: String

    public var directoryURL: URL? {
        fileURL?.deletingLastPathComponent()
    }

    public init(fileURL: URL? = nil, displayName: String = "Untitled") {
        self.fileURL = fileURL?.standardizedFileURL
        self.displayName = displayName
    }

    func update(fileURL: URL?, displayName: String) {
        self.fileURL = fileURL?.standardizedFileURL
        self.displayName = displayName
    }
}
