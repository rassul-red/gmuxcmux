import Combine
import Darwin
import Foundation
#if DEBUG
import Bonsplit
#endif

/// Visible motion phase for a ghost in the dashboard's room scene
/// (issue #17). Independent of `GhostState` (which describes *what* the
/// agent is doing). Motion describes *where* the ghost is on screen.
///
/// - `spawning`:  freshly observed session that has never had a tool_use yet
///                (i.e. the ghost just appeared in the room).
/// - `wandering`: idle drift around the room. Used for the per-workspace
///                "free" ghost that has not yet been assigned to a session.
/// - `walking`:   moving toward an assigned table after the agent launched
///                in its terminal tab.
/// - `settled`:   parked at its assigned table. Once seated, the ghost stays
///                bound to that desk for the lifetime of the session — even
///                when the session goes idle ("Idle at desk"). It only leaves
///                when the user deletes the terminal instance.
public enum GhostMotion: String, Codable, Equatable, Sendable {
    case spawning
    case wandering
    case walking
    case settled

    /// How long the `walking` animation lasts before the ghost is treated as
    /// `settled` at its desk. The JS overlay reuses this value (mirrored as
    /// `WALK_DURATION_SECONDS` in `ghost-room-overlay.js`) so Swift and JS
    /// agree on when the ghost arrives.
    public static let walkDuration: TimeInterval = 2.0
}

/// One ghost in a project roster.
public struct GhostEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public var state: GhostState
    public var label: String
    public var lastActivity: Date?
    /// Lifecycle phase for the renderer (Issue #14). Defaults to `.idle` so
    /// existing callers and tests stay source-compatible.
    public var lifecycle: GhostLifecycle
    /// Issue #17: deterministic seat in the room. `nil` until the agent
    /// launches in this terminal tab (first non-Idle `tool_use` after Idle).
    /// Once assigned, the seat stays bound to this ghost so subsequent
    /// idle/active flips return to the same chair instead of musical-chairs.
    public var tableID: Int?
    /// Issue #17: visible motion phase, derived per-snapshot from
    /// `state`, `tableID`, and `motionStartedAt`.
    public var motion: GhostMotion
    /// Wall-clock timestamp the current `motion` phase started.
    /// JS overlay uses this to drive the walk animation.
    public var motionStartedAt: Date?
    /// True when the underlying agent has an unread notification (Claude
    /// Code "Notification" hook fired, or any other surface notification on
    /// this workspace). Drives the "?" speech-bubble badge above the ghost.
    public var needsAttention: Bool
    /// Per-cmux-panel identity. For assigned ghosts this is the terminal
    /// panel UUID (the `agentKey`) so the JS overlay can round-trip a click
    /// back to a specific surface. `nil` for the synthetic free wandering
    /// ghost which has no terminal yet.
    public var panelID: String?

    public init(
        id: String,
        state: GhostState = .Idle,
        label: String = "",
        lastActivity: Date? = nil,
        lifecycle: GhostLifecycle = .idle,
        tableID: Int? = nil,
        motion: GhostMotion = .spawning,
        motionStartedAt: Date? = nil,
        needsAttention: Bool = false,
        panelID: String? = nil
    ) {
        self.id = id
        self.state = state
        self.label = label
        self.lastActivity = lastActivity
        self.lifecycle = lifecycle
        self.tableID = tableID
        self.motion = motion
        self.motionStartedAt = motionStartedAt
        self.needsAttention = needsAttention
        self.panelID = panelID
    }

    public var ghostID: String { id }
}

public struct ProjectGhostRoster: Equatable, Sendable {
    public let projectID: String
    public var ghosts: [GhostEntry]

    public init(projectID: String, ghosts: [GhostEntry] = []) {
        self.projectID = projectID
        self.ghosts = ghosts
    }
}

/// Owns one `ClaudeTranscriptWatcher` per registered project, runs the parser
/// off-main, and exposes a `@Published roster` that is mutated only on the
/// main thread.
///
/// Self-verifies via `dispatchPrecondition` that the parsing path never lands
/// on `.main`, per the seed `evaluation_principles.typing_latency_zero`.
public final class GhostRosterManager: ObservableObject {
    /// Max number of *assigned* (seated) ghosts per workspace. Matches the
    /// renderer's `DESK_SLOTS.length` so every assigned ghost has a desk.
    /// One additional "free" wandering ghost may be appended on top — it
    /// represents the next ghost waiting to be assigned to a new task.
    public static let maxAssignedPerProject = 4

