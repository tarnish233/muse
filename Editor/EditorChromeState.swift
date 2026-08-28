import Observation

@MainActor
@Observable
final class EditorChromeState {
    var isProjectSidebarPresented = true
    var isOutlinePresented = true
    var isSourceMode = false
}
