import SwiftUI

/// One "room" in the GUI canvas. Renders room-local props and ghost agents
/// over the shared 2x2 office background. World ticks happen in
/// `AgentWorldStore` (not here) — this view only reads value snapshots.
struct AgentsCanvasRoomView: View, Equatable {
    let snapshot: AgentsCanvasRoomSnapshot
    let now: Date
    let completedAtByPanelId: [UUID: Date]
    let onTapAgent: (UUID, UUID) -> Void
    let onSetRole: (UUID, AgentRole) -> Void

    static func == (lhs: AgentsCanvasRoomView, rhs: AgentsCanvasRoomView) -> Bool {
        // `now` is excluded — agent animations tick via internal TimelineViews.
        lhs.snapshot == rhs.snapshot &&
            lhs.completedAtByPanelId == rhs.completedAtByPanelId
    }

    var body: some View {
        let size = snapshot.roomSize
        ZStack(alignment: .topLeading) {
            content
                .frame(width: size.width, height: size.height)
            header
        }
        .frame(width: size.width, height: size.height)
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
        .offset(x: 8, y: -24)
        .zIndex(1)
    }

    @ViewBuilder
    private var content: some View {
        let size = snapshot.roomSize
        ZStack {
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
    }
}
