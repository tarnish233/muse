import SwiftUI

struct WorkspaceProjectActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(
                isHovered ? Color.primary.opacity(0.07) : .clear,
                in: .rect(cornerRadius: 5)
            )
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .help(title)
    }
}
