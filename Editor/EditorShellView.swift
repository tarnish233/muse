import AppKit
import MuseKit
import SwiftUI

/// The SwiftUI shell owns navigation and status UI. The document text remains
/// exclusively owned by MuseDocument -> EditorBuffer -> NSTextStorage.
struct EditorShellView: View {
    let document: MuseDocument
    @ObservedObject var renderer: RenderCoordinator
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedHeadingID: Int?

    init(document: MuseDocument) {
        self.document = document
        self.renderer = document.renderer
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FileSidebar(document: document)
                .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 300)
        } detail: {
            HSplitView {
                EditorDetail(document: document, renderer: renderer)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                OutlineSidebar(
                    renderer: renderer,
                    selectedHeadingID: $selectedHeadingID
                )
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    NSDocumentController.shared.newDocument(nil)
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("新建文稿")

                Button {
                    NSApp.keyWindow?.firstResponder?
                        .tryToPerform(
                            #selector(NSSplitViewController.toggleSidebar(_:)),
                            with: nil
                        )
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("显示或隐藏侧栏")
            }
        }
        .onChange(of: selectedHeadingID) { _, newValue in
            guard let newValue,
                  let heading = renderer.outline.first(where: { $0.id == newValue })
            else { return }
            renderer.reveal(heading: heading)
        }
    }
}

// MARK: - Files and projects

private struct FileSidebar: View {
    let document: MuseDocument

    var body: some View {
        List {
            Section("项目") {
                Label("Muse", systemImage: "folder")
                    .fontWeight(.medium)
            }

            Section("文件") {
                Button(action: focusCurrentDocument) {
                    Label {
                        Text(document.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("Muse")
    }

    private func focusCurrentDocument() {
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Editor

private struct EditorDetail: View {
    let document: MuseDocument
    @ObservedObject var renderer: RenderCoordinator

    var body: some View {
        EditorView(document: document)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                RenderStatus(renderer: renderer)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
    }
}

private struct RenderStatus: View {
    @ObservedObject var renderer: RenderCoordinator

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption2)
            Text(renderer.statusText)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Outline

private struct OutlineSidebar: View {
    @ObservedObject var renderer: RenderCoordinator
    @Binding var selectedHeadingID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("大纲")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("\(renderer.outline.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().opacity(0.35)

            List(selection: $selectedHeadingID) {
                if renderer.outline.isEmpty {
                    Text("尚无标题")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(renderer.outline) { heading in
                        OutlineRow(heading: heading)
                            .tag(heading.id as Int?)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyleSoftIfAvailable()
        }
        .background(.bar)
    }
}

private struct OutlineRow: View {
    let heading: RenderCoordinator.OutlineHeading

    var body: some View {
        HStack(spacing: 8) {
            Text("H\(heading.level)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .leading)
            Text(heading.title)
                .font(.system(size: 13, weight: heading.level == 1 ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - macOS 26 helpers

private extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
