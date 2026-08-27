import SwiftUI

struct WorkspaceNameSheet: View {
    let request: WorkspaceCreationRequest
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(
        request: WorkspaceCreationRequest,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _name = State(initialValue: request.kind.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.kind.title)
                .font(.headline)

            TextField(request.kind.prompt, text: $name)
                .focused($isNameFocused)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("创建", action: submit)
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
