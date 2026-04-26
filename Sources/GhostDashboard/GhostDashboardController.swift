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

    /// Titles of the first four cmux workspaces, surfaced as room labels in
    /// the embedded Ghost grid. Updated reactively via `bind(tabManager:)`.
    @Published private(set) var workspaceLabels: [String] = []

    /// Process-wide roster shared with `GhostBridgeHost` via
    /// `GhostRosterManager.shared` (see `GhostDashboardWebViewHost.attachRosterBridge`).
    /// The controller wires cmux workspace observers into this same instance
    /// so ghost lifecycle events reach the dashboard WebView.
    let rosterManager = GhostRosterManager.shared

    var rosterPublisher: AnyPublisher<[String: ProjectGhostRoster], Never> {
        rosterManager.$roster.eraseToAnyPublisher()
    }

    private weak var boundTabManager: TabManager?
    private var tabsCancellable: AnyCancellable?
    private var titleCancellables: Set<AnyCancellable> = []
    /// Per-workspace cancellables for `panels` watchers. Keyed by
    /// workspace UUID so we can swap them in/out as tabs come and go.
    private var workspacePanelsCancellables: [UUID: AnyCancellable] = [:]
    /// Last seen set of terminal-panel IDs per workspace. Diffing against
    /// the new set on each tick gives us "panel opened" / "panel closed"
    /// events to drive ghost lifecycle.
    private var lastTerminalPanels: [UUID: Set<UUID>] = [:]
    /// All workspaces we've ever registered with the roster manager —
    /// kept here so we can `unregisterWorkspace` ones that disappear.
    private var registeredWorkspaceIDs: Set<UUID> = []
    /// Notification-store observation. When Claude Code (or any agent) fires
    /// a notification, the matching ghost flips to needs-attention so the
    /// renderer paints it red and shows the "?" badge. Cleared when the user
    /// reads it.
    private var notificationStoreCancellable: AnyCancellable?
    /// Per-(workspace, panel) attention state we last pushed into the roster.
    /// Diffed against the live notification state so we only call
    /// `noteAgentNeedsAttention` when the value actually flips.
    private var lastAttentionByPanel: [UUID: [UUID: Bool]] = [:]

    private init() {}

    // MARK: - Workspace labels

    /// Subscribe to the tab manager's workspaces and republish the first four
    /// titles. Last bind wins — multi-window setups feed the most recently
    /// shown embedded grid. Also wires per-workspace terminal-panel observers
    /// so the ghost roster reflects open terminals in real time: one terminal
    /// panel = one assigned ghost.
    func bind(tabManager: TabManager) {
        guard boundTabManager !== tabManager else { return }
        boundTabManager = tabManager
        tabsCancellable = tabManager.$tabs
            .sink { [weak self] tabs in
                self?.subscribeToTitles(of: Array(tabs.prefix(4)))
                self?.syncWorkspaceRegistrations(tabs: tabs)
            }
        // Mirror unread-notification state per (workspace, panel) into the
        // roster so the JS overlay can paint the ghost red when Claude Code
        // is done or asking. The notification hook fires for both, so
        // `needsAttention` is the right single signal.
        if notificationStoreCancellable == nil {
            notificationStoreCancellable = TerminalNotificationStore.shared
                .objectWillChange
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.refreshAttentionStates()
                    }
                }
        }
    }

    /// Walk every registered workspace × terminal panel and push any
    /// notification-state diffs into the roster. Called whenever the
    /// `TerminalNotificationStore` mutates, and once after each panel-set
    /// change so newly opened panels start with the correct state.
    private func refreshAttentionStates() {
        guard let tabManager = boundTabManager else { return }
        let store = TerminalNotificationStore.shared
        for workspace in tabManager.tabs {
            let workspaceID = workspace.id
            var liveAttention: [UUID: Bool] = [:]
            for (panelID, panel) in workspace.panels {
                guard panel is TerminalPanel else { continue }
                let needs = store.hasVisibleNotificationIndicator(
                    forTabId: workspaceID,
                    surfaceId: panelID
                )
                liveAttention[panelID] = needs
                let prior = lastAttentionByPanel[workspaceID]?[panelID] ?? false
                if prior != needs {
                    rosterManager.noteAgentNeedsAttention(
                        workspaceID: workspaceID.uuidString,
                        agentKey: panelID.uuidString,
                        needs: needs
                    )
                }
            }
            lastAttentionByPanel[workspaceID] = liveAttention
        }
    }

    /// Register every cmux workspace as a ghost-roster project (idempotent)
    /// and unregister ones that have gone away. For each registered workspace,
    /// observe its `panels` map so terminal panels translate to ghost
    /// session-start / session-end events.
    private func syncWorkspaceRegistrations(tabs: [Workspace]) {
        let liveIDs = Set(tabs.map { $0.id })

        // Drop subscriptions for workspaces that disappeared.
        for id in registeredWorkspaceIDs.subtracting(liveIDs) {
            workspacePanelsCancellables.removeValue(forKey: id)
            lastTerminalPanels.removeValue(forKey: id)
            rosterManager.unregisterWorkspace(workspaceID: id.uuidString)
        }
        registeredWorkspaceIDs.formIntersection(liveIDs)

        // Register and observe new workspaces.
        for workspace in tabs {
            if registeredWorkspaceIDs.contains(workspace.id) { continue }
            registeredWorkspaceIDs.insert(workspace.id)

            let workspaceID = workspace.id.uuidString
            rosterManager.registerWorkspace(
                workspaceID: workspaceID,
                displayName: workspace.title,
                cwd: workspace.currentDirectory
            )

            // Eagerly seed the panel state — `registerWorkspace` and the
            // first `noteAgentLaunched` calls share the same serial state
            // queue, so register lands first and the launch finds its
            // project context. Subsequent panel changes flow through the
            // `$panels` sink with `.dropFirst()` since we already covered
            // the current value here.
            #if DEBUG
            dlog("ghost.bind workspace=\(workspace.id.uuidString.prefix(8)) initial-panels=\(workspace.panels.count)")
            #endif
            handlePanelsChange(
                workspaceID: workspace.id,
                panels: workspace.panels
            )

            let cancellable = workspace.$panels
                .dropFirst()
                .sink { [weak self, weak workspace] panels in
                    guard let self, let workspace else { return }
                    // Already on main — `panels` is a Workspace property
                    // that mutates from main. No `.receive(on:)` needed.
                    self.handlePanelsChange(
                        workspaceID: workspace.id,
                        panels: panels
                    )
                }
            workspacePanelsCancellables[workspace.id] = cancellable
        }

        // Keep roster metadata provider in sync so the WebView's room labels
        // reflect real workspace titles.
        refreshRosterMetadataProvider(tabs: tabs)
        // Push current notification-attention state for any panels that
        // already had notifications when their workspace registered.
        refreshAttentionStates()
    }

    /// Diff the workspace's current set of terminal panels against the last
    /// snapshot and translate the difference into ghost lifecycle calls.
    /// Each terminal panel's UUID is used as the agentKey, giving every
    /// panel its own stable ghost.
    private func handlePanelsChange(workspaceID: UUID, panels: [UUID: any Panel]) {
        let liveTerminalPanels: Set<UUID> = Set(
            panels.compactMap { (id, panel) in
                panel is TerminalPanel ? id : nil
            }
        )
        let prior = lastTerminalPanels[workspaceID] ?? []
        lastTerminalPanels[workspaceID] = liveTerminalPanels

        let added = liveTerminalPanels.subtracting(prior)
        let removed = prior.subtracting(liveTerminalPanels)
        #if DEBUG
        dlog("ghost.panels workspace=\(workspaceID.uuidString.prefix(8)) total=\(panels.count) terminals=\(liveTerminalPanels.count) added=\(added.count) removed=\(removed.count)")
        #endif

        let id = workspaceID.uuidString
        // New terminals → walk to a desk.
        for panelID in added {
            rosterManager.noteAgentLaunched(
                workspaceID: id,
                agentKey: panelID.uuidString,
                label: "terminal"
            )
        }
        // Closed terminals → free the desk.
        for panelID in removed {
            rosterManager.noteAgentEnded(
                workspaceID: id,
                agentKey: panelID.uuidString
            )
        }
    }

    /// Refresh the shared roster's metadata provider so the WebView bridge
    /// can ask any workspace for its current title/cwd/status.
    private func refreshRosterMetadataProvider(tabs: [Workspace]) {
        // Snapshot a value-type lookup; the closure must be Sendable so
        // capturing the live workspace objects (class refs, MainActor) is
        // not allowed.
        let lookup: [String: (name: String, cwd: String, status: String)] =
            Dictionary(uniqueKeysWithValues: tabs.map { ws in
                (
                    ws.id.uuidString,
                    (
                        name: ws.title,
                        cwd: ws.currentDirectory,
                        status: ws.statusEntries["claude_code"]?.value ?? ""
                    )
                )
            })
        rosterManager.metadataProvider = { pid in
            lookup[pid] ?? (pid, "", "")
        }
    }

    private func subscribeToTitles(of tabs: [Workspace]) {
        titleCancellables.removeAll()
        recomputeLabels(from: tabs)
        for tab in tabs {
            tab.$title
                .dropFirst()
                .sink { [weak self] _ in
                    self?.recomputeLabels(from: tabs)
                }
                .store(in: &titleCancellables)
        }
    }

    private func recomputeLabels(from tabs: [Workspace]) {
        let titles = tabs.map { $0.title }
        guard workspaceLabels != titles else { return }
        workspaceLabels = titles
    }

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
        // Click on a single ghost in the room view. For now we focus the
        // workspace as a whole — per-session focus inside the workspace
        // (mapping `data.ghostID` → terminal panel) is a follow-up that
        // needs a Claude-Code-session ↔ panel index.
        bridgeHost.onFocusGhost = { payload in
            #if DEBUG
            let ghostID = (payload.data?.value as? [String: AnyHashable])?["ghostID"] as? String
            dlog("ghost.action.focusGhost project=\(payload.projectID ?? "?") ghost=\(ghostID ?? "?")")
            #endif
            Self.dispatch(payload) { id in
                GhostDashboardController.shared.selectProject(workspaceID: id)
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
