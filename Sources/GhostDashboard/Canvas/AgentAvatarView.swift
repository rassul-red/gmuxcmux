import SwiftUI

/// One ghost agent on the canvas. Animation is purely cosmetic;
/// world-position writes happen in `AgentWorldStore.tick(...)`, never here.
struct AgentAvatarView: View, Equatable {
    let snapshot: AgentsCanvasAgentSnapshot
    let completedAt: Date?
    let onTap: () -> Void
    let onSetRole: (AgentRole) -> Void

    static let avatarSize: CGFloat = 64
    static let seatedSize: CGFloat = 64

    static func == (lhs: AgentAvatarView, rhs: AgentAvatarView) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.completedAt == rhs.completedAt
    }

    var body: some View {
        let frame = snapshot.isAtDesk ? Self.seatedSize : Self.avatarSize
        VStack(spacing: 4) {
            avatarStack
                .frame(width: frame, height: frame)
            label
        }
        .frame(width: frame + 36)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu { roleMenu }
        .help(snapshot.title)
        .accessibilityIdentifier("AgentAvatar.\(snapshot.id.uuidString)")
    }

    private var avatarStack: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let bob = computeBob(at: elapsed)
            let pulse = computePulse(at: elapsed)
            let jiggle = computeWalkJiggle(at: elapsed)
            let frame = snapshot.isAtDesk ? Self.seatedSize : Self.avatarSize
            ZStack {
                halo(pulse: pulse, frame: frame)
                spriteImage
                    .resizable()
                    .interpolation(.none)
                    .frame(width: frame, height: frame)
                    .scaleEffect(x: snapshot.facingLeft && !snapshot.isAtDesk ? -1 : 1, y: 1)
                if snapshot.status.overlayGlyph == .completedHalo {
                    completedHalo(pulse: pulse, frame: frame)
                }
                if snapshot.status.overlayGlyph == .thoughtBubble {
                    thoughtBubble
                        .offset(x: frame * 0.30, y: -frame * 0.42)
                }
                if shouldShowDoneBubble(at: timeline.date) {
                    doneBubble
                        .offset(y: -frame * 0.62)
                        .transition(.opacity)
                }
            }
            .offset(x: 0, y: bob + jiggle)
        }
    }

    private var spriteImage: Image {
        let assetName = "\(snapshot.role.assetPrefix)\(snapshot.status.spriteVariant.rawValue)"
        return Image(assetName)
    }

    private func halo(pulse: Double, frame: CGFloat) -> some View {
        let aura = snapshot.status.auraColor
        let radius = frame * (0.55 + 0.05 * pulse)
        return RadialGradient(
            colors: [aura.opacity(0.33), aura.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
        .blur(radius: 4)
        .frame(width: radius * 2, height: radius * 2)
    }

    private func completedHalo(pulse: Double, frame: CGFloat) -> some View {
        let auraSize = frame * (0.95 + 0.06 * pulse)
        return Circle()
            .stroke(snapshot.status.auraColor.opacity(0.55 + 0.30 * pulse), lineWidth: 2)
            .frame(width: auraSize, height: auraSize)
            .blur(radius: 0.5)
    }

    private var thoughtBubble: some View {
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(snapshot.status.auraColor)
                    .frame(width: 4, height: 4)
                    .opacity(0.3 + 0.7 * thoughtPulseOpacity(index: i))
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color(red: 0.04, green: 0.05, blue: 0.10).opacity(0.85))
                .overlay(Capsule().stroke(snapshot.status.auraColor.opacity(0.6), lineWidth: 1))
        )
    }

    private func thoughtPulseOpacity(index: Int) -> Double {
        let now = Date().timeIntervalSinceReferenceDate
        let phase = (now + Double(index) * 0.20).truncatingRemainder(dividingBy: 1.0)
        return 0.5 + 0.5 * sin(phase * .pi * 2)
    }

    private var doneBubble: some View {
        Text(String(localized: "agentsCanvas.bubble.done", defaultValue: "DONE"))
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .tracking(1)
            .foregroundColor(Color(red: 0.04, green: 0.05, blue: 0.10))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(snapshot.status.auraColor)
                    .shadow(color: snapshot.status.auraColor.opacity(0.6), radius: 4)
            )
    }

    private var label: some View {
        Text(snapshot.title)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.78))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 4)
            .frame(maxWidth: (snapshot.isAtDesk ? Self.seatedSize : Self.avatarSize) + 36)
    }

    @ViewBuilder
    private var roleMenu: some View {
        Section(String(localized: "agentsCanvas.role.section", defaultValue: "Role")) {
            ForEach(AgentRole.allCases) { role in
                Button {
                    onSetRole(role)
                } label: {
                    Label(role.localizedName, systemImage: role == snapshot.role ? "checkmark" : "")
                }
            }
        }
    }

    private func computeBob(at elapsed: TimeInterval) -> CGFloat {
        guard !snapshot.isAtDesk, !snapshot.isWalking else { return 0 }
        let period = snapshot.role.bouncePeriod
        let phase = (elapsed.truncatingRemainder(dividingBy: period)) / period
        let amplitude: CGFloat = 3
        return CGFloat(sin(phase * 2 * .pi)) * amplitude
    }

    private func computePulse(at elapsed: TimeInterval) -> Double {
        let phase = (elapsed.truncatingRemainder(dividingBy: 1.6)) / 1.6
        return 0.5 + 0.5 * sin(phase * 2 * .pi)
    }

    private func computeWalkJiggle(at elapsed: TimeInterval) -> CGFloat {
        guard snapshot.isWalking, !snapshot.isAtDesk else { return 0 }
        let frequency: Double = 4
        let phase = (elapsed * frequency).truncatingRemainder(dividingBy: 1.0)
        let amplitude: CGFloat = 2
        return CGFloat(sin(phase * 2 * .pi)) * amplitude
    }

    private func shouldShowDoneBubble(at now: Date) -> Bool {
        guard snapshot.status == .completed, let completedAt else { return false }
        return now.timeIntervalSince(completedAt) <= 5
    }
}
