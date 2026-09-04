import MuseKit
import SwiftUI

/// Window-level navigation shell. Source text remains owned exclusively by
/// MuseDocument -> EditorBuffer -> NSTextStorage.
struct EditorShellView: View {
    let document: MuseDocument
    @Bindable var chromeState: EditorChromeState
    @Bindable private var location: DocumentLocationState
    @Bindable private var workspace: ProjectWorkspace
    let navigation: EditorDocumentNavigation
    @ObservedObject private var renderer: RenderCoordinator
    @State private var projectSidebarWidth = EditorChromeMetrics.projectSidebarDefaultWidth
    @State private var outlineSidebarWidth = EditorChromeMetrics.outlineSidebarDefaultWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        document: MuseDocument,
        chromeState: EditorChromeState,
        workspace: ProjectWorkspace,
        navigation: EditorDocumentNavigation
    ) {
        self.document = document
        self.chromeState = chromeState
        self.location = document.location
        self.workspace = workspace
        self.navigation = navigation
        renderer = document.renderer
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
        .onChange(of: location.fileURL) { oldURL, newURL in
            if let oldURL {
                workspace.refreshProject(containing: oldURL)
            }
            if let newURL, newURL != oldURL {
                workspace.refreshProject(containing: newURL)
            }
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: EditorChromeMetrics.titlebarHeight)

            WorkspaceSidebar(
                workspace: workspace,
                selectedFileURL: location.fileURL,
                isPresented: chromeState.isProjectSidebarPresented,
                openFile: navigation.open,
                restoreEditorFocus: restoreEditorFocus
            )
        }
        // Keep sidebar contents at their expanded geometry while the outer frame
        // collapses. This clips text at the moving edge instead of fading or
        // reflowing each label during the close animation.
        .frame(width: projectSidebarWidth)
        .background(EditorSurface.sidebar)
        .frame(
            width: chromeState.isProjectSidebarPresented ? projectSidebarWidth : 0,
            alignment: .leading
        )
        .clipped()
        .allowsHitTesting(chromeState.isProjectSidebarPresented)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            CodexDocumentTitlebar(
                title: location.displayName,
                windowControls: chromeState.windowControls,
                reservesWindowControls: !chromeState.isProjectSidebarPresented,
                reservesOutlineToggle: !chromeState.isOutlinePresented,
                renderer: renderer
            )
            .frame(height: EditorChromeMetrics.titlebarHeight)

            EditorDetailView(
                document: document,
                isSourceMode: chromeState.isSourceMode,
                previewBaseURL: location.directoryURL
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
                highlightedHeadingID: renderer.visibleHeadingID,
                selectHeading: renderer.reveal
            )
        }
        .background(EditorSurface.sidebar)
        .frame(width: chromeState.isOutlinePresented ? outlineSidebarWidth : 0)
        .opacity(chromeState.isOutlinePresented ? 1 : 0)
        .clipped()
        .allowsHitTesting(chromeState.isOutlinePresented)
    }

    /// Floats over both sidebars and the editor column, on the traffic lights'
    /// own centerline. Centering these in the band instead put them 7pt below the
    /// window buttons a few points to their left.
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
            .padding(.leading, chromeState.windowControls.leadingControlInset)

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
        .frame(height: EditorChromeMetrics.titlebarControlSize)
        .padding(.top, chromeState.windowControls.controlTopInset)
        .frame(maxWidth: .infinity)
    }

    private var sidebarAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.28, dampingFraction: 1)
    }

    private func restoreEditorFocus() {
        guard let textView = renderer.textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

}