    /// Synthetic ghost id suffix for the per-workspace "free" ghost.
    public static let freeGhostSuffix = "__free__"

    /// Backwards-compat alias: total renderable ghosts per project (assigned
    /// + the optional free ghost). Kept as a property name for any callers
    /// or tests that still reference the old constant.
    public static let maxGhostsPerProject = maxAssignedPerProject + 1

    /// Process-wide singleton consumed by `GhostDashboardWebViewHost` so the
    /// Swift→JS bridge has a stable roster to subscribe to. Tests construct
    /// dedicated instances via `init(...)`.
    public static let shared = GhostRosterManager()

    @Published public private(set) var roster: [String: ProjectGhostRoster] = [:]

    /// Optional, project-id-keyed metadata provider used by the bridge to
    /// build snapshot tile names / cwd / status fields. Walkthrough or
    /// workspace integration code can replace this; the default falls back to
    /// the project id as the display name with empty cwd/status.
    ///
    /// Reads and writes are serialized through `metadataProviderLock` so the
    /// bridge can read it from `coalesceQueue` while another thread updates it.
    private let metadataProviderLock = NSLock()
    private var _metadataProvider: (String) -> (name: String, cwd: String, status: String) = { pid in
        (pid, "", "")
    }
    public var metadataProvider: (String) -> (name: String, cwd: String, status: String) {
        get {
            metadataProviderLock.lock()
            defer { metadataProviderLock.unlock() }
            return _metadataProvider
        }
        set {
            metadataProviderLock.lock()
            _metadataProvider = newValue
            metadataProviderLock.unlock()
        }
    }

    public typealias DeltaObserver = (_ projectID: String, _ snapshot: ProjectGhostRoster) -> Void

    /// Optional callback fired on the main thread immediately after `roster`
    /// is updated. Task #3 wires this to the WebView bridge once that PR
    /// lands; until then, it is the dlog hook used for verification.
    public var onDelta: DeltaObserver?

    /// Issue #17 per-session state attached to a transcript URL. We track the
    /// assigned seat (`tableID`) and the motion-phase start time separately
    /// from the `GhostStateMachine` so the state machine stays a pure mapping
    /// of `tool_use → GhostState`.
    private struct SessionMotion: Equatable {
        var tableID: Int?
        var motionStartedAt: Date?
        /// Captures the `state` at the time motion last changed. Used to
        /// detect post-launch idle-collapse so we can flip back to wandering.
        var lastSnapshotState: GhostState
        /// Cmux-managed attention flag — true when the workspace has an
        /// unread notification on this agent's surface.
        var needsAttention: Bool = false
        /// The "free ghost generation" this session inherited when it was
        /// first observed. Renders as the trailing `__free__<gen>` in the
        /// ghost id so the previously-wandering ghost visually walks to the
        /// desk on launch and a fresh wandering ghost (with the next gen)
        /// spawns to take its place. See `nextFreeGen` on `ProjectContext`.
        var freeGen: Int
    }

    private struct ProjectContext {
        let cwd: String
        /// Optional: cmux-managed workspace projects do not run a transcript
        /// watcher. They are driven directly by `noteAgent*` calls fed from
        /// `Workspace.statusEntries["claude_code"]` observers.
        let watcher: ClaudeTranscriptWatcher?
        var sessionStates: [URL: GhostStateMachine]
        var sessionLabels: [URL: String]
        var sessionMotion: [URL: SessionMotion]
        var orderedSessions: [URL]
        var lastSnapshot: ProjectGhostRoster?
        /// Next "free ghost generation" — the suffix used by the trailing
        /// wandering ghost in the snapshot. Bumped each time a new session
        /// claims the current free ghost's identity, so the wandering DOM
        /// element transitions in place from `wander` to `walk-to-desk` and
        /// a fresh wandering ghost takes its slot.
        var nextFreeGen: Int = 0
    }

    private var projects: [String: ProjectContext] = [:]
    private let stateQueue: DispatchQueue
    private let index: ProjectTranscriptIndex

    /// Idle-collapse refresh cadence. The state machine collapses to `.Idle`
    /// at `GhostStateMachine.idleThreshold` (60s) of inactivity; we sweep at
    /// a fraction of that so a session that sees no further `tool_use` lines
    /// still flips to `.Idle` within ~5s of the threshold.
    private let idleRefreshInterval: DispatchTimeInterval
    private var idleRefreshTimer: DispatchSourceTimer?

