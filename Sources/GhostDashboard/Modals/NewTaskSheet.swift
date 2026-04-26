import SwiftUI

/// Modal for the v1 "New Task" Quick Action. Captures a prompt and injects it
/// (with a trailing newline) into the selected workspace's active terminal
/// surface via `GhostDashboardController.shared.newTask`.
struct NewTaskSheet: View {
    @Binding var isPresented: Bool
    let workspaceID: UUID
    @State private var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: "dashboard.newTask.title",
                defaultValue: "New Task"
            ))
            .font(.headline)

            TextField(
                String(
                    localized: "dashboard.newTask.placeholder",
                    defaultValue: "Describe the task…"
                ),
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(4...)
            .textFieldStyle(.roundedBorder)

            HStack {
                Button(String(
                    localized: "dashboard.newTask.cancel",
                    defaultValue: "Cancel"
                )) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(
                    localized: "dashboard.newTask.submit",
                    defaultValue: "Submit"
                )) {
                    submit()
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func submit() {
        GhostDashboardController.shared.newTask(
            workspaceID: workspaceID,
            prompt: prompt
        )
        isPresented = false
    }
}
