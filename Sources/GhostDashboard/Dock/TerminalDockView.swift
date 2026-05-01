import Combine
import SwiftUI

/// SwiftUI dock view shown to the right of the 2x2 grid. Observes
/// `.ghostDashboardProjectDidSelect` to forward focus to the corresponding
/// cmux workspace via `TabManager.focusTab(_:surfaceId:)` (TabManager.swift:4660),
/// and listens to `.ghostDashboardDockNeedsRefresh` so Follow updates can
/// trigger a redraw without coupling to a workspace-specific publisher.
struct TerminalDockView: View {
    @StateObject private var model = TerminalDockViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(
                    localized: "dashboard.terminalDock.title",
                    defaultValue: "Terminal Dock"
                ))
                .font(.headline)
                Spacer()
                if model.isFollowing {
                    Text(String(
                        localized: "dashboard.terminalDock.followingBadge",
                        defaultValue: "Following"
                    ))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                }
            }

            if let workspaceID = model.attachedWorkspaceID {
                Text(verbatim: workspaceID.uuidString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(String(
                    localized: "dashboard.terminalDock.attached",
                    defaultValue: "Attached to selected workspace."
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
                Text(String(
                    localized: "dashboard.terminalDock.empty",
                    defaultValue: "Select a project to attach the terminal."
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.04))
    }
}

@MainActor
final class TerminalDockViewModel: ObservableObject {
    @Published private(set) var attachedWorkspaceID: UUID?
    @Published private(set) var refreshToken: UInt64 = 0
    @Published private(set) var isFollowing: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    init() {
        NotificationCenter.default.publisher(for: .ghostDashboardProjectDidSelect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleProjectDidSelect(note.object)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .ghostDashboardDockNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleDockNeedsRefresh(note.object)
            }
            .store(in: &cancellables)
    }

    private func handleProjectDidSelect(_ object: Any?) {
        guard let workspaceID = object as? UUID else { return }
        attachedWorkspaceID = workspaceID
        isFollowing = TerminalDockMirror.shared.isFollowing(workspaceID: workspaceID)

        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            return
        }
        manager.focusTab(workspaceID, surfaceId: workspace.focusedPanelId)
    }

    private func handleDockNeedsRefresh(_ object: Any?) {
        refreshToken &+= 1
        if let workspaceID = object as? UUID, workspaceID == attachedWorkspaceID {
            isFollowing = TerminalDockMirror.shared.isFollowing(workspaceID: workspaceID)
        }
    }
}
