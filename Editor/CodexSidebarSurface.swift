import SwiftUI

enum EditorSurface {
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let main = Color(nsColor: .textBackgroundColor)
}

struct CodexSidebarSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EditorSurface.sidebar)
    }
}
