import MuseKit
import SwiftUI

struct CodexDocumentTitlebar: View {
    let document: MuseDocument
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
        .padding(.leading, reservesWindowControls ? 142 : 18)
        .padding(.trailing, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .background(EditorSurface.main)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorSurface.divider)
                .frame(height: 1)
        }
    }
}
