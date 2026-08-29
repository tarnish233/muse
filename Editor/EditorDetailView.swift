import MuseKit
import SwiftUI

struct EditorDetailView: View {
    let document: MuseDocument
    let isSourceMode: Bool
    let previewBaseURL: URL?
    @ObservedObject var renderer: RenderCoordinator

    var body: some View {
        EditorView(
            document: document,
            isSourceMode: isSourceMode,
            previewBaseURL: previewBaseURL
        )
            .id(ObjectIdentifier(document))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                RenderStatusView(renderer: renderer)
                    .padding(.trailing, 30)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
    }
}
