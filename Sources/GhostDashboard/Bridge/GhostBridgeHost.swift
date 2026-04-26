import Combine
import Foundation
import WebKit
import os.lock
#if DEBUG
import Bonsplit
#endif

/// Hosts the Swift side of the Ghost dashboard bridge.
///
/// Responsibilities:
///   - Implements `WKScriptMessageHandler` for the four named handlers
///     (`ghost.action.v1`, `ghost.bridge.metrics`, plus inert acceptance of
///     the Swift→JS names so misdirected messages are diagnosed instead of
///     silently dropped).
///   - Encodes and pushes `ghost.snapshot.v1` / `ghost.delta.v1` envelopes
///     to JS via `WKWebView.evaluateJavaScript`.
///   - Subscribes to `GhostRosterManager.$roster` and emits coalesced delta
///     pushes (20 ms window) so a flurry of updates collapses to one push
///     per project per window.
///   - Tracks `snapshotsSent` / `deltasSent` counters readable by tests
///     (the integration soak in #3 compares these against
///     `console.count("[bridge] delta")` from the JS side).
public final class GhostBridgeHost: NSObject, WKScriptMessageHandler {

    public typealias ActionHandler = (GhostActionPayload) -> Void

    public var onRoomSelect: ActionHandler?
    public var onOpenProject: ActionHandler?
    public var onInterrupt: ActionHandler?
    public var onNewTask: ActionHandler?
    public var onFollow: ActionHandler?

    /// Test seam: invoked whenever a `broadcast` or `groupChat` message lands.
    /// Production code uses the `dlog` no-op path; tests can capture intent.
    public var onNoOpAction: ((String) -> Void)?

    /// Coalesce window for delta pushes. The dashboard renderer can absorb at
    /// most ~30 fps comfortably; 20 ms collapses bursts without adding visible
    /// latency.
    public static let coalesceWindow: DispatchTimeInterval = .milliseconds(20)

    public weak var webView: WKWebView?

    private struct Counters {
        var snapshots: Int32 = 0
        var deltas: Int32 = 0
    }

    private let counterLock = OSAllocatedUnfairLock(initialState: Counters())

    public var snapshotsSent: Int32 {
        counterLock.withLock { $0.snapshots }
    }

    public var deltasSent: Int32 {
        counterLock.withLock { $0.deltas }
    }

    /// Reset counters. Test seam used by long-running soaks that span more
    /// than one assertion window.
    public func resetCountersForTesting() {
        counterLock.withLock { state in
            state.snapshots = 0
            state.deltas = 0
        }
    }

    private let coalesceQueue = DispatchQueue(
        label: "cmux.ghost-bridge.coalesce",
        qos: .userInitiated
    )

    /// Main-actor mutable state — guarded by serial coalesceQueue.
    private var pendingDeltas: [String: GhostDeltaPayload] = [:]
    private var lastEmittedRoster: [String: ProjectGhostRoster] = [:]
    private var pendingFlushScheduled = false
    private var hasEmittedInitialSnapshot = false

