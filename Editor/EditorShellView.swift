import SwiftUI

/// SwiftUI 外壳（v0.2）：窗口内容 + 状态栏。编辑面在 AppKit 侧，此处只做编排与状态展示。
struct EditorShellView: View {
    let document: MuseDocument
    @ObservedObject var renderer: RenderCoordinator

    init(document: MuseDocument) {
        self.document = document
        self.renderer = document.renderer
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorView(document: document)
            Divider()
            HStack(spacing: 8) {
                Text(renderer.statusText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}
