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

/// Deterministic mapping from a Claude Code `tool_use.name` to a `GhostState`,
/// plus a 60-second idle collapse.
///
/// Thread-safety: callers are expected to live on a single private serial
/// queue (the watcher's parser queue). The struct itself has no locks.
public struct GhostStateMachine: Sendable {
    /// Idle threshold (seconds) — must match the seed AC.
    public static let idleThreshold: TimeInterval = 60

    private var lastState: GhostState
    private var lastActivityAt: Date?

    public init(initialState: GhostState = .Idle) {
        self.lastState = initialState
        self.lastActivityAt = nil
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

    /// Records a new tool_use event and returns the resulting state.
    @discardableResult
    public mutating func apply(toolName: String, at timestamp: Date) -> GhostState {
        let mapped = Self.mapToolName(toolName)
        lastState = mapped
        lastActivityAt = timestamp
        return mapped
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

    public var lastActivity: Date? { lastActivityAt }
}
