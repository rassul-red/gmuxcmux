import Combine
import Foundation
#if DEBUG
import Bonsplit
#endif

/// Tracks per-workspace Follow state and re-emits dock refresh notifications
/// while a workspace is followed. Reuses the #2 transcript publisher
/// (`GhostRosterManager.$roster`) instead of introducing a dedicated
/// NSNotification — the dashboard already has
/// `.ghostDashboardDockNeedsRefresh` for that purpose.
@MainActor
final class TerminalDockMirror {
    static let shared = TerminalDockMirror()

    private var cancellables: [UUID: AnyCancellable] = [:]
    private static let userDefaultsPrefix = "workspace-follow-"

    private static func userDefaultsKey(for workspaceID: UUID) -> String {
        "\(userDefaultsPrefix)\(workspaceID.uuidString)"
    }

    private init() {}

    func isFollowing(workspaceID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: Self.userDefaultsKey(for: workspaceID))
    }

    func toggle(workspaceID: UUID) {
        let nowOn = !isFollowing(workspaceID: workspaceID)
        UserDefaults.standard.set(
            nowOn,
            forKey: Self.userDefaultsKey(for: workspaceID)
        )
        if nowOn {
            startMirroring(workspaceID: workspaceID)
        } else {
            cancellables[workspaceID]?.cancel()
            cancellables.removeValue(forKey: workspaceID)
        }
        NotificationCenter.default.post(
            name: .ghostDashboardDockNeedsRefresh,
            object: workspaceID
        )
        #if DEBUG
        dlog("ghost.action.follow workspace=\(workspaceID.uuidString.prefix(5)) on=\(nowOn)")
        #endif
    }

    private func startMirroring(workspaceID: UUID) {
        cancellables[workspaceID] = GhostDashboardController.shared.rosterPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                NotificationCenter.default.post(
                    name: .ghostDashboardDockNeedsRefresh,
                    object: workspaceID
                )
            }
    }
}
