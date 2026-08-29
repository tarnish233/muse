import MuseKit
import SwiftUI

struct CodexDocumentTitlebar: View {
    let document: MuseDocument
    let windowControls: WindowControlsGeometry
    let reservesWindowControls: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Text(document.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)
        }
        // Sits on the traffic-light centerline like the toggles do, instead of
        // centering in the band. Centering here would leave the title 7pt below
        // the outline toggle at the other end of the same row.
        .frame(height: EditorChromeMetrics.titlebarControlSize)
        .padding(.top, windowControls.controlTopInset)
        .padding(.leading, leadingInset)
        .padding(.trailing, EditorChromeMetrics.documentTitleTrailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .background(EditorSurface.main)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorSurface.divider)
                .frame(height: 1)
        }
    }

    private var leadingInset: CGFloat {
        reservesWindowControls
            ? windowControls.documentTitleInset
            : EditorChromeMetrics.documentTitleEdgeInset
    }
}
