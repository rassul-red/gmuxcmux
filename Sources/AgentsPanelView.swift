import SwiftUI

/// Right-sidebar panel that renders every workspace as a "room" containing
/// each terminal panel as a clickable "agent" box. Tapping an agent selects
/// the workspace and focuses that terminal.
///
/// Snapshot-boundary rule (`CLAUDE.md`): the row subtree (`AgentsRoomBox`,
/// `AgentBox`) only sees value-type snapshots and closures — never an
/// `ObservableObject` reference. This prevents unrelated `@Published`
/// changes from invalidating every row.
struct AgentsPanelView: View {
    @ObservedObject var tabManager: TabManager
    let onFocusTerminal: (UUID, UUID) -> Void

    var body: some View {
        let rooms = makeRoomSnapshots()
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if rooms.isEmpty {
                    Text(String(localized: "agentsPanel.empty", defaultValue: "No workspaces"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                } else {
                    ForEach(rooms) { room in
                        AgentsRoomBox(snapshot: room, onTapAgent: onFocusTerminal)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("AgentsPanel")
    }

    private func makeRoomSnapshots() -> [AgentsRoomSnapshot] {
        tabManager.tabs.map { workspace in
            let agents: [AgentsAgentSnapshot] = workspace.panels.values
                .compactMap { $0 as? TerminalPanel }
                .map { panel in
                    AgentsAgentSnapshot(
                        id: panel.id,
                        workspaceId: workspace.id,
                        title: panel.displayTitle
                    )
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return AgentsRoomSnapshot(
                id: workspace.id,
                title: workspace.title,
                agents: agents
            )
        }
    }
}

private struct AgentsRoomSnapshot: Identifiable, Equatable {
    let id: UUID
    let title: String
    let agents: [AgentsAgentSnapshot]
}

private struct AgentsAgentSnapshot: Identifiable, Equatable {
    let id: UUID
    let workspaceId: UUID
    let title: String
}

private struct AgentsRoomBox: View, Equatable {
    let snapshot: AgentsRoomSnapshot
    let onTapAgent: (UUID, UUID) -> Void

    static func == (lhs: AgentsRoomBox, rhs: AgentsRoomBox) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            if snapshot.agents.isEmpty {
                Text(String(localized: "agentsPanel.room.empty", defaultValue: "No terminals"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            } else {
                AgentsFlow(items: snapshot.agents) { agent in
                    AgentBox(snapshot: agent, onTap: onTapAgent)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct AgentBox: View, Equatable {
    let snapshot: AgentsAgentSnapshot
    let onTap: (UUID, UUID) -> Void

    static func == (lhs: AgentBox, rhs: AgentBox) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        Button {
            onTap(snapshot.workspaceId, snapshot.id)
        } label: {
            Text(snapshot.title)
                .font(.system(size: 10))
                .foregroundColor(.primary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: 140, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(snapshot.title)
    }
}

/// Simple wrapping flow layout for the agent boxes inside a room.
private struct AgentsFlow<Item: Identifiable & Equatable, ItemView: View>: View {
    let items: [Item]
    let content: (Item) -> ItemView

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items) { item in
                content(item)
            }
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let arrangement = arrange(subviews: subviews, maxWidth: maxWidth)
        return CGSize(width: arrangement.totalSize.width, height: arrangement.totalSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, maxWidth: bounds.width)
        for (index, position) in arrangement.positions.enumerated() {
            let subview = subviews[index]
            let size = subview.sizeThatFits(.unspecified)
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> (positions: [CGPoint], totalSize: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxLineWidth = max(maxLineWidth, x - spacing)
        }
        let totalHeight = y + lineHeight
        return (positions, CGSize(width: maxLineWidth, height: totalHeight))
    }
}
