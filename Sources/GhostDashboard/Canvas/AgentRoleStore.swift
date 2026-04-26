import Foundation
import Combine

/// Persists the `AgentRole` selection for each terminal panel.
@MainActor
final class AgentRoleStore: ObservableObject {
    static let shared = AgentRoleStore()

    @Published private(set) var rolesByPanelId: [UUID: AgentRole] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func role(for panelId: UUID) -> AgentRole {
        rolesByPanelId[panelId] ?? AgentRole.defaultRole
    }

    func setRole(_ role: AgentRole, for panelId: UUID) {
        if rolesByPanelId[panelId] == role { return }
        rolesByPanelId[panelId] = role
        scheduleSave()
    }

    func clear(panelId: UUID) {
        guard rolesByPanelId.removeValue(forKey: panelId) != nil else { return }
        scheduleSave()
    }

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("cmux", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent-roles.json", isDirectory: false)
    }

    private struct DiskFormat: Codable {
        var rolesByPanelId: [String: String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DiskFormat.self, from: data)
        else { return }

        var result: [UUID: AgentRole] = [:]
        for (key, value) in decoded.rolesByPanelId {
            guard let id = UUID(uuidString: key),
                  let role = AgentRole(rawValue: value) else { continue }
            result[id] = role
        }
        rolesByPanelId = result
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = rolesByPanelId
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let payload = DiskFormat(
                rolesByPanelId: Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key.uuidString, $0.value.rawValue) })
            )
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
}
