import AppKit
import Combine
import Foundation
#if DEBUG
import Bonsplit
#endif

extension Notification.Name {
    static let ghostDashboardProjectDidSelect = Notification.Name(
        "cmux.ghostDashboard.projectDidSelect"
    )
    static let ghostDashboardDockNeedsRefresh = Notification.Name(
        "cmux.ghostDashboard.dockNeedsRefresh"
    )
}

/// Coordinates Ghost Projects dashboard v1 actions. Owned as a singleton so
/// the SwiftUI action bar, the Swift↔JS bridge (`GhostBridgeHost` from #3),
/// and the dock observer share one source of truth for the selected project
/// and follow state.
@MainActor
final class GhostDashboardController: ObservableObject {
    static let shared = GhostDashboardController()

    @Published private(set) var selectedProjectID: UUID?

    /// Roster manager owned by the dashboard. Stays empty (no registrations)
    /// until callers wire it up; the action bar only needs its publisher to
    /// satisfy the Follow contract.
    let rosterManager = GhostRosterManager()

    var rosterPublisher: AnyPublisher<[String: ProjectGhostRoster], Never> {
        rosterManager.$roster.eraseToAnyPublisher()
    }

    private init() {}

    // MARK: - v1 actions

    func selectProject(workspaceID: UUID) {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            #if DEBUG
            dlog("ghost.action.openProject.miss workspaceID=\(workspaceID.uuidString.prefix(5))")
            #endif
            return
        }
        manager.selectWorkspace(workspace)
        selectedProjectID = workspaceID
        // Revive a Follow subscription that was persisted ON across launches.
        TerminalDockMirror.shared.ensureMirroring(workspaceID: workspaceID)
        NotificationCenter.default.post(
            name: .ghostDashboardProjectDidSelect,
            object: workspaceID
        )
    }

    func interrupt(workspaceID: UUID) {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.focusedTerminalPanel else {
            #if DEBUG
            dlog("ghost.action.interrupt.miss workspaceID=\(workspaceID.uuidString.prefix(5))")
            #endif
            return
        }
        _ = panel.surface.sendNamedKey("ctrl-c")
    }

    func newTask(workspaceID: UUID, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        TerminalController.shared.sendTextToWorkspace(id: workspaceID, text: trimmed + "\n")
    }

    func isFollowing(workspaceID: UUID) -> Bool {
        TerminalDockMirror.shared.isFollowing(workspaceID: workspaceID)
    }

    func toggleFollow(workspaceID: UUID) {
        TerminalDockMirror.shared.toggle(workspaceID: workspaceID)
    }

    // MARK: - Bridge wiring

    /// Wire a freshly created `GhostBridgeHost` to controller actions. The
    /// bridge handler closures hop to main before mutating dashboard state.
    func wire(bridgeHost: GhostBridgeHost) {
        bridgeHost.onRoomSelect = { payload in
            Self.dispatch(payload) { id in
                GhostDashboardController.shared.selectProject(workspaceID: id)
            }
        }
        bridgeHost.onOpenProject = { payload in
            Self.dispatch(payload) { id in
                GhostDashboardController.shared.selectProject(workspaceID: id)
            }
        }
        bridgeHost.onInterrupt = { payload in
            Self.dispatch(payload) { id in
                GhostDashboardController.shared.interrupt(workspaceID: id)
            }
        }
        bridgeHost.onNewTask = { payload in
            let prompt = Self.prompt(from: payload) ?? ""
            Self.dispatch(payload) { id in
                GhostDashboardController.shared.newTask(
                    workspaceID: id,
                    prompt: prompt
                )
            }
        }
        bridgeHost.onFollow = { payload in
            Self.dispatch(payload) { id in
                GhostDashboardController.shared.toggleFollow(workspaceID: id)
            }
        }
    }

    nonisolated private static func dispatch(
        _ payload: GhostActionPayload,
        _ apply: @MainActor @escaping (UUID) -> Void
    ) {
        guard let id = workspaceID(from: payload) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                apply(id)
            }
        }
    }

    nonisolated private static func workspaceID(from payload: GhostActionPayload) -> UUID? {
        if let pid = payload.projectID, let id = UUID(uuidString: pid) { return id }
        if let dict = payload.data?.value as? [String: AnyHashable],
           let raw = dict["workspaceID"] as? String,
           let id = UUID(uuidString: raw) {
            return id
        }
        return nil
    }

    nonisolated private static func prompt(from payload: GhostActionPayload) -> String? {
        guard let dict = payload.data?.value as? [String: AnyHashable] else { return nil }
        return dict["prompt"] as? String
    }
}
