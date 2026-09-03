import SwiftUI

struct WorkspaceNameSheet: View {
    let title: String
    let prompt: String
    let submitTitle: String
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(
        title: String,
        prompt: String,
        initialName: String,
        submitTitle: String,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.prompt = prompt
        self.submitTitle = submitTitle
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            TextField(prompt, text: $name)
                .focused($isNameFocused)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(submitTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task {
            isNameFocused = true
        }
    }

    private func submit() {
        onSubmit(name)
    }
}
