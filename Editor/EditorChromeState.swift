import Observation

@MainActor
@Observable
final class EditorChromeState {
    var isProjectSidebarPresented = true
    var isOutlinePresented = true
    var isSourceMode = false

    /// Measured from the window by `EditorWindowController`. The chrome band
    /// lines its controls and document title up with the traffic lights rather
    /// than centering them in its own height.
    var windowControls = WindowControlsGeometry.unavailable
}
