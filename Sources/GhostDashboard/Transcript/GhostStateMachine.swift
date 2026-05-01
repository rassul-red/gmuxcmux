import Foundation

/// Eight visible ghost states. Raw values are stable strings used by the
/// WebView bridge (Task #3).
public enum GhostState: String, Codable, Equatable, Sendable {
    case Coding
    case Reviewing
    case Reading
    case Idle
    case Checking
    case Deploying
    case Monitoring
    case Testing
}

/// Lifecycle phase of a ghost — orthogonal to `GhostState` (which describes
/// *what* the ghost is doing). Lifecycle drives the renderer's animation
/// selection per Issue #14:
///
///   • `walking`   — spawned ghost walking to its desk after a new tab
///   • `working`   — at the desk, animating per `GhostState`
///   • `idle`      — at the desk, idle pose (no activity for `idleThreshold`)
///   • `warning`   — needs human intervention (error / question)
///   • `despawning` — final tick before the ghost disappears (tab closed)
public enum GhostLifecycle: String, Codable, Equatable, Sendable {
    case walking
    case working
    case idle
    case warning
    case despawning

    /// Default lifecycle derived from a `GhostState`. Used when no explicit
    /// lifecycle has been set (e.g. before warning detection or spawn/despawn
    /// transitions kick in).
    public static func from(state: GhostState) -> GhostLifecycle {
        return state == .Idle ? .idle : .working
    }
}

/// Result of applying one `tool_use` event to a `GhostStateMachine`.
///
/// `didLaunch` is the "agent launched in this terminal tab" signal that
/// drives issue #17's walk-to-free-table behaviour. It is `true` when the
/// previous observed state was `.Idle` (either no prior activity, or the 60s
/// idle threshold had collapsed the session) and the new event lands a
/// non-`.Idle` state. The roster layer turns this into a table assignment
/// and the JS overlay turns the assignment into a walking animation.
public struct GhostStateApplyResult: Equatable, Sendable {
    public let state: GhostState
    public let didLaunch: Bool
}

/// Deterministic mapping from a Claude Code `tool_use.name` to a `GhostState`,
/// plus a 60-second idle collapse.
///
/// Thread-safety: callers are expected to live on a single private serial
/// queue (the watcher's parser queue). The struct itself has no locks.
public struct GhostStateMachine: Sendable {
    /// Idle threshold (seconds) — must match the seed AC.
    public static let idleThreshold: TimeInterval = 60

    /// Walking-on-spawn duration: how long a freshly spawned ghost should
    /// linger in the `.walking` lifecycle before transitioning to its
    /// state-derived lifecycle. Issue #14: "newly created terminal tab
    /// creates a walking ghost".
    public static let walkingDuration: TimeInterval = 3.0

    private var lastState: GhostState
    private var lastActivityAt: Date?
    private var spawnedAt: Date?
    private var warningRaisedAt: Date?

    public init(initialState: GhostState = .Idle) {
        self.lastState = initialState
        self.lastActivityAt = nil
        self.spawnedAt = nil
        self.warningRaisedAt = nil
    }

    /// Maps a `tool_use.name` to a `GhostState`. Pure / testable.
    public static func mapToolName(_ name: String) -> GhostState {
        switch name {
        case "Read", "Glob", "Grep":
            return .Reading
        case "Edit", "Write":
            return .Coding
        case "Bash":
            return .Checking
        case "WebFetch", "WebSearch":
            return .Reviewing
        case "Task":
            return .Monitoring
        case "Skill":
            return .Reviewing
        default:
            if name.hasPrefix("mcp__") {
                return .Monitoring
            }
            return .Coding
        }
    }

    /// Records a new tool_use event and returns the resulting state plus a
    /// `didLaunch` flag (true if this event woke the session up from Idle).
    /// Fresh activity also auto-clears any active warning — the agent has
    /// resumed working, so the warning lifecycle no longer applies.
    @discardableResult
    public mutating func apply(toolName: String, at timestamp: Date) -> GhostStateApplyResult {
        let priorState = currentState(now: timestamp)
        let mapped = Self.mapToolName(toolName)
        lastState = mapped
        lastActivityAt = timestamp
        warningRaisedAt = nil
        if spawnedAt == nil {
            spawnedAt = timestamp
        }
        let didLaunch = priorState == .Idle && mapped != .Idle
        return GhostStateApplyResult(state: mapped, didLaunch: didLaunch)
    }

    /// Mark this ghost as freshly spawned (e.g. on first observation of a
    /// session before any tool_use lands). Drives the `.walking` lifecycle.
    public mutating func markSpawned(at timestamp: Date) {
        if spawnedAt == nil {
            spawnedAt = timestamp
        }
    }

    /// Raise a warning that the ghost needs human intervention. The warning
    /// remains active until cleared via `clearWarning()` or until a fresh
    /// `tool_use` event lands (which implies the agent has resumed working).
    public mutating func raiseWarning(at timestamp: Date) {
        warningRaisedAt = timestamp
    }

    public mutating func clearWarning() {
        warningRaisedAt = nil
    }

    /// Most recently mapped state. The setter is internal — go through `apply`.
    public var rawState: GhostState { lastState }

    /// State observed by callers. Collapses to `.Idle` when no `tool_use` has
    /// fired in the last `idleThreshold` seconds.
    public func currentState(now: Date = Date()) -> GhostState {
        guard let last = lastActivityAt else { return .Idle }
        if now.timeIntervalSince(last) > Self.idleThreshold {
            return .Idle
        }
        return lastState
    }

    /// Lifecycle phase resolved from spawn/warning/state at `now`.
    public func currentLifecycle(now: Date = Date()) -> GhostLifecycle {
        if warningRaisedAt != nil {
            return .warning
        }
        if let spawned = spawnedAt,
           now.timeIntervalSince(spawned) < Self.walkingDuration {
            return .walking
        }
        return GhostLifecycle.from(state: currentState(now: now))
    }

    public var lastActivity: Date? { lastActivityAt }
    public var spawnTime: Date? { spawnedAt }
    public var warningTime: Date? { warningRaisedAt }
}