    public init(
        index: ProjectTranscriptIndex = ProjectTranscriptIndex(),
        stateQueue: DispatchQueue? = nil,
        idleRefreshInterval: DispatchTimeInterval = .seconds(5)
    ) {
        self.index = index
        self.stateQueue = stateQueue ?? DispatchQueue(
            label: "cmux.ghost-dashboard.roster",
            qos: .utility
        )
        self.idleRefreshInterval = idleRefreshInterval
    }

    deinit {
        idleRefreshTimer?.cancel()
        for (_, ctx) in projects {
            ctx.watcher?.stop()
        }
    }

    // MARK: - Registration

    /// Register a project. Idempotent.
    public func register(projectID: String, cwd: String, coldStart: Bool = true) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()

            if self.projects[projectID] != nil { return }

            let watcher = ClaudeTranscriptWatcher(
                projectID: projectID,
                cwd: cwd,
                index: self.index
            ) { [weak self] pid, events in
                // Watcher callbacks land on the watcher's private queue. Hop
                // onto stateQueue so all `projects` mutations stay serialized
                // with register/unregister/ingestForTesting.
                self?.stateQueue.async { [weak self] in
                    self?.process(projectID: pid, events: events)
                }
            }

            let initialSnapshot = ProjectGhostRoster(projectID: projectID, ghosts: [])
            self.projects[projectID] = ProjectContext(
                cwd: cwd,
                watcher: watcher,
                sessionStates: [:],
                sessionLabels: [:],
                sessionMotion: [:],
                orderedSessions: [],
                lastSnapshot: initialSnapshot
            )
            watcher.start(coldStart: coldStart)
            self.startIdleRefreshTimerIfNeeded()

