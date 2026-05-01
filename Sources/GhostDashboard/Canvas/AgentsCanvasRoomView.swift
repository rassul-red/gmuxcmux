import SwiftUI

/// One "room" in the GUI canvas. Renders a fixed-size office scene plus
/// ghost agents at their world-store positions.
struct AgentsCanvasRoomView: View, Equatable {
    let snapshot: AgentsCanvasRoomSnapshot
    let now: Date
    let completedAtByPanelId: [UUID: Date]
    let onTapAgent: (UUID, UUID) -> Void
    let onSetRole: (UUID, AgentRole) -> Void

    static func == (lhs: AgentsCanvasRoomView, rhs: AgentsCanvasRoomView) -> Bool {
        lhs.snapshot == rhs.snapshot &&
            lhs.completedAtByPanelId == rhs.completedAtByPanelId
    }

    var body: some View {
        let size = snapshot.roomSize
        VStack(alignment: .leading, spacing: 6) {
            header
            content
                .frame(width: size.width, height: size.height)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(snapshot.title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(snapshot.accentColor.opacity(0.32))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(snapshot.accentColor, lineWidth: 1)
                        )
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: snapshot.roomSize.width, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        let size = snapshot.roomSize
        ZStack {
            officeFloor

            Image("OfficePropFloorRug")
                .resizable()
                .interpolation(.none)
                .frame(width: size.width * 0.55, height: size.height * 0.45)
                .opacity(0.9)
                .position(x: size.width / 2, y: size.height / 2)

            ForEach(snapshot.decorations) { deco in
                Image(deco.kind.assetName)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: deco.kind.size.width, height: deco.kind.size.height)
                    .position(x: deco.position.x, y: deco.position.y)
            }

            if snapshot.agents.isEmpty {
                Text(String(localized: "agentsCanvas.room.empty", defaultValue: "no agents in this room"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.30))
                    .tracking(1)
                    .position(x: size.width / 2, y: size.height / 2)
            } else {
                ForEach(snapshot.agents) { agent in
                    AgentAvatarView(
                        snapshot: agent,
                        completedAt: completedAtByPanelId[agent.id],
                        onTap: { onTapAgent(agent.workspaceId, agent.id) },
                        onSetRole: { role in onSetRole(agent.id, role) }
                    )
                    .equatable()
                    .position(x: agent.worldPosition.x, y: agent.worldPosition.y)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(snapshot.accentColor.opacity(0.30), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var officeFloor: some View {
        let accent = snapshot.accentColor
        return Canvas { context, size in
            let baseColor = Color(red: 0.08, green: 0.07, blue: 0.11)
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(baseColor)
            )
            context.fill(
                Path(CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height * 0.45))),
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.16), accent.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height * 0.45)
                )
            )
            let tile: CGFloat = 48
            var x: CGFloat = 0
            while x < size.width {
                let line = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(Color.white.opacity(0.025)), lineWidth: 1)
                x += tile
            }
            var y: CGFloat = 0
            while y < size.height {
                let line = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(line, with: .color(Color.white.opacity(0.022)), lineWidth: 1)
                y += tile
            }
        }
    }
}
