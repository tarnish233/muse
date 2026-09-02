import Foundation

/// UserDefaults keys shared by the settings UI and every open editor window.
enum EditorPreferences {
    static let revealCurrentBlockMarkdownKey = "revealCurrentBlockMarkdown"
    static let clipboardCopyModeKey = "clipboardCopyMode"
    static let copyWholeLineWhenSelectionIsEmptyKey = "copyWholeLineWhenSelectionIsEmpty"
    static let typewriterModeKey = "typewriterMode"
}
