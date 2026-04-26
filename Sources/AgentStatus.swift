import SwiftUI

/// Live agent status driving sprite + overlay selection in GUI mode.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case running
    case thinking
    case asking
    case completed

    /// Which of the three sprite variants (Idle/Working/Attention) to render
    /// for the **standing** ghost. Used when the agent is wandering / idle.
    var spriteVariant: AgentSpriteVariant {
        switch self {
        case .running: return .working
        case .thinking: return .idle
        case .asking: return .attention
        case .completed: return .idle
        }
    }

    /// Which sprite variant to render when the agent is **at its desk**
    /// (composed `AgentDesk{Role}{State}` asset). Wandering states never
    /// trigger this — they always use `spriteVariant` instead.
    var seatedSpriteVariant: AgentSpriteVariant {
        switch self {
        case .running: return .working
        case .asking: return .attention
        case .thinking: return .idle
        case .completed: return .idle
        }
    }

    /// Whether this status keeps the agent seated at a desk in the room.
    /// Wandering states (`thinking`, `completed`) explicitly are not at-desk.
    var isAtDeskStatus: Bool {
        switch self {
        case .running, .asking: return true
        case .thinking, .completed: return false
        }
    }

    /// Whether the ghost should wander horizontally (alive-but-resting feel).
    var isWandering: Bool {
        switch self {
        case .running, .asking: return false
        case .thinking, .completed: return true
        }
    }

    /// Optional overlay glyph drawn on top of the sprite.
    var overlayGlyph: AgentOverlayGlyph? {
        switch self {
        case .running: return nil
        case .thinking: return .thoughtBubble
        case .asking: return nil
        case .completed: return .completedHalo
        }
    }

    /// Aura color for the radial halo behind the sprite. Independent of role tint.
    var auraColor: Color {
        switch self {
        case .running: return Color(red: 1.00, green: 0.70, blue: 0.28)   // #ffb347
        case .thinking: return Color(red: 0.49, green: 0.85, blue: 1.00)  // #7dd9ff
        case .asking: return Color(red: 1.00, green: 0.36, blue: 0.56)    // #ff5d8f
        case .completed: return Color(red: 0.62, green: 1.00, blue: 0.61) // #9eff9c
        }
    }

    var pillLabel: String {
        switch self {
        case .running:
            return String(localized: "agentsCanvas.status.running", defaultValue: "RUNNING")
        case .thinking:
            return String(localized: "agentsCanvas.status.thinking", defaultValue: "THINKING")
        case .asking:
            return String(localized: "agentsCanvas.status.asking", defaultValue: "ASKING")
        case .completed:
            return String(localized: "agentsCanvas.status.completed", defaultValue: "DONE")
        }
    }
}

enum AgentSpriteVariant: String {
    case idle = "Idle"
    case working = "Working"
    case attention = "Attention"
}

enum AgentOverlayGlyph {
    case thoughtBubble
    case completedHalo
}
