import Foundation

extension TerminalController {
    /// Public accessor used by the Ghost Projects dashboard's New Task action
    /// to inject a prompt into a workspace's selected terminal surface. The
    /// underlying socket-command path (`sendInputToWorkspace`) is `private`,
    /// so this thin wrapper invokes the same `TerminalSurface.sendInput`
    /// route directly without touching the typing-latency hot path.
    @MainActor
    func sendTextToWorkspace(id workspaceID: UUID, text: String) {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.focusedTerminalPanel else {
            return
        }
        panel.sendInput(text)
        panel.surface.requestBackgroundSurfaceStartIfNeeded()
    }
}
