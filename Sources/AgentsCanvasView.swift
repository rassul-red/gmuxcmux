import SwiftUI
import AppKit
import Combine

/// Top-level "game" canvas shown in the center of the window when GUI mode is
/// active. Renders one room per workspace as a horizontal row inside a
/// scrollable, pinch-zoomable world. Agents walk around their rooms when not
/// busy and sit at their desks when running/asking.
///
/// Snapshot-boundary rule (`CLAUDE.md`): row subviews see only immutable value
/// snapshots + closures. World position writes happen exclusively in
/// `AgentWorldStore.tick(...)`, never inside a view body.
struct AgentsCanvasView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject var roleStore: AgentRoleStore
    let onFocusTerminal: (UUID, UUID) -> Void

    @StateObject private var worldStore = AgentWorldStore.shared

    @State private var completedAtByPanelId: [UUID: Date] = [:]
    @State private var lastSeenStatusByPanelId: [UUID: AgentStatus] = [:]
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @AppStorage("agentsCanvas.chimeEnabled") private var chimeEnabled: Bool = true

    private let roomSize = CGSize(width: 720, height: 480)
    private let roomGap: CGFloat = 120
    private let outerPadding: CGFloat = 60
    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 2.5

    private let tickPublisher = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let workspaces = workspaceTabs()
        let rooms = makeRoomSnapshots(for: workspaces)

        ZStack {
            Color(red: 0.04, green: 0.03, blue: 0.06).ignoresSafeArea()

            if rooms.isEmpty {
                emptyState
            } else {
                worldScrollView(rooms: rooms)
            }

            zoomHUD
        }
        .onReceive(tickPublisher) { now in
            advanceWorld(workspaces: workspaces, at: now)
        }
        .onChange(of: rooms) { _, newRooms in
            handleStatusTransitions(in: newRooms)
        }
        .onAppear {
            primeStatusBaseline(rooms: rooms)
        }
        .accessibilityIdentifier("AgentsCanvas")
    }

    // MARK: - Subviews

    private func worldScrollView(rooms: [AgentsCanvasRoomSnapshot]) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            HStack(alignment: .top, spacing: roomGap) {
                ForEach(rooms) { room in
                    AgentsCanvasRoomView(
                        snapshot: room,
                        now: Date(),
                        completedAtByPanelId: completedAtByPanelId,
                        onTapAgent: onFocusTerminal,
                        onSetRole: { panelId, role in
                            roleStore.setRole(role, for: panelId)
                        }
                    )
                    .equatable()
                }
            }
            .padding(outerPadding)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(
                width: worldContentWidth(roomCount: rooms.count) * zoom,
                height: worldContentHeight() * zoom,
                alignment: .topLeading
            )
        }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    zoom = clampZoom(baseZoom * value)
                }
                .onEnded { _ in
                    baseZoom = zoom
                }
        )
        .accessibilityIdentifier("AgentsCanvas.World")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(String(localized: "agentsCanvas.empty.title", defaultValue: "No workspaces yet"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
            Text(String(localized: "agentsCanvas.empty.subtitle", defaultValue: "Open a workspace to see its agents."))
                .font(.system(size: 11))
                .foregroundColor(Color.secondary.opacity(0.7))
        }
    }

    private var zoomHUD: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    zoomButton(
                        title: "−",
                        accessibility: String(localized: "agentsCanvas.zoom.out", defaultValue: "Zoom out"),
                        action: { zoom = clampZoom(zoom - 0.1); baseZoom = zoom }
                    )
                    Text(zoomLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(minWidth: 36)
                    zoomButton(
                        title: "+",
                        accessibility: String(localized: "agentsCanvas.zoom.in", defaultValue: "Zoom in"),
                        action: { zoom = clampZoom(zoom + 0.1); baseZoom = zoom }
                    )
                    Divider()
                        .frame(height: 14)
                        .background(Color.white.opacity(0.15))
                    Button {
                        zoom = 1.0
                        baseZoom = 1.0
                    } label: {
                        Text("⌘0")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "agentsCanvas.zoom.reset", defaultValue: "Reset zoom"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.08, green: 0.08, blue: 0.12).opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
                .padding(12)
            }
        }
    }

    private func zoomButton(title: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(accessibility)
        .accessibilityLabel(accessibility)
    }

    private var zoomLabel: String {
        "\(Int(zoom * 100))%"
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        return min(max(value, minZoom), maxZoom)
    }

    private func worldContentWidth(roomCount: Int) -> CGFloat {
        guard roomCount > 0 else { return roomSize.width + outerPadding * 2 }
        let rooms = CGFloat(roomCount)
        return rooms * roomSize.width + (rooms - 1) * roomGap + outerPadding * 2
    }

    private func worldContentHeight() -> CGFloat {
        roomSize.height + 32 + outerPadding * 2
    }

    // MARK: - World tick

    /// One-frame advance: build drivers from current workspace state, hand to
    /// the store. The store mutates its `@Published` state; the next render
    /// reads from `worldStore.statesByPanelId`.
    private func advanceWorld(workspaces: [Workspace], at now: Date) {
        var drivers: [AgentWorldDriver] = []
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let panels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            let sortedPanels = panels.sorted { lhs, rhs in
                lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
            for (panelIndex, panel) in sortedPanels.enumerated() {
                let panelId = panel.id
                let status = currentStatus(forWorkspace: workspace, panelId: panelId)
                let bounds = roomLocalBounds()
                let desk = deskPosition(forPanelIndex: panelIndex)
                let seed = stableSeed(workspaceIndex: workspaceIndex, panelIndex: panelIndex, panelId: panelId)
                drivers.append(AgentWorldDriver(
                    panelId: panelId,
                    status: status,
                    roomBounds: bounds,
                    deskPosition: desk,
                    seed: seed
                ))
            }
        }
        worldStore.tick(now: now, drivers: drivers)
    }

    private func currentStatus(forWorkspace workspace: Workspace, panelId: UUID) -> AgentStatus {
        let hasNotification = notificationStore.hasVisibleNotificationIndicator(
            forTabId: workspace.id,
            surfaceId: panelId
        )
        if hasNotification {
            return .completed
        }
        // Only sit at the desk when the shell is actually running a command —
        // i.e. the user has typed/launched something. Bare focus (a freshly
        // created terminal sitting at the prompt) means the agent should still
        // wander.
        let activity = workspace.panelShellActivityState(forPanelId: panelId)
        if activity == .commandRunning {
            return .running
        }
        return .thinking
    }

    /// Wander zone — the open central floor area where ghosts roam. Excludes
    /// the perimeter where furniture (desks, bookshelves, side tables) sits.
    /// Pixel-art top-down convention: y grows down, so this carves out the
    /// strip between the mid-row desks and the bottom decorations.
    private func roomLocalBounds() -> CGRect {
        CGRect(x: 80, y: 320, width: roomSize.width - 160, height: 90)
    }

    /// Fixed seat slots in every room. Each slot is the position where a
    /// seated ghost sits (the chair position, not the desk top). Furniture
    /// drawn by `roomFurniture` aligns with these.
    private static let chairSlots: [CGPoint] = [
        CGPoint(x: 180, y: 173),   // top-left desk, chair below
        CGPoint(x: 540, y: 173),   // top-right desk, chair below
        CGPoint(x: 180, y: 283),   // mid-left desk, chair below
        CGPoint(x: 540, y: 283),   // mid-right desk, chair below
    ]

    private func deskPosition(forPanelIndex panelIndex: Int) -> CGPoint {
        let slots = Self.chairSlots
        return slots[panelIndex % slots.count]
    }

    private func stableSeed(workspaceIndex: Int, panelIndex: Int, panelId: UUID) -> UInt64 {
        let raw = panelId.uuidString.hashValue
        return UInt64(bitPattern: Int64(raw)) &+ UInt64(workspaceIndex * 1000 + panelIndex)
    }

    // MARK: - Snapshot building

    private func workspaceTabs() -> [Workspace] {
        Array(tabManager.tabs)
    }

    private func makeRoomSnapshots(for workspaces: [Workspace]) -> [AgentsCanvasRoomSnapshot] {
        let palette: [Color] = [
            Color(red: 1.00, green: 0.70, blue: 0.28).opacity(0.7),
            Color(red: 0.37, green: 0.72, blue: 1.00).opacity(0.7),
            Color(red: 0.72, green: 0.60, blue: 0.85).opacity(0.7),
            Color(red: 0.37, green: 1.00, blue: 0.54).opacity(0.7),
            Color(red: 1.00, green: 0.55, blue: 0.78).opacity(0.7),
            Color(red: 0.99, green: 0.95, blue: 0.42).opacity(0.7),
        ]
        let states = worldStore.statesByPanelId

        return workspaces.enumerated().map { index, workspace in
            let panels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            let sorted = panels.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
            let bounds = roomLocalBounds()
            let agents: [AgentsCanvasAgentSnapshot] = sorted.enumerated().map { panelIndex, panel in
                let panelId = panel.id
                let status = currentStatus(forWorkspace: workspace, panelId: panelId)
                let desk = deskPosition(forPanelIndex: panelIndex)
                let state = states[panelId]
                let pos = state?.position ?? desk
                let arrived = state?.arrived ?? true
                let facingLeft = state?.facingLeft ?? false
                let isAtDesk = status.isAtDeskStatus
                let isWalking = !arrived
                return AgentsCanvasAgentSnapshot(
                    id: panelId,
                    workspaceId: workspace.id,
                    title: panel.displayTitle,
                    role: roleStore.role(for: panelId),
                    status: status,
                    worldPosition: pos,
                    deskPosition: desk,
                    facingLeft: facingLeft,
                    isAtDesk: isAtDesk,
                    isWalking: isWalking
                )
            }

            return AgentsCanvasRoomSnapshot(
                id: workspace.id,
                title: workspace.title,
                accentColor: palette[index % palette.count],
                roomSize: roomSize,
                decorations: Self.roomFurniture,
                agents: agents
            )
        }
    }

    /// Fixed office furniture layout — every room shares the same arrangement
    /// (desks pre-built into the room, perimeter decorations, central floor
    /// open for wandering). Order matters for layering: floor-level pieces
    /// first, then taller pieces, so e.g. a chair behind a desk reads
    /// correctly. Chairs are intentionally rendered before the seated ghost
    /// (the ghost is drawn separately as an agent), and monitors/lamps after
    /// the desk so they sit "on" the desk surface.
    static let roomFurniture: [AgentRoomDecoration] = {
        // Helpers to produce deterministic UUIDs by index.
        func id(_ slot: Int) -> UUID {
            let hex = String(format: "%012x", 0xF1F00000 &+ slot)
            return UUID(uuidString: "00000000-0000-0000-0000-\(hex)") ?? UUID()
        }

        var pieces: [AgentRoomDecoration] = []
        var slot = 0
        func add(_ kind: AgentRoomDecorationKind, _ x: CGFloat, _ y: CGFloat) {
            pieces.append(AgentRoomDecoration(id: id(slot), kind: kind, position: CGPoint(x: x, y: y)))
            slot += 1
        }

        // Top wall (back wall) — bookshelf, wall task board, server rack.
        add(.bookshelf, 60, 80)
        add(.taskBoard, 360, 50)
        add(.serverRack, 675, 85)

        // Top-left desk station (chair at chairSlots[0] = 180, 173).
        add(.officeChair, 180, 180)
        add(.desk, 180, 130)
        add(.terminalMonitor, 180, 108)
        add(.deskLamp, 220, 108)
        add(.coffeeMug, 145, 124)
        add(.keyboard, 180, 142)

        // Top-right desk station (chair at 540, 173).
        add(.officeChair, 540, 180)
        add(.desk, 540, 130)
        add(.terminalMonitor, 540, 108)
        add(.deskLamp, 580, 108)
        add(.coffeeMug, 505, 124)
        add(.keyboard, 540, 142)

        // Plants between top desks.
        add(.pottedPlant, 290, 115)
        add(.pottedPlant, 430, 115)

        // Mid-left desk station (chair at 180, 283).
        add(.officeChair, 180, 290)
        add(.desk, 180, 240)
        add(.terminalMonitor, 180, 218)
        add(.deskLamp, 220, 218)
        add(.coffeeMug, 145, 234)
        add(.keyboard, 180, 252)

        // Mid-right desk station (chair at 540, 283).
        add(.officeChair, 540, 290)
        add(.desk, 540, 240)
        add(.terminalMonitor, 540, 218)
        add(.deskLamp, 580, 218)
        add(.coffeeMug, 505, 234)
        add(.keyboard, 540, 252)

        // Side-wall floor lamps flanking the open central floor.
        add(.floorLamp, 35, 360)
        add(.floorLamp, 685, 360)

        // Bottom strip — storage cabinet, side tables, plants.
        add(.storageCabinet, 60, 435)
        add(.pottedPlant, 135, 430)
        add(.sideTable, 360, 435)
        add(.pottedPlant, 295, 430)
        add(.pottedPlant, 425, 430)
        add(.sideTable, 660, 435)
        add(.pottedPlant, 595, 430)

        return pieces
    }()

    // MARK: - Status transition tracking

    private func primeStatusBaseline(rooms: [AgentsCanvasRoomSnapshot]) {
        var seen: [UUID: AgentStatus] = [:]
        for room in rooms {
            for agent in room.agents { seen[agent.id] = agent.status }
        }
        lastSeenStatusByPanelId = seen
    }

    private func handleStatusTransitions(in rooms: [AgentsCanvasRoomSnapshot]) {
        var nextSeen: [UUID: AgentStatus] = [:]
        var newlyCompleted: [UUID] = []
        let now = Date()

        for room in rooms {
            for agent in room.agents {
                nextSeen[agent.id] = agent.status
                let previous = lastSeenStatusByPanelId[agent.id]
                if agent.status == .completed && previous != .completed {
                    newlyCompleted.append(agent.id)
                }
            }
        }

        var nextCompletedAt = completedAtByPanelId
        for (panelId, _) in nextCompletedAt {
            if nextSeen[panelId] != .completed {
                nextCompletedAt.removeValue(forKey: panelId)
            }
        }
        for panelId in newlyCompleted {
            nextCompletedAt[panelId] = now
        }

        completedAtByPanelId = nextCompletedAt
        lastSeenStatusByPanelId = nextSeen

        if !newlyCompleted.isEmpty, chimeEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }
}

