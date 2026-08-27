import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "外观"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .general

    private init() {}
}

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var history: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isTraversingHistory = false

    private var activeTab: SettingsTab { navigation.selectedTab ?? .general }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .foregroundStyle(.primary)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectStyleSoftIfAvailable()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider().opacity(0.35)
                    HStack {
                        Text(AppVersion.displayString)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Muse")
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch activeTab {
                case .general: GeneralSettingsPane()
                case .appearance: AppearanceSettingsPane()
                case .about: AboutSettingsPane()
                }
            }
            .navigationTitle(activeTab.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("设置")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) { Image(systemName: "chevron.left") }
                    .help("返回")
                    .disabled(historyIndex == 0)
                Button(action: goForward) { Image(systemName: "chevron.right") }
                    .help("前进")
                    .disabled(historyIndex >= history.count - 1)
            }
        }
        .onChange(of: navigation.selectedTab) { _, selection in
            record(selection)
        }
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        isTraversingHistory = true
        historyIndex -= 1
        navigation.selectedTab = history[historyIndex]
        DispatchQueue.main.async { isTraversingHistory = false }
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        isTraversingHistory = true
        historyIndex += 1
        navigation.selectedTab = history[historyIndex]
        DispatchQueue.main.async { isTraversingHistory = false }
    }

    private func record(_ selection: SettingsTab?) {
        guard !isTraversingHistory, let selection else { return }
        guard history[historyIndex] != selection else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(selection)
        historyIndex = history.count - 1
    }
}

private enum AppVersion {
    static let displayString: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "版本 \(version) (\(build))"
    }()
}

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
