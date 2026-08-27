import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "自动"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
enum AppPreferences {
    static let appearanceKey = "appAppearance"
    static let openUntitledDocumentKey = "openUntitledDocumentAtLaunch"

    static func applyAppearance(_ value: String? = nil) {
        let rawValue = value ?? UserDefaults.standard.string(forKey: appearanceKey)
        let selection = AppAppearance(rawValue: rawValue ?? "") ?? .system
        NSApp.appearance = selection.appearance
    }
}
