import MuseKit
import SwiftUI

struct EditorDetailView: View {
    let document: MuseDocument
    @ObservedObject var renderer: RenderCoordinator

    var body: some View {
        EditorView(document: document)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                RenderStatusView(renderer: renderer)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
    }
}
