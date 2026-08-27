import MuseKit
import SwiftUI

struct DocumentOutlineRow: View {
    let heading: RenderCoordinator.OutlineHeading

    var body: some View {
        Text(heading.title)
            .font(.system(size: 12, weight: heading.level == 1 ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, Double(max(0, heading.level - 1)) * 12)
            .padding(.horizontal, 7)
            .frame(height: 29)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}
