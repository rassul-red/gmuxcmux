import Foundation

/// Versioned envelope for every Swift↔JS bridge message.
///
/// `v` is the protocol version — currently `1`. JS rejects any envelope whose
/// `v` is not equal to 1 with a `console.error` diagnostic.
public struct GhostEnvelope<Payload: Codable>: Codable, Equatable where Payload: Equatable {
    public let v: Int
    public let payload: Payload

    public init(v: Int = 1, payload: Payload) {
        self.v = v
        self.payload = payload
    }
}

// MARK: - ghost.snapshot.v1

public struct GhostSnapshotPayload: Codable, Equatable {
    public let projects: [GhostProjectState]

    public init(projects: [GhostProjectState]) {
        self.projects = projects
    }
}

public struct GhostProjectState: Codable, Equatable {
    public let projectID: String
    public let projectName: String
    public let projectCwd: String
    public let projectStatus: String
    public let ghosts: [GhostEntryState]
    public let selectedProjectID: String?

    public init(
        projectID: String,
        projectName: String,
        projectCwd: String,
        projectStatus: String,
        ghosts: [GhostEntryState],
        selectedProjectID: String? = nil
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.projectCwd = projectCwd
        self.projectStatus = projectStatus
        self.ghosts = ghosts
        self.selectedProjectID = selectedProjectID
    }
}

public struct GhostEntryState: Codable, Equatable {
    public let ghostID: String
    public let state: String
    public let label: String
    /// Epoch milliseconds; nil if the ghost has never recorded activity.
    /// JS consumes this with `new Date(ms)`.
    public let lastActivityAt: Double?

    public init(ghostID: String, state: String, label: String, lastActivityAt: Double? = nil) {
        self.ghostID = ghostID
        self.state = state
        self.label = label
        self.lastActivityAt = lastActivityAt
    }
}

// MARK: - ghost.delta.v1

public struct GhostDeltaPayload: Codable, Equatable {
    public let projectID: String
    public let ghosts: [GhostEntryState]?
    public let projectStatus: String?

    public init(
        projectID: String,
        ghosts: [GhostEntryState]? = nil,
        projectStatus: String? = nil
    ) {
        self.projectID = projectID
        self.ghosts = ghosts
        self.projectStatus = projectStatus
    }
}

// MARK: - ghost.action.v1

public struct GhostActionPayload: Codable, Equatable {
    public let action: String
    public let projectID: String?
    public let data: GhostBridgeAnyCodable?

    public init(
        action: String,
        projectID: String? = nil,
        data: GhostBridgeAnyCodable? = nil
    ) {
        self.action = action
        self.projectID = projectID
        self.data = data
    }
}

/// Minimal `AnyCodable` for opaque action `data` payloads. Holds JSON-native
/// values (Bool/Int/Double/String/Array/Dict/null) and round-trips them via
/// `Codable`.
public struct GhostBridgeAnyCodable: Codable, Equatable {
    public let value: AnyHashable?

    public init(_ value: AnyHashable?) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else if let v = try? container.decode(Bool.self) {
            self.value = v
        } else if let v = try? container.decode(Int.self) {
            self.value = v
        } else if let v = try? container.decode(Double.self) {
            self.value = v
        } else if let v = try? container.decode(String.self) {
            self.value = v
        } else if let v = try? container.decode([GhostBridgeAnyCodable].self) {
            self.value = v.compactMap { $0.value } as [AnyHashable]
        } else if let v = try? container.decode([String: GhostBridgeAnyCodable].self) {
            self.value = v.compactMapValues { $0.value } as [String: AnyHashable]
        } else {
            self.value = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .none:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [AnyHashable]:
            try container.encode(v.map { GhostBridgeAnyCodable($0) })
        case let v as [String: AnyHashable]:
            try container.encode(v.mapValues { GhostBridgeAnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Constants

public enum GhostBridgeMessageName {
    public static let snapshot = "ghost.snapshot.v1"
    public static let delta = "ghost.delta.v1"
    public static let action = "ghost.action.v1"
    public static let metrics = "ghost.bridge.metrics"
}

public enum GhostBridgeAction {
    public static let roomSelect = "roomSelect"
    public static let openProject = "openProject"
    public static let interrupt = "interrupt"
    public static let newTask = "newTask"
    public static let follow = "follow"
    public static let broadcast = "broadcast"
    public static let groupChat = "groupChat"
}
