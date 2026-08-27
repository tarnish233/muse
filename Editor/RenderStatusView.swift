import MuseKit
import SwiftUI

struct RenderStatusView: View {
    @ObservedObject var renderer: RenderCoordinator

    var body: some View {
        Label(renderer.statusText, systemImage: "waveform")
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
    }
}
