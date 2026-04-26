import Bonsplit
import SwiftUI

/// Lightweight model for the four hardcoded sample projects shown in the
/// sidebar before #2 wires real Workspace data.
struct GhostDashboardSampleProject: Identifiable, Hashable {
    let id: String
    let name: String
    let cwd: String
    let status: String

    static let samples: [GhostDashboardSampleProject] = [
        .init(id: "sample.cmux", name: "cmux", cwd: "~/cmux", status: "running"),
        .init(id: "sample.ghostty", name: "ghostty", cwd: "~/cmux/ghostty", status: "OK"),
        .init(id: "sample.bonsplit", name: "bonsplit", cwd: "~/cmux/vendor/bonsplit", status: "idle"),
        .init(id: "sample.web", name: "web", cwd: "~/cmux/web", status: "warning"),
    ]
}

// MARK: - Sidebar

struct GhostDashboardSidebar: View {
    private let projects = GhostDashboardSampleProject.samples
    @State private var selection: GhostDashboardSampleProject.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "dashboard.sidebar.projects", defaultValue: "Projects"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            List(projects, selection: $selection) { project in
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(for: project.status))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.body)
                        Text(project.cwd)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .tag(project.id)
            }
            .listStyle(.sidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "OK": return .green
        case "running": return .blue
        case "warning": return .orange
        case "idle": return .gray
        default: return .secondary
        }
    }
}

// MARK: - Right detail panel

struct GhostDashboardRightPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "dashboard.title", defaultValue: "Ghost Projects"))
                .font(.headline)

            GroupBox(label: Text(String(localized: "dashboard.detail.selectedProject", defaultValue: "Selected Project"))) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "—")
                        .foregroundColor(.secondary)
                    Text(String(localized: "dashboard.detail.bindPlaceholder", defaultValue: "Bind in #2"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox(label: Text(String(localized: "dashboard.detail.quickActions", defaultValue: "Quick Actions"))) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "dashboard.detail.wiredIn5", defaultValue: "Wired in #5"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Right terminal dock placeholder

struct GhostTerminalDockPlaceholder: View {
    var body: some View {
        VStack {
            Spacer()
            Text(String(localized: "dashboard.terminalDock.title", defaultValue: "Terminal Dock"))
                .font(.headline)
                .foregroundColor(.secondary)
            Text(String(localized: "dashboard.terminalDock.wiredIn5", defaultValue: "Wired in #5"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.04))
    }
}

// MARK: - Bottom action bar

struct GhostDashboardActionBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Button(action: { logAction("openProject") }) {
                Text(String(localized: "dashboard.action.openProject", defaultValue: "Open Project"))
            }

            Button(action: { logAction("interrupt") }) {
                Text(String(localized: "dashboard.action.interrupt", defaultValue: "Interrupt"))
            }

            Button(action: { logAction("newTask") }) {
                Text(String(localized: "dashboard.action.newTask", defaultValue: "New Task"))
            }

            Button(action: { logAction("follow") }) {
                Text(String(localized: "dashboard.action.follow", defaultValue: "Follow"))
            }

            Spacer()

            v2Button(
                title: String(localized: "dashboard.action.broadcast", defaultValue: "Broadcast"),
                tooltip: String(
                    localized: "dashboard.action.broadcast.v2Tooltip",
                    defaultValue: "Available in v2"
                )
            )

            v2Button(
                title: String(localized: "dashboard.action.groupChat", defaultValue: "Group Chat"),
                tooltip: String(
                    localized: "dashboard.action.groupChat.v2Tooltip",
                    defaultValue: "Available in v2"
                )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Divider()
                .frame(maxWidth: .infinity)
                .frame(height: 1),
            alignment: .top
        )
    }

    private func v2Button(title: String, tooltip: String) -> some View {
        Button(action: {}) {
            HStack(spacing: 4) {
                Text(title)
                Text("v2")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .disabled(true)
        .help(tooltip)
    }

    private func logAction(_ name: String) {
        #if DEBUG
        dlog("ghost.dashboard action.\(name) (no-op until #5/#6)")
        #endif
    }
}
