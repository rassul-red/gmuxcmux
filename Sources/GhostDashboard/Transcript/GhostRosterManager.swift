import Combine
import Darwin
import Foundation
#if DEBUG
import Bonsplit
#endif

/// One ghost in a project roster.
public struct GhostEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public var state: GhostState
    public var label: String
    public var lastActivity: Date?
    /// Lifecycle phase for the renderer (Issue #14). Defaults to `.idle` so
    /// existing callers and tests stay source-compatible.
    public var lifecycle: GhostLifecycle

    public init(
        id: String,
        state: GhostState = .Idle,
        label: String = "",
        lastActivity: Date? = nil,
        lifecycle: GhostLifecycle = .idle
    ) {
        self.id = id
        self.state = state
        self.label = label
        self.lastActivity = lastActivity
        self.lifecycle = lifecycle
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
    public static let maxGhostsPerProject = 5

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

    private struct ProjectContext {
        let cwd: String
        let watcher: ClaudeTranscriptWatcher
        var sessionStates: [URL: GhostStateMachine]
        var sessionLabels: [URL: String]
        var orderedSessions: [URL]
        var lastSnapshot: ProjectGhostRoster?
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
            ctx.watcher.stop()
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
                ctx.watcher.stop()
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
            "\(projectID)#\(url.deletingPathExtension().lastPathComponent)" == ghostID
        }) else { return }
        var machine = ctx.sessionStates[sessionURL] ?? GhostStateMachine()
        mutate(&machine)
        ctx.sessionStates[sessionURL] = machine
        let snapshot = buildSnapshot(projectID: projectID, ctx: ctx, now: Date())
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
        // the renderer can play the exit animation before removal.
        let sessions = ctx.orderedSessions.prefix(Self.maxGhostsPerProject)
        let entries: [GhostEntry] = sessions.map { url in
            let machine = ctx.sessionStates[url] ?? GhostStateMachine()
            let label = ctx.sessionLabels[url] ?? ""
            let id = "\(projectID)#\(url.deletingPathExtension().lastPathComponent)"
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
        var changed = false

        for event in events {
            // Each line yields zero or more tool_use entries. Without a session
            // id we still want to count the line — fall back to a single
            // logical session ("default") so the project shows at least one
            // ghost.
            let sessionKey: URL = {
                if let sid = event.sessionId, !sid.isEmpty {
                    return ctx.watcher.projectDirectoryURL.appendingPathComponent("\(sid).jsonl")
                }
                return ctx.watcher.projectDirectoryURL.appendingPathComponent("default.jsonl")
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
                machine.apply(toolName: name, at: event.parsedTimestamp())
                ctx.sessionStates[sessionKey] = machine
                ctx.sessionLabels[sessionKey] = name
                if isFirstObservation {
                    ctx.orderedSessions.append(sessionKey)
                }
                changed = true
            }
        }

        let now = Date()
        let snapshot = buildSnapshot(projectID: projectID, ctx: ctx, now: now)

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
            let snapshot = buildSnapshot(projectID: projectID, ctx: ctx, now: now)
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

    private func buildSnapshot(projectID: String, ctx: ProjectContext, now: Date) -> ProjectGhostRoster {
        // Deterministic ordering: oldest-seen first; cap at 5.
        let sessions = ctx.orderedSessions.prefix(Self.maxGhostsPerProject)
        let entries: [GhostEntry] = sessions.enumerated().map { (idx, url) in
            let machine = ctx.sessionStates[url] ?? GhostStateMachine()
            let label = ctx.sessionLabels[url] ?? ""
            let id = "\(projectID)#\(url.deletingPathExtension().lastPathComponent)"
            let _ = idx // index reserved for stable ordering, unused for now
            return GhostEntry(
                id: id,
                state: machine.currentState(now: now),
                label: label,
                lastActivity: machine.lastActivity,
                lifecycle: machine.currentLifecycle(now: now)
            )
        }
        return ProjectGhostRoster(projectID: projectID, ghosts: Array(entries))
    }

    private func commitOnMain(projectID: String, snapshot: ProjectGhostRoster) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.roster[projectID] = snapshot
            #if DEBUG
            dlog(
                "ghost.roster.delta project=\(projectID) "
                + "ghosts=\(snapshot.ghosts.count) "
                + "states=\(snapshot.ghosts.map { "\($0.state.rawValue):\($0.label)" }.joined(separator: ","))"
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

