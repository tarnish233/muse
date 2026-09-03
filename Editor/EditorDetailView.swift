import MuseKit
import SwiftUI

struct EditorDetailView: View {
    let document: MuseDocument
    let isSourceMode: Bool
    let previewBaseURL: URL?

    var body: some View {
        EditorView(
            document: document,
            isSourceMode: isSourceMode,
            previewBaseURL: previewBaseURL
        )
            .id(ObjectIdentifier(document))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
