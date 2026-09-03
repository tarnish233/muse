import MuseKit
import SwiftUI

struct CodexDocumentTitlebar: View {
    let title: String
    let windowControls: WindowControlsGeometry
    let reservesWindowControls: Bool
    let reservesOutlineToggle: Bool
    /// Held, not observed. `RenderStatusView` does the observing, so a status
    /// publish on every keystroke re-renders only the readout instead of
    /// invalidating this whole band.
    let renderer: RenderCoordinator

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            // A readout, not a control: it must never eat a titlebar drag. Fixed
            // so a long filename truncates (it already does, mid-string) instead
            // of squeezing the digits.
            RenderStatusView(renderer: renderer)
                .fixedSize()
                .allowsHitTesting(false)
        }
        // Sits on the traffic-light centerline like the toggles do, read from the
        // window rather than centered in the band. The band is sized to `2 ×` that
        // line (see `EditorChromeMetrics.titlebarHeight`), so this lands with equal
        // clearance above and below — but the alignment still comes from the
        // measurement, so it survives AppKit moving the buttons.
        .frame(height: EditorChromeMetrics.titlebarControlSize)
        .padding(.top, windowControls.controlTopInset)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .background(EditorSurface.main)
    }

    private var leadingInset: CGFloat {
        reservesWindowControls
            ? windowControls.documentTitleInset
            : EditorChromeMetrics.documentTitleEdgeInset
    }

    /// Mirrors `leadingInset`: clear the outline toggle while it floats over this
    /// column, otherwise sit on the body text's own right margin.
    private var trailingInset: CGFloat {
        reservesOutlineToggle
            ? EditorChromeMetrics.documentTitleTrailingInset
            : EditorChromeMetrics.documentTitleEdgeInset
    }
}
