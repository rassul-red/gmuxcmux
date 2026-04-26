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
        if panel.surface.surface != nil {
            panel.sendInput(text)
        } else {
            // Surface not yet realized — queue text via the pending-input
            // path so a New Task prompt against a background workspace lands
            // once the surface starts (mirroring sendInputToWorkspace).
            let raw = text.replacingOccurrences(of: "\n", with: "\r")
            panel.sendText(raw)
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }
}
