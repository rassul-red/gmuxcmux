import Foundation
import CoreGraphics

/// Per-panel "where is this ghost standing in its room" state. Owned by
/// `AgentWorldStore`; never written from a SwiftUI body.
struct AgentWorldState: Equatable {
    var position: CGPoint
    var target: CGPoint
    var facingLeft: Bool
    var arrived: Bool
    var nextWanderAt: Date
    var lastTickAt: Date
}

/// Snapshot input describing what each panel should be doing this tick.
struct AgentWorldDriver {
    let panelId: UUID
    let status: AgentStatus
    let roomBounds: CGRect
    let chairPosition: CGPoint
    let seed: UInt64
}

/// Single source of truth for ghost positions and walking targets.
/// The canvas view ticks this once per frame from a `Timer.publish` and
/// then reads `statesByPanelId` to build per-room snapshots.
@MainActor
final class AgentWorldStore: ObservableObject {
    static let shared = AgentWorldStore()

    @Published private(set) var statesByPanelId: [UUID: AgentWorldState] = [:]

    private let walkSpeed: CGFloat = 30
    private let deskWalkSpeed: CGFloat = 120
    private let arrivalEpsilon: CGFloat = 1.5
    private let wanderMinDelay: TimeInterval = 4.0
    private let wanderMaxDelay: TimeInterval = 8.0

    private init() {}

    func clear(panelId: UUID) {
        statesByPanelId.removeValue(forKey: panelId)
    }

    func retainOnly(_ keepIds: Set<UUID>) {
        for id in statesByPanelId.keys where !keepIds.contains(id) {
            statesByPanelId.removeValue(forKey: id)
        }
    }

    func tick(now: Date, drivers: [AgentWorldDriver]) {
        var next = statesByPanelId

        let liveIds = Set(drivers.map { $0.panelId })
        for id in next.keys where !liveIds.contains(id) {
            next.removeValue(forKey: id)
        }

        for driver in drivers {
            let existing = next[driver.panelId]
            var state = existing ?? makeInitialState(for: driver, now: now)

            let dt = max(0, now.timeIntervalSince(state.lastTickAt))
            state.lastTickAt = now

            if driver.status.isAtDeskStatus {
                state.target = driver.chairPosition
            } else if state.arrived, now >= state.nextWanderAt {
                state.target = randomTarget(in: driver.roomBounds, seed: driver.seed, now: now)
                state.nextWanderAt = now.addingTimeInterval(
                    Double.random(in: wanderMinDelay ... wanderMaxDelay)
                )
            } else if existing == nil {
                state.target = randomTarget(in: driver.roomBounds, seed: driver.seed, now: now)
            }

            let dx = state.target.x - state.position.x
            let dy = state.target.y - state.position.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance <= arrivalEpsilon {
                state.position = state.target
                if !state.arrived {
                    state.arrived = true
                    if !driver.status.isAtDeskStatus {
                        state.nextWanderAt = now.addingTimeInterval(
                            Double.random(in: wanderMinDelay ... wanderMaxDelay)
                        )
                    }
                }
            } else {
                let speed = driver.status.isAtDeskStatus ? deskWalkSpeed : walkSpeed
                let step = min(distance, speed * CGFloat(dt))
                let nx = dx / distance
                let ny = dy / distance
                state.position = CGPoint(
                    x: state.position.x + nx * step,
                    y: state.position.y + ny * step
                )
                state.arrived = false
                if abs(dx) > 0.5 {
                    state.facingLeft = dx < 0
                }
            }

            next[driver.panelId] = state
        }

        if next != statesByPanelId {
            statesByPanelId = next
        }
    }

    private func makeInitialState(for driver: AgentWorldDriver, now: Date) -> AgentWorldState {
        let bounds = driver.roomBounds
        let xPad = max(24, bounds.width * 0.1)
        let xRange = max(bounds.minX + xPad, bounds.minX)
        let xMax = max(xRange, bounds.maxX - xPad)
        let seedFraction = Double(driver.seed % 1000) / 1000.0
        let x = xRange + CGFloat(seedFraction) * (xMax - xRange)
        let y = bounds.midY
        let pos = CGPoint(x: x, y: y)
        return AgentWorldState(
            position: pos,
            target: pos,
            facingLeft: false,
            arrived: true,
            nextWanderAt: now,
            lastTickAt: now
        )
    }

    private func randomTarget(in bounds: CGRect, seed: UInt64, now: Date) -> CGPoint {
        let inset = bounds.insetBy(dx: 28, dy: 28)
        guard inset.width > 0, inset.height > 0 else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let x = CGFloat.random(in: inset.minX ... inset.maxX)
        let y = CGFloat.random(in: inset.minY ... inset.maxY)
        return CGPoint(x: x, y: y)
    }
}