            // Seed an empty roster on the main thread so observers can render
            // the project even before any tool_use lands.
            self.commitOnMain(projectID: projectID, snapshot: initialSnapshot)
        }
    }

    /// Min dwell time (in main-queue) between emitting the `.despawning`
    /// snapshot and dropping the roster entry. Must exceed the bridge's
    /// 20 ms coalesce window so the despawn delta isn't merged with the
    /// removal delta and lost (Issue #14).
    public static let despawnDwell: DispatchTimeInterval = .milliseconds(300)

    public func unregister(projectID: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            // Emit a final "despawning" snapshot so the renderer can play the
            // disappear animation before the project is dropped (Issue #14).
            let hadContext = self.projects[projectID] != nil
            if let ctx = self.projects[projectID] {
                let now = Date()
                let despawnSnapshot = self.buildDespawnSnapshot(projectID: projectID, ctx: ctx, now: now)
                self.commitOnMain(projectID: projectID, snapshot: despawnSnapshot)
            }
            if let ctx = self.projects.removeValue(forKey: projectID) {
                ctx.watcher?.stop()
            }
            if self.projects.isEmpty {
                self.stopIdleRefreshTimer()
            }
            // Wait long enough for the bridge coalesce window + a renderer
            // animation tick before pulling the roster entry. Without this
            // delay the removal delta clobbers the despawning delta inside
            // the 20 ms coalesce buffer.
            let dwell: DispatchTimeInterval = hadContext ? Self.despawnDwell : .milliseconds(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell) {
                self.roster.removeValue(forKey: projectID)
            }
        }
    }

    // MARK: - cmux-managed agents (no transcript watcher)
    //
    // The dashboard observes `Workspace.statusEntries["claude_code"]` per
    // cmux workspace and translates state changes into these calls. The
    // synthetic session URL `cmux-agent://<workspaceID>/<agentKey>` keeps
    // session bookkeeping (table assignment, motion clock, idle/active
    // state) compatible with the transcript-driven path even though no file
    // exists on disk.

    /// Recover the cmux panel UUID (the `agentKey`) from a session URL built
    /// by `cmuxAgentSessionURL`. Returns nil for non-cmux session URLs (e.g.
    /// transcript-derived sessions). The JS overlay uses this to round-trip
    /// a ghost click back to the originating terminal panel.
    static func panelID(fromSessionURL url: URL) -> String? {
        guard url.scheme == "cmux-agent" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let last = parts.last else { return nil }
        return last.removingPercentEncoding ?? last
    }

    /// Stable synthetic URL for a cmux-managed agent session.
    private static func cmuxAgentSessionURL(workspaceID: String, agentKey: String) -> URL {
        // Encode arbitrary characters so URL parsing never fails on weird
        // workspace names. UUIDs and the "claude_code" key are both safe but
        // future agent keys may not be.
        let escapedWorkspace = workspaceID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? workspaceID
        let escapedAgent = agentKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? agentKey
        return URL(string: "cmux-agent://\(escapedWorkspace)/\(escapedAgent)")
            ?? URL(fileURLWithPath: "/tmp/cmux-agent-\(escapedWorkspace)-\(escapedAgent)")
    }

    /// Register a cmux workspace as a project. Idempotent. No transcript
    /// watcher is started — the workspace's ghost lifecycle is driven
    /// entirely by `noteAgent*` calls fed from cmux status observers.
    public func registerWorkspace(workspaceID: String, displayName: String, cwd: String = "") {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            if self.projects[workspaceID] != nil { return }
            var ctx = ProjectContext(
                cwd: cwd,
                watcher: nil,
                sessionStates: [:],
                sessionLabels: [:],
                sessionMotion: [:],
                orderedSessions: [],
                lastSnapshot: nil
            )
            // Build the initial snapshot (just the free wandering ghost) so
            // the renderer shows the workspace tile immediately. Use the
            // local `ctx` for inout, then write the populated context back
            // into `self.projects` — avoids the Dictionary force-unwrap +
            // inout pattern that Swift's exclusivity rules disallow.
            self.startIdleRefreshTimerIfNeeded()
            let snapshot = self.buildSnapshot(projectID: workspaceID, ctx: &ctx, now: Date())
            ctx.lastSnapshot = snapshot
            self.projects[workspaceID] = ctx
            #if DEBUG
            dlog("ghost.register workspace=\(workspaceID.prefix(8)) ghosts=\(snapshot.ghosts.count)")
            #endif
            self.commitOnMain(projectID: workspaceID, snapshot: snapshot)
        }
    }

    /// Drop a cmux-managed workspace. Mirrors `unregister(projectID:)` but
    /// skips the watcher.stop() (there is none).
    public func unregisterWorkspace(workspaceID: String) {
        unregister(projectID: workspaceID)
    }

    /// Note that an agent (e.g. Claude Code) launched in this workspace.
    /// Treated as a session start: assigns a free desk and starts the
    /// walk-to-desk animation. Idempotent for the same `agentKey`.
    public func noteAgentLaunched(workspaceID: String, agentKey: String, label: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            self.applyAgentEvent(
                workspaceID: workspaceID,
                agentKey: agentKey,
                label: label,
                state: .Coding,
                isLaunch: true,
                ended: false
            )
        }
    }

    /// Note that the agent in this workspace went idle. Stays seated; the
    /// renderer flips to the seated Idle pose.
    public func noteAgentIdle(workspaceID: String, agentKey: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            self.applyAgentEvent(
                workspaceID: workspaceID,
                agentKey: agentKey,
                label: "",
                state: .Idle,
                isLaunch: false,
                ended: false
            )
        }
    }

    /// Toggle the "needs attention" speech-bubble for a cmux-managed agent.
    /// Driven by `TerminalNotificationStore` per-tab unread counts so the
    /// ghost surfaces a "?" badge and red-glow pose whenever Claude Code
    /// fires a Notification hook.
    public func noteAgentNeedsAttention(workspaceID: String, agentKey: String, needs: Bool) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            guard var ctx = self.projects[workspaceID] else { return }
            let sessionKey = Self.cmuxAgentSessionURL(workspaceID: workspaceID, agentKey: agentKey)
            // Only flip if a session exists for this agent. A notification
            // arriving before the session-start hook (rare) would otherwise
            // create a phantom session with no state machine.
            guard ctx.orderedSessions.contains(sessionKey) else { return }
            var motion = ctx.sessionMotion[sessionKey] ?? SessionMotion(
                tableID: nil,
                motionStartedAt: nil,
                lastSnapshotState: .Idle,
                freeGen: ctx.nextFreeGen
            )
            guard motion.needsAttention != needs else { return }
            motion.needsAttention = needs
            ctx.sessionMotion[sessionKey] = motion
            let snapshot = self.buildSnapshot(projectID: workspaceID, ctx: &ctx, now: Date())
            ctx.lastSnapshot = snapshot
            self.projects[workspaceID] = ctx
            self.commitOnMain(projectID: workspaceID, snapshot: snapshot)
        }
    }

    /// Note that the agent in this workspace ended (terminal closed, PID
    /// gone). Removes the session entry, freeing the desk.
    public func noteAgentEnded(workspaceID: String, agentKey: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            self.applyAgentEvent(
                workspaceID: workspaceID,
                agentKey: agentKey,
                label: "",
                state: .Idle,
                isLaunch: false,
                ended: true
            )
        }
    }

    private func applyAgentEvent(
        workspaceID: String,
        agentKey: String,
        label: String,
        state: GhostState,
        isLaunch: Bool,
        ended: Bool
    ) {
        guard var ctx = projects[workspaceID] else {
            #if DEBUG
            dlog("ghost.agent.miss workspace=\(workspaceID.prefix(8)) agent=\(agentKey.prefix(8)) launch=\(isLaunch) end=\(ended) — workspace not registered")
            #endif
            return
        }
        let sessionKey = Self.cmuxAgentSessionURL(workspaceID: workspaceID, agentKey: agentKey)
        let now = Date()

        if ended {
            ctx.sessionStates.removeValue(forKey: sessionKey)
            ctx.sessionLabels.removeValue(forKey: sessionKey)
            ctx.sessionMotion.removeValue(forKey: sessionKey)
            ctx.orderedSessions.removeAll { $0 == sessionKey }
        } else {
            var machine = ctx.sessionStates[sessionKey] ?? GhostStateMachine()
            let isFirstObservation = !ctx.orderedSessions.contains(sessionKey)
            if isFirstObservation {
                machine.markSpawned(at: now)
                ctx.orderedSessions.append(sessionKey)
                // Claim the current free-ghost generation. The previously
                // wandering ghost (rendered with id `__free__<gen>`) now
                // becomes this session, so the JS overlay reuses its DOM and
                // walks it to the desk in place. Bumping `nextFreeGen` makes
                // the next snapshot append a fresh wandering ghost.
                ctx.sessionMotion[sessionKey] = SessionMotion(
                    tableID: nil,
                    motionStartedAt: nil,
                    lastSnapshotState: state,
                    freeGen: ctx.nextFreeGen
                )
                ctx.nextFreeGen += 1
            }
            // Drive the state machine through a synthetic tool name so the
            // existing `apply` path does its bookkeeping (lastActivity,
            // didLaunch detection).
            if state == .Idle {
                // Force the visible state to Idle by clearing lastActivity
                // implicitly: write Idle as the current state. We can't
                // bypass the state machine cleanly, so apply a no-op tool
                // and then mark idle via the time axis on the next sweep.
                // For an immediate flip, we just record a label change and
                // let buildSnapshot derive .Idle once the agent has been
                // marked idle. The roster entry's state field reads from
                // `currentState(now:)` which collapses to .Idle after the
                // 60s threshold — too slow. Instead, build the entry
                // directly using the supplied state.
                ctx.sessionLabels[sessionKey] = label
                ctx.sessionStates[sessionKey] = machine
            } else {
                let synthetic = (state == .Coding) ? "Edit" : "Read"
                _ = machine.apply(toolName: synthetic, at: now)
                ctx.sessionStates[sessionKey] = machine
                ctx.sessionLabels[sessionKey] = label.isEmpty ? synthetic : label
            }

            // Assign a desk + start walk clock on launch.
            if isLaunch {
                var motion = ctx.sessionMotion[sessionKey] ?? SessionMotion(
                    tableID: nil,
                    motionStartedAt: nil,
                    lastSnapshotState: .Idle,
                    freeGen: ctx.nextFreeGen
                )
                if motion.tableID == nil {
                    motion.tableID = Self.assignFreeTable(in: ctx.sessionMotion)
                }
                motion.motionStartedAt = now
                motion.lastSnapshotState = state
                ctx.sessionMotion[sessionKey] = motion
            }
        }

        let snapshot = buildSnapshot(
            projectID: workspaceID,
            ctx: &ctx,
            now: now,
            overrideStates: ended ? [:] : [sessionKey: state]
        )
        ctx.lastSnapshot = snapshot
        projects[workspaceID] = ctx
        #if DEBUG
        dlog("ghost.agent.apply workspace=\(workspaceID.prefix(8)) agent=\(agentKey.prefix(8)) launch=\(isLaunch) end=\(ended) ghosts=\(snapshot.ghosts.count) sessions=\(ctx.orderedSessions.count)")
        #endif
        commitOnMain(projectID: workspaceID, snapshot: snapshot)
    }

    /// Mark a single ghost (session) as needing human intervention. Drives
    /// the `.warning` lifecycle in the next snapshot. Issue #14.
    public func raiseWarning(projectID: String, ghostID: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            self.mutateMachine(projectID: projectID, ghostID: ghostID) { machine in
                machine.raiseWarning(at: Date())
            }
        }
    }

    /// Clear an active warning for a single ghost.
    public func clearWarning(projectID: String, ghostID: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dispatchPreconditionOffMain()
            self.mutateMachine(projectID: projectID, ghostID: ghostID) { machine in
                machine.clearWarning()
            }
        }
    }

    private func mutateMachine(
        projectID: String,
        ghostID: String,
        _ mutate: (inout GhostStateMachine) -> Void
    ) {
        guard var ctx = projects[projectID] else { return }
        guard let sessionURL = ctx.orderedSessions.first(where: { url in
            let freeGen = ctx.sessionMotion[url]?.freeGen ?? 0
            return Self.ghostID(projectID: projectID, freeGen: freeGen) == ghostID
        }) else { return }
        var machine = ctx.sessionStates[sessionURL] ?? GhostStateMachine()
        mutate(&machine)
        ctx.sessionStates[sessionURL] = machine
        let snapshot = buildSnapshot(projectID: projectID, ctx: &ctx, now: Date())
        ctx.lastSnapshot = snapshot
        projects[projectID] = ctx
        commitOnMain(projectID: projectID, snapshot: snapshot)
    }

    private func buildDespawnSnapshot(
        projectID: String,
        ctx: ProjectContext,
        now: Date
    ) -> ProjectGhostRoster {
        // Same shape as `buildSnapshot` but every ghost gets `.despawning` so
        // the renderer can play the exit animation before removal. The free
        // ghost is omitted — it never had a session so it has nothing to
        // despawn from.
        let sessions = ctx.orderedSessions.prefix(Self.maxAssignedPerProject)
        let entries: [GhostEntry] = sessions.map { url in
            let machine = ctx.sessionStates[url] ?? GhostStateMachine()
            let label = ctx.sessionLabels[url] ?? ""
            let freeGen = ctx.sessionMotion[url]?.freeGen ?? 0
            let id = Self.ghostID(projectID: projectID, freeGen: freeGen)
            return GhostEntry(
                id: id,
                state: machine.currentState(now: now),
                label: label,
                lastActivity: machine.lastActivity,
                lifecycle: .despawning
            )
        }
        return ProjectGhostRoster(projectID: projectID, ghosts: Array(entries))
    }

    // MARK: - Event ingestion

    /// Test seam: synchronously feed events as if they came from the watcher.
    public func ingestForTesting(projectID: String, events: [TranscriptEvent]) {
        stateQueue.sync {
            process(projectID: projectID, events: events)
        }
    }

    /// Test seam: synchronously trigger an idle-state sweep, as if the timer
    /// fired now. Lets unit tests advance the wall clock with a fake date.
    public func refreshIdleStatesForTesting(now: Date = Date()) {
        stateQueue.sync {
            sweepIdleStates(now: now)
        }
    }

    private func process(projectID: String, events: [TranscriptEvent]) {
        // We are on stateQueue (serial). The seed AC requires this path to
        // never touch .main — assert it loudly in DEBUG.
        dispatchPreconditionOffMain()

        guard var ctx = projects[projectID] else { return }
        // cmux-managed workspaces have no transcript watcher; this path is
        // only valid for projects registered via `register(projectID:cwd:)`.
        guard let watcher = ctx.watcher else { return }
        var changed = false

        for event in events {
            // Each line yields zero or more tool_use entries. Without a session
            // id we still want to count the line — fall back to a single
            // logical session ("default") so the project shows at least one
            // ghost.
            let sessionKey: URL = {
                if let sid = event.sessionId, !sid.isEmpty {
                    return watcher.projectDirectoryURL.appendingPathComponent("\(sid).jsonl")
                }
                return watcher.projectDirectoryURL.appendingPathComponent("default.jsonl")
            }()

            let names = event.toolUseNames
            if names.isEmpty { continue }

            for name in names {
                var machine = ctx.sessionStates[sessionKey] ?? GhostStateMachine()
                let isFirstObservation = !ctx.orderedSessions.contains(sessionKey)
                if isFirstObservation {
                    // Spawn marker drives the `.walking` lifecycle for the
                    // walkingDuration window (Issue #14).
                    machine.markSpawned(at: event.parsedTimestamp())
                }
                let result = machine.apply(toolName: name, at: event.parsedTimestamp())
                ctx.sessionStates[sessionKey] = machine
                ctx.sessionLabels[sessionKey] = name
                if isFirstObservation {
                    ctx.orderedSessions.append(sessionKey)
                    // Claim the current free-ghost generation so the wandering
                    // DOM element transitions in place (see notes on
                    // `applyAgentEvent`).
                    ctx.sessionMotion[sessionKey] = SessionMotion(
                        tableID: nil,
                        motionStartedAt: nil,
                        lastSnapshotState: result.state,
                        freeGen: ctx.nextFreeGen
                    )
                    ctx.nextFreeGen += 1
                }

                // Issue #17: agent launched (Idle → active). Assign a free
                // table if the session does not have one yet, and (re)start
                // the walking-motion clock so the JS overlay animates the
                // ghost to its desk.
                if result.didLaunch {
                    var motion = ctx.sessionMotion[sessionKey] ?? SessionMotion(
                        tableID: nil,
                        motionStartedAt: nil,
                        lastSnapshotState: .Idle,
                        freeGen: ctx.nextFreeGen
                    )
                    if motion.tableID == nil {
                        motion.tableID = Self.assignFreeTable(in: ctx.sessionMotion)
                    }
                    motion.motionStartedAt = event.parsedTimestamp()
                    motion.lastSnapshotState = result.state
                    ctx.sessionMotion[sessionKey] = motion
                }
                changed = true
            }
        }

        let now = Date()
        let snapshot = buildSnapshot(projectID: projectID, ctx: &ctx, now: now)

        // Even when no `tool_use` lines arrived (`changed == false`) the time
        // axis can still flip a session from active to `.Idle`, so always
        // diff the rendered snapshot against the last committed one.
        let shouldCommit = changed || ctx.lastSnapshot != snapshot
        if shouldCommit {
            ctx.lastSnapshot = snapshot
        }
        projects[projectID] = ctx

        if shouldCommit {
            commitOnMain(projectID: projectID, snapshot: snapshot)
        }
    }

    private func sweepIdleStates(now: Date) {
        dispatchPreconditionOffMain()
        for projectID in projects.keys {
            guard var ctx = projects[projectID] else { continue }
            let snapshot = buildSnapshot(projectID: projectID, ctx: &ctx, now: now)
            if ctx.lastSnapshot != snapshot {
                ctx.lastSnapshot = snapshot
                projects[projectID] = ctx
                commitOnMain(projectID: projectID, snapshot: snapshot)
            }
        }
    }

    // MARK: - Idle refresh timer

    private func startIdleRefreshTimerIfNeeded() {
        dispatchPreconditionOffMain()
        guard idleRefreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + idleRefreshInterval, repeating: idleRefreshInterval)
        timer.setEventHandler { [weak self] in
            self?.sweepIdleStates(now: Date())
        }
        idleRefreshTimer = timer
        timer.resume()
    }

    private func stopIdleRefreshTimer() {
        dispatchPreconditionOffMain()
        idleRefreshTimer?.cancel()
        idleRefreshTimer = nil
    }

    private func buildSnapshot(
        projectID: String,
        ctx: inout ProjectContext,
        now: Date,
        overrideStates: [URL: GhostState] = [:]
    ) -> ProjectGhostRoster {
        // Deterministic ordering: oldest-seen first; cap at the desk count.
        let sessions = ctx.orderedSessions.prefix(Self.maxAssignedPerProject)
        var entries: [GhostEntry] = []
        entries.reserveCapacity(sessions.count + 1)

        for url in sessions {
            let machine = ctx.sessionStates[url] ?? GhostStateMachine()
            let label = ctx.sessionLabels[url] ?? ""
            // cmux-managed sessions pin their state explicitly so the renderer
            // doesn't have to wait for the 60s idle threshold to flip
            // Running → Idle.
            let state = overrideStates[url] ?? machine.currentState(now: now)

            var motion = ctx.sessionMotion[url] ?? SessionMotion(
                tableID: nil,
                motionStartedAt: nil,
                lastSnapshotState: .Idle,
                freeGen: 0
            )
            let id = Self.ghostID(projectID: projectID, freeGen: motion.freeGen)
            // Once a session is bound to a desk, the ghost stays seated for
            // the lifetime of the terminal instance — even when the session
            // collapses to `.Idle` ("Idle at desk"). The desk is only freed
            // on `unregister`/session removal.
            motion.lastSnapshotState = state
            ctx.sessionMotion[url] = motion

            let phase = Self.derivePhase(
                state: state,
                tableID: motion.tableID,
                motionStartedAt: motion.motionStartedAt,
                now: now
            )

            entries.append(GhostEntry(
                id: id,
                state: state,
                label: label,
                lastActivity: machine.lastActivity,
                lifecycle: motion.needsAttention ? .warning : machine.currentLifecycle(now: now),
                tableID: motion.tableID,
                motion: phase,
                motionStartedAt: motion.motionStartedAt,
                needsAttention: motion.needsAttention,
                panelID: Self.panelID(fromSessionURL: url)
            ))
        }

        // Append a synthetic "free" wandering ghost unless every desk is
        // already taken. It represents the idle ghost waiting to be assigned
        // to the next Claude Code instance the user launches. Its id uses
        // `ctx.nextFreeGen` so the JS overlay can transition the same DOM
        // element from `wander` to `walk-to-desk` when this ghost gets
        // claimed by the next session — and a fresh wandering ghost (with
        // the bumped gen) takes its place.
        let assignedCount = entries.filter { $0.tableID != nil }.count
        if assignedCount < Self.maxAssignedPerProject {
            entries.append(GhostEntry(
                id: Self.ghostID(projectID: projectID, freeGen: ctx.nextFreeGen),
                state: .Idle,
                label: "",
                lastActivity: nil,
                lifecycle: .idle,
                tableID: nil,
                motion: .wandering,
                motionStartedAt: nil,
                needsAttention: false
            ))
        }

        return ProjectGhostRoster(projectID: projectID, ghosts: entries)
    }

    /// Compose the ghost id used by the JS overlay. The `__free__<gen>`
    /// scheme keys workers by their generation so the wandering DOM element
    /// is reused when a session "claims" the current free ghost on launch.
    private static func ghostID(projectID: String, freeGen: Int) -> String {
        return "\(projectID)#\(freeGhostSuffix)\(freeGen)"
    }

    /// Pick the lowest free seat index in `0..<maxGhostsPerProject`. Lowest-
    /// index policy keeps the assignment deterministic and idempotent across
    /// rebuilds.
    private static func assignFreeTable(in sessionMotion: [URL: SessionMotion]) -> Int? {
        var taken = Set<Int>()
        for (_, m) in sessionMotion {
            if let id = m.tableID { taken.insert(id) }
        }
        for candidate in 0..<maxGhostsPerProject where !taken.contains(candidate) {
            return candidate
        }
        return nil
    }

    /// Derive the visible motion phase from the seat assignment + state +
    /// elapsed time since the motion clock started.
    ///
    /// An assigned ghost (one with a `tableID`) is **bound to its desk for
    /// the lifetime of the terminal instance**: it walks there on launch
    /// and stays settled afterwards, including when the underlying session
    /// collapses to `.Idle` ("Idle at desk"). Only when the session is
    /// unregistered does the desk free up.
    private static func derivePhase(
        state: GhostState,
        tableID: Int?,
        motionStartedAt: Date?,
        now: Date
    ) -> GhostMotion {
        // No seat yet → ghost is still floating around looking for one.
        guard tableID != nil else { return .spawning }
        // We know when the walk started → settle after walkDuration.
        if let started = motionStartedAt,
           now.timeIntervalSince(started) >= GhostMotion.walkDuration {
            return .settled
        }
        // Walking starts on launch; if no walk clock yet (e.g. session
        // observed before any tool_use), treat as already settled.
        return motionStartedAt == nil ? .settled : .walking
    }

    private func commitOnMain(projectID: String, snapshot: ProjectGhostRoster) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.roster[projectID] = snapshot
            #if DEBUG
            dlog(
                "ghost.roster.delta project=\(projectID) "
                + "ghosts=\(snapshot.ghosts.count) "
                + "states=\(snapshot.ghosts.map { "\($0.state.rawValue):\($0.label):table=\($0.tableID.map(String.init) ?? "-"):motion=\($0.motion.rawValue)" }.joined(separator: ","))"
            )
            #endif
            self.onDelta?(projectID, snapshot)
        }
    }

    /// Self-verification helper. The seed treats a single hop onto `.main`
    /// during parsing as a regression of `typing_latency_zero`.
    @inline(__always)
    private func dispatchPreconditionOffMain() {
        dispatchPrecondition(condition: .notOnQueue(.main))
    }
}