    private var cancellables: Set<AnyCancellable> = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    public override init() {
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case GhostBridgeMessageName.action:
            handleActionBody(message.body)
        case GhostBridgeMessageName.metrics:
            handleMetricsBody(message.body)
        case GhostBridgeMessageName.snapshot, GhostBridgeMessageName.delta:
            // Snapshot/delta are Swift→JS only. If JS posts one back, log it
            // so misuse does not silently disappear.
            #if DEBUG
            dlog("ghost.bridge inbound on Swift→JS channel name=\(message.name)")
            #endif
        default:
            #if DEBUG
            dlog("ghost.bridge unknown name=\(message.name)")
            #endif
        }
    }

    private func handleActionBody(_ body: Any) {
        guard let raw = body as? String, let data = raw.data(using: .utf8) else {
            #if DEBUG
            dlog("ghost.action.v1 invalid body type=\(type(of: body))")
            #endif
            return
        }
        // The contract allows two shapes:
        //   1) { v:1, payload: GhostActionPayload } — preferred (matches
        //      Swift→JS shape; AC requires v != 1 reject).
        //   2) GhostActionPayload as the raw body — accepted for parity with
        //      bridge.js call sites that build an action without an envelope.
        if let envelope = try? decoder.decode(
            GhostEnvelope<GhostActionPayload>.self,
            from: data
        ) {
            guard envelope.v == 1 else {
                #if DEBUG
                dlog("ghost.action.v1 reject v=\(envelope.v)")
                #endif
                return
            }
            route(action: envelope.payload)
            return
        }
        if let payload = try? decoder.decode(GhostActionPayload.self, from: data) {
            route(action: payload)
            return
        }
        #if DEBUG
        dlog("ghost.action.v1 decode failed body=\(raw.prefix(120))")
        #endif
    }

    private func handleMetricsBody(_ body: Any) {
        // Informational. Tests query JS-side counters directly via
        // console.count + the `__ghostBridge.counters()` accessor; this
        // handler exists so JS can opt-in to telemetry without an exception.
        #if DEBUG
        if let str = body as? String {
            dlog("ghost.bridge.metrics body=\(str.prefix(160))")
        }
        #endif
    }

    private func route(action: GhostActionPayload) {
        switch action.action {
        case GhostBridgeAction.roomSelect:
            onRoomSelect?(action)
        case GhostBridgeAction.openProject:
            onOpenProject?(action)
        case GhostBridgeAction.interrupt:
            onInterrupt?(action)
        case GhostBridgeAction.newTask:
            onNewTask?(action)
        case GhostBridgeAction.follow:
            onFollow?(action)
        case GhostBridgeAction.broadcast, GhostBridgeAction.groupChat:
            #if DEBUG
            dlog("bridge.action.noop action=\(action.action)")
            #endif
            onNoOpAction?(action.action)
        default:
            #if DEBUG
            dlog("bridge.action.unknown action=\(action.action)")
            #endif
        }
    }

    // MARK: - Roster subscription

    /// Wire this host to a `WKWebView` and a `GhostRosterManager`. Pushes an
    /// initial full snapshot, then emits coalesced delta pushes thereafter.
    ///
    /// `projectMetadataProvider` lets the caller supply project-level
    /// metadata (display name, cwd, status) that the roster manager itself
    /// does not own.
    public func attach(
        webView: WKWebView,
        rosterManager: GhostRosterManager,
        projectMetadataProvider: @escaping (String) -> (name: String, cwd: String, status: String)
    ) {
        self.webView = webView
        let metadata = projectMetadataProvider

        rosterManager.$roster
            .removeDuplicates()
            .receive(on: coalesceQueue)
            .sink { [weak self] roster in
                self?.ingestRoster(roster, metadata: metadata)
            }
            .store(in: &cancellables)
    }

    private func ingestRoster(
        _ roster: [String: ProjectGhostRoster],
        metadata: (String) -> (name: String, cwd: String, status: String)
    ) {
        if !hasEmittedInitialSnapshot {
            hasEmittedInitialSnapshot = true
            let snapshot = Self.buildSnapshot(roster: roster, metadata: metadata)
            lastEmittedRoster = roster
            push(snapshot: snapshot)
            return
        }

        var changed = false
        for (projectID, project) in roster {
            if lastEmittedRoster[projectID] != project {
                let delta = GhostDeltaPayload(
                    projectID: projectID,
                    ghosts: project.ghosts.map(Self.entryState(from:)),
                    projectStatus: metadata(projectID).status
                )
                pendingDeltas[projectID] = delta
                changed = true
            }
        }
        // A removed project also counts as a change — emit a delta with an
        // empty ghosts array so the renderer can drop it.
        for projectID in lastEmittedRoster.keys where roster[projectID] == nil {
            pendingDeltas[projectID] = GhostDeltaPayload(
                projectID: projectID,
                ghosts: [],
                projectStatus: nil
            )
            changed = true
        }
        lastEmittedRoster = roster
        guard changed else { return }
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !pendingFlushScheduled else { return }
        pendingFlushScheduled = true
        coalesceQueue.asyncAfter(deadline: .now() + Self.coalesceWindow) { [weak self] in
            self?.flushPending()
        }
    }

    private func flushPending() {
        let drained = pendingDeltas
        pendingDeltas.removeAll(keepingCapacity: true)
        pendingFlushScheduled = false
        for (_, delta) in drained {
            push(delta: delta)
        }
    }

    // MARK: - Snapshot / delta builders

    private static func entryState(from entry: GhostEntry) -> GhostEntryState {
        return GhostEntryState(
            ghostID: entry.id,
            state: entry.state.rawValue,
            label: entry.label
        )
    }

    private static func buildSnapshot(
        roster: [String: ProjectGhostRoster],
        metadata: (String) -> (name: String, cwd: String, status: String)
    ) -> GhostSnapshotPayload {
        let projects: [GhostProjectState] = roster.keys.sorted().map { projectID in
            let info = metadata(projectID)
            let ghosts = roster[projectID]?.ghosts.map(entryState(from:)) ?? []
            return GhostProjectState(
                projectID: projectID,
                projectName: info.name,
                projectCwd: info.cwd,
                projectStatus: info.status,
                ghosts: ghosts,
                selectedProjectID: nil
            )
        }
        return GhostSnapshotPayload(projects: projects)
    }

    // MARK: - Public push API

    public func push(snapshot: GhostSnapshotPayload) {
        guard let webView = self.webView else { return }
        push(snapshot: snapshot, to: webView)
    }

    public func push(delta: GhostDeltaPayload) {
        guard let webView = self.webView else { return }
        push(delta: delta, to: webView)
    }

    public func push(snapshot: GhostSnapshotPayload, to webView: WKWebView) {
        let envelope = GhostEnvelope(payload: snapshot)
        guard let encoded = try? encoder.encode(envelope),
              let json = String(data: encoded, encoding: .utf8) else {
            #if DEBUG
            dlog("ghost.snapshot encode failed")
            #endif
            return
        }
        // Counter increments at enqueue time so tests can assert determinism
        // without waiting for the main hop.
        counterLock.withLock { $0.snapshots &+= 1 }
        let escaped = Self.jsEscape(json)
        DispatchQueue.main.async {
            webView.evaluateJavaScript(
                "window.__ghostBridge && window.__ghostBridge.onSnapshot('\(escaped)')",
                completionHandler: nil
            )
        }
    }

    public func push(delta: GhostDeltaPayload, to webView: WKWebView) {
        let envelope = GhostEnvelope(payload: delta)
        guard let encoded = try? encoder.encode(envelope),
              let json = String(data: encoded, encoding: .utf8) else {
            #if DEBUG
            dlog("ghost.delta encode failed")
            #endif
            return
        }
        counterLock.withLock { $0.deltas &+= 1 }
        let escaped = Self.jsEscape(json)
        DispatchQueue.main.async {
            webView.evaluateJavaScript(
                "window.__ghostBridge && window.__ghostBridge.onDelta('\(escaped)')",
                completionHandler: nil
            )
        }
    }

    // MARK: - JS escaping

    /// Escape a JSON string for embedding inside a single-quoted JS literal.
    /// JSON forbids raw control bytes, so the only characters we need to
    /// guard are the single-quote, backslash, line terminators, and the
    /// non-newline U+2028 / U+2029 separators that JS treats as line breaks.
    static func jsEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out.append("\\\\")
            case "'":  out.append("\\'")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\u{2028}": out.append("\\u2028")
            case "\u{2029}": out.append("\\u2029")
            default: out.append(Character(scalar))
            }
        }
        return out
    }

    // MARK: - Test seam

    /// Synchronously process a roster diff (skipping the Combine hop) so
    /// unit tests can assert deterministic delta emission without waiting on
    /// the dispatch queue.
    public func ingestRosterForTesting(
        _ roster: [String: ProjectGhostRoster],
        metadata: (String) -> (name: String, cwd: String, status: String) = { pid in (pid, "", "OK") }
    ) {
        coalesceQueue.sync {
            ingestRoster(roster, metadata: metadata)
        }
    }

    /// Synchronously drain coalesced deltas without waiting for the timer.
    public func flushPendingForTesting() {
        coalesceQueue.sync {
            flushPending()
        }
    }
}
