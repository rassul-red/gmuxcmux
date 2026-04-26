import SwiftUI

/// Live agent status driving sprite + overlay selection in GUI mode.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case running
    case thinking
    case asking
    case completed

    var spriteVariant: AgentSpriteVariant {
        switch self {
        case .running: return .working
        case .thinking: return .idle
        case .asking: return .attention
        case .completed: return .idle
        }
    }

    var isAtDeskStatus: Bool {
        switch self {
        case .running, .asking: return true
        case .thinking, .completed: return false
        }
    }

    var isWandering: Bool {
        switch self {
        case .running, .asking: return false
        case .thinking, .completed: return true
        }
    }

    var overlayGlyph: AgentOverlayGlyph? {
        switch self {
        case .running: return nil
        case .thinking: return .thoughtBubble
        case .asking: return nil
        case .completed: return .completedHalo
        }
    }

    var auraColor: Color {
        switch self {
        case .running: return Color(red: 1.00, green: 0.70, blue: 0.28)
        case .thinking: return Color(red: 0.49, green: 0.85, blue: 1.00)
        case .asking: return Color(red: 1.00, green: 0.36, blue: 0.56)
        case .completed: return Color(red: 0.62, green: 1.00, blue: 0.61)
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
