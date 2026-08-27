import MuseKit
import SwiftUI

struct DocumentOutlineView: View {
    @ObservedObject var renderer: RenderCoordinator
    @Binding var selectedHeadingID: Int?

    var body: some View {
        CodexSidebarSurface {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if renderer.outline.isEmpty {
                        Label("尚无标题", systemImage: "list.bullet.indent")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        ForEach(renderer.outline) { heading in
                            Button {
                                selectedHeadingID = heading.id
                            } label: {
                                DocumentOutlineRow(heading: heading)
                            }
                            .buttonStyle(.plain)
                            .background(
                                selectedHeadingID == heading.id ? Color.primary.opacity(0.08) : .clear,
                                in: .rect(cornerRadius: 9)
                            )
                        }
                    }
                }
                .padding(10)
            }
            .museSoftScrollEdges()
        }
    }
}