// MARK: - Snapshot value types

struct AgentsCanvasRoomSnapshot: Identifiable, Equatable {
    let id: UUID
    let title: String
    let accentColor: Color
    let roomSize: CGSize
    let decorations: [AgentRoomDecoration]
    let agents: [AgentsCanvasAgentSnapshot]
}

struct AgentsCanvasAgentSnapshot: Identifiable, Equatable {
    let id: UUID
    let workspaceId: UUID
    let title: String
    let role: AgentRole
    let status: AgentStatus
    let worldPosition: CGPoint
    let deskPosition: CGPoint
    let facingLeft: Bool
    let isAtDesk: Bool
    let isWalking: Bool
}

enum AgentRoomDecorationKind: String, Equatable, Sendable {
    case bookshelf
    case pottedPlant
    case floorLamp
    case sideTable
    case taskBoard
    case desk
    case officeChair
    case deskLamp
    case keyboard
    case terminalMonitor
    case coffeeMug
    case serverRack
    case storageCabinet

    var assetName: String {
        switch self {
        case .bookshelf: return "OfficePropBookshelf"
        case .pottedPlant: return "OfficePropPottedPlant"
        case .floorLamp: return "OfficePropFloorLamp"
        case .sideTable: return "OfficePropSideTable"
        case .taskBoard: return "OfficePropTaskBoard"
        case .desk: return "OfficePropDesk"
        case .officeChair: return "OfficePropOfficeChair"
        case .deskLamp: return "OfficePropDeskLamp"
        case .keyboard: return "OfficePropKeyboard"
        case .terminalMonitor: return "OfficePropTerminalMonitor"
        case .coffeeMug: return "OfficePropCoffeeMug"
        case .serverRack: return "OfficePropServerRack"
        case .storageCabinet: return "OfficePropStorageCabinet"
        }
    }

    /// Render size for this decoration (points).
    var size: CGSize {
        switch self {
        case .bookshelf: return CGSize(width: 88, height: 110)
        case .pottedPlant: return CGSize(width: 48, height: 60)
        case .floorLamp: return CGSize(width: 40, height: 88)
        case .sideTable: return CGSize(width: 64, height: 56)
        case .taskBoard: return CGSize(width: 96, height: 64)
        case .desk: return CGSize(width: 110, height: 56)
        case .officeChair: return CGSize(width: 44, height: 44)
        case .deskLamp: return CGSize(width: 28, height: 36)
        case .keyboard: return CGSize(width: 56, height: 16)
        case .terminalMonitor: return CGSize(width: 60, height: 40)
        case .coffeeMug: return CGSize(width: 18, height: 20)
        case .serverRack: return CGSize(width: 56, height: 110)
        case .storageCabinet: return CGSize(width: 88, height: 60)
        }
    }
}

struct AgentRoomDecoration: Identifiable, Equatable {
    let id: UUID
    let kind: AgentRoomDecorationKind
    let position: CGPoint
}
