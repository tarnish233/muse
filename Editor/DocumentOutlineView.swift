import MuseKit
import SwiftUI

struct DocumentOutlineView: View {
    @ObservedObject var renderer: RenderCoordinator
    let highlightedHeadingID: Int?
    let selectHeading: (RenderCoordinator.OutlineHeading) -> Void

    var body: some View {
        CodexSidebarSurface {
            ScrollViewReader { proxy in
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
                                    selectHeading(heading)
                                } label: {
                                    DocumentOutlineRow(heading: heading)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    highlightedHeadingID == heading.id
                                        ? Color.primary.opacity(0.08) : .clear,
                                    in: .rect(cornerRadius: 9)
                                )
                                .id(heading.id)
                            }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: highlightedHeadingID, initial: true) { _, headingID in
                    guard let headingID else { return }
                    proxy.scrollTo(headingID, anchor: .center)
                }
                .museSoftScrollEdges()
            }
        }
    }
}
