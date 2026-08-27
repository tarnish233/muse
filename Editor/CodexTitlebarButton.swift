import SwiftUI

struct CodexTitlebarButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let showsActiveBackground: Bool
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: EditorChromeMetrics.titlebarControlSize,
                    height: EditorChromeMetrics.titlebarControlSize
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(background, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.08 : 0), lineWidth: 0.5)
        }
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: Color {
        if isHovered {
            return Color.primary.opacity(0.07)
        }
        if showsActiveBackground && isActive {
            return Color.primary.opacity(0.035)
        }
        return .clear
    }
}
