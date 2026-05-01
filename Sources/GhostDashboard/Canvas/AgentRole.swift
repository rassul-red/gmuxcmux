import SwiftUI

/// Pixel-art role classes for the GUI mode "ghost" agents.
/// Each role corresponds to a set of Idle/Working/Attention sprites in
/// `Assets.xcassets/AgentWorkers/`.
public enum AgentRole: String, Codable, CaseIterable, Sendable, Identifiable {
    case builder
    case debugger
    case orchestrator
    case reviewer

    public var id: String { rawValue }

    var assetPrefix: String {
        switch self {
        case .builder: return "AgentWorkerBuilder"
        case .debugger: return "AgentWorkerDebugger"
        case .orchestrator: return "AgentWorkerOrchestrator"
        case .reviewer: return "AgentWorkerReviewer"
        }
    }

    var assetCoreName: String {
        switch self {
        case .builder: return "Builder"
        case .debugger: return "Debugger"
        case .orchestrator: return "Orchestrator"
        case .reviewer: return "Reviewer"
        }
    }

    var localizedName: String {
        switch self {
        case .builder:
            return String(localized: "agentsCanvas.role.builder", defaultValue: "Builder")
        case .debugger:
            return String(localized: "agentsCanvas.role.debugger", defaultValue: "Debugger")
        case .orchestrator:
            return String(localized: "agentsCanvas.role.orchestrator", defaultValue: "Orchestrator")
        case .reviewer:
            return String(localized: "agentsCanvas.role.reviewer", defaultValue: "Reviewer")
        }
    }

    var roleDescription: String {
        switch self {
        case .builder:
            return String(localized: "agentsCanvas.role.builder.desc", defaultValue: "Implements features, writes code")
        case .debugger:
            return String(localized: "agentsCanvas.role.debugger.desc", defaultValue: "Hunts bugs, traces execution")
        case .orchestrator:
            return String(localized: "agentsCanvas.role.orchestrator.desc", defaultValue: "Coordinates agents, plans work")
        case .reviewer:
            return String(localized: "agentsCanvas.role.reviewer.desc", defaultValue: "Reads diffs, validates output")
        }
    }

    var accentColor: Color {
        switch self {
        case .builder: return Color(red: 1.00, green: 0.70, blue: 0.28)
        case .debugger: return Color(red: 0.37, green: 1.00, blue: 0.54)
        case .orchestrator: return Color(red: 0.72, green: 0.60, blue: 0.85)
        case .reviewer: return Color(red: 0.37, green: 0.72, blue: 1.00)
        }
    }

    var glowColor: Color {
        switch self {
        case .builder: return Color(red: 1.00, green: 0.82, blue: 0.48)
        case .debugger: return Color(red: 0.62, green: 1.00, blue: 0.61)
        case .orchestrator: return Color(red: 0.83, green: 0.72, blue: 1.00)
        case .reviewer: return Color(red: 0.49, green: 0.85, blue: 1.00)
        }
    }

    var bouncePeriod: Double {
        2.4 + Double(rawValue.count % 3) * 0.2
    }

    static let defaultRole: AgentRole = .builder
}
