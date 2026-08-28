import MuseKit
import SwiftUI

/// Window-level navigation shell. Source text remains owned exclusively by
/// MuseDocument -> EditorBuffer -> NSTextStorage.
struct EditorShellView: View {
    let document: MuseDocument
    @Bindable var chromeState: EditorChromeState
    let navigation: EditorDocumentNavigation
    @ObservedObject private var renderer: RenderCoordinator
    @State private var workspace = ProjectWorkspace.shared
    @State private var projectSidebarWidth = EditorChromeMetrics.projectSidebarDefaultWidth
    @State private var outlineSidebarWidth = EditorChromeMetrics.outlineSidebarDefaultWidth
    @State private var selectedHeadingID: Int?
    @State private var selectedFileURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        document: MuseDocument,
        chromeState: EditorChromeState,
        navigation: EditorDocumentNavigation
    ) {
        self.document = document
        self.chromeState = chromeState
        self.navigation = navigation
        renderer = document.renderer
        _selectedFileURL = State(initialValue: document.fileURL?.standardizedFileURL)
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                projectSidebar

                SidebarResizeHandle(
                    side: .leading,
                    isPresented: chromeState.isProjectSidebarPresented,
                    width: $projectSidebarWidth,
                    range: EditorChromeMetrics.projectSidebarRange
                )

                editorColumn

                SidebarResizeHandle(
                    side: .trailing,
                    isPresented: chromeState.isOutlinePresented,
                    width: $outlineSidebarWidth,
                    range: EditorChromeMetrics.outlineSidebarRange
                )

                outlineSidebar
            }

            titlebarControls
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(sidebarAnimation, value: chromeState.isProjectSidebarPresented)
        .animation(sidebarAnimation, value: chromeState.isOutlinePresented)
        .onChange(of: selectedHeadingID, revealSelectedHeading)
        .onChange(of: document.fileURL) { _, newURL in
            selectedFileURL = newURL?.standardizedFileURL
            workspace.refreshAll()
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: EditorChromeMetrics.titlebarHeight)

            WorkspaceSidebar(
                workspace: workspace,
                selectedFileURL: $selectedFileURL,
                openFile: navigation.open
            )
        }
        .background(EditorSurface.sidebar)
        .frame(width: chromeState.isProjectSidebarPresented ? projectSidebarWidth : 0)
        .opacity(chromeState.isProjectSidebarPresented ? 1 : 0)
        .clipped()
        .allowsHitTesting(chromeState.isProjectSidebarPresented)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            CodexDocumentTitlebar(
                document: document,
                reservesWindowControls: !chromeState.isProjectSidebarPresented
            )
            .frame(height: EditorChromeMetrics.titlebarHeight)

            EditorDetailView(
                document: document,
                isSourceMode: chromeState.isSourceMode,
                renderer: renderer
            )
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(EditorSurface.main)
    }

    private var outlineSidebar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: EditorChromeMetrics.titlebarHeight)

            DocumentOutlineView(
                renderer: renderer,
                selectedHeadingID: $selectedHeadingID
            )
        }
        .background(EditorSurface.sidebar)
        .frame(width: chromeState.isOutlinePresented ? outlineSidebarWidth : 0)
        .opacity(chromeState.isOutlinePresented ? 1 : 0)
        .clipped()
        .allowsHitTesting(chromeState.isOutlinePresented)
    }

    private var titlebarControls: some View {
        HStack(spacing: 0) {
            CodexTitlebarButton(
                systemImage: "sidebar.left",
                accessibilityLabel: "切换项目栏",
                showsActiveBackground: false,
                isActive: chromeState.isProjectSidebarPresented
            ) {
                chromeState.isProjectSidebarPresented.toggle()
            }
            .padding(.leading, EditorChromeMetrics.leadingControlInset)

            Spacer(minLength: 0)

            CodexTitlebarButton(
                systemImage: "sidebar.right",
                accessibilityLabel: "切换大纲栏",
                showsActiveBackground: true,
                isActive: chromeState.isOutlinePresented
            ) {
                chromeState.isOutlinePresented.toggle()
            }
            .padding(.trailing, EditorChromeMetrics.trailingControlInset)
        }
        .frame(height: EditorChromeMetrics.titlebarHeight)
        .frame(maxWidth: .infinity)
    }

    private var sidebarAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.28, dampingFraction: 1)
    }

    private func revealSelectedHeading() {
        guard let selectedHeadingID,
              let heading = renderer.outline.first(where: { $0.id == selectedHeadingID })
        else { return }
        renderer.reveal(heading: heading)
    }
}
