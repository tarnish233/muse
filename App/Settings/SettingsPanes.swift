import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage(AppPreferences.openUntitledDocumentKey) private var openUntitledDocument = true

    var body: some View {
        Form {
            Section("启动") {
                Toggle(isOn: $openUntitledDocument) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动时新建文稿")
                        Text("没有恢复窗口或待打开文件时，显示一份新文稿。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("文稿") {
                LabeledContent("默认格式") {
                    Label("Markdown", systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("自动存储") {
                    Text("就地存储")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

struct AppearanceSettingsPane: View {
    @AppStorage(AppPreferences.appearanceKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section("界面") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, value in
                    AppPreferences.applyAppearance(value)
                }
            }

            Section("编辑器") {
                LabeledContent("排版") {
                    Text("系统字体 · 16 pt")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("代码") {
                    Text("等宽字体 · 15 pt")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Muse")
                            .font(.title.bold())
                        Text("专注于 Markdown 的原生 macOS 编辑器")
                            .foregroundStyle(.secondary)
                        Text(AppVersionText.value)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("技术") {
                LabeledContent("编辑引擎", value: "TextKit 2")
                LabeledContent("文稿格式", value: "Markdown")
                LabeledContent("最低系统", value: "macOS 14")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

private enum AppVersionText {
    static let value: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "版本 \(version) (\(build))"
    }()
}
