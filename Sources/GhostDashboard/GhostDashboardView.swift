import SwiftUI

/// SwiftUI shell for the Ghost Projects dashboard. Per epic #1 the layout is
/// sidebar (left) + 2×2 isometric grid WebView (center, owns the bulk of the
/// canvas) + detail / Quick Actions (right) + collapsible terminal dock
/// (rightmost) + action bar (bottom).
///
/// The terminal dock is hidden by default (`terminalDockCollapsed = true`)
/// so the ghost grid commands the full center column until the user opts
/// the dock in via the action bar / shortcut. The center grid is wrapped in
/// `GhostCanvasZoomView` so the world view can be panned and pinch-zoomed
/// (Issue #16). Real Workspace data binds in #2; action handlers wire in
/// #5/#6; ghost state injection happens in #3/#4.
struct GhostDashboardView: View {
    @AppStorage("terminalDockCollapsed") private var terminalDockCollapsed: Bool = true
    @StateObject private var zoomState = CanvasZoomState()

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                GhostDashboardSidebar()
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

                GhostCanvasZoomView(state: zoomState) {
                    GhostGridWebView()
                }
                .frame(minWidth: 480, minHeight: 360)

                GhostDashboardRightPanel()
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

                if !terminalDockCollapsed {
                    GhostTerminalDockPlaceholder()
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
                }
            }

            GhostDashboardActionBar()
        }
        .frame(minWidth: 1024, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// `NSViewRepresentable` wrapping `GhostDashboardWebViewHost`. The WebView
/// owns its own retained instance per host view so SwiftUI re-creation never
/// tears down the message-handler bridge mid-flight.
struct GhostGridWebView: NSViewRepresentable {
    final class Coordinator {
        let webView: GhostDashboardWebViewHost

        init() {
            self.webView = GhostDashboardWebViewHost()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> GhostDashboardWebViewHost {
        context.coordinator.webView
    }

    func updateNSView(_ nsView: GhostDashboardWebViewHost, context: Context) {
        // No-op until #4 wires Workspace state through the bridge.
    }
}

// MARK: - Issue #16: Canvas pan + pinch-zoom

/// Drives the 2-axis pan + pinch zoom state for the world canvas.
///
/// The committed `zoom` is what the view renders; `baseZoom` is the value
/// captured when a magnification gesture starts so successive pinches
/// compose correctly. Both values are clamped to [`minZoom`, `maxZoom`].
final class CanvasZoomState: ObservableObject {
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 2.5
    static let stepZoom: CGFloat = 0.1
    static let resetZoom: CGFloat = 1.0

    @Published var zoom: CGFloat = CanvasZoomState.resetZoom
    @Published var baseZoom: CGFloat = CanvasZoomState.resetZoom

    /// Apply an in-flight magnification gesture multiplier. Clamps to range.
    func applyMagnification(_ multiplier: CGFloat) {
        zoom = Self.clamp(baseZoom * multiplier)
    }

    /// Commit the current `zoom` as the new `baseZoom`. Call from
    /// `MagnificationGesture.onEnded`.
    func commitMagnification() {
        baseZoom = zoom
    }

    func zoomIn() { setZoom(zoom + Self.stepZoom) }
    func zoomOut() { setZoom(zoom - Self.stepZoom) }
    func resetZoom() { setZoom(Self.resetZoom) }

    func setZoom(_ next: CGFloat) {
        let clamped = Self.clamp(next)
        zoom = clamped
        baseZoom = clamped
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        return min(max(value, minZoom), maxZoom)
    }

    /// Human-readable percentage label, e.g. `"100%"`.
    var percentLabel: String {
        return "\(Int((zoom * 100).rounded()))%"
    }
}

/// SwiftUI container that wraps arbitrary canvas `Content` with:
///   • two-axis ScrollView (pan)
///   • `MagnificationGesture` (pinch zoom) clamped to [0.5×, 2.5×]
///   • bottom-trailing HUD pill: `−`, percent label, `+`, `⌘0` reset
///
/// The wrapped content is sized at its intrinsic
/// `(contentWidth × contentHeight)` and scaled with anchor `.topLeading`
/// while the outer frame grows to `contentWidth*zoom × contentHeight*zoom`
/// so the scroll view's contentSize tracks the zoom level — without this
/// the scrollable area would stay at 100% and zooming-in would clip
/// content off the edges.
struct GhostCanvasZoomView<Content: View>: View {
    @ObservedObject var state: CanvasZoomState
    let content: () -> Content

    init(state: CanvasZoomState, @ViewBuilder content: @escaping () -> Content) {
        self.state = state
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                content()
                    .frame(
                        width: geo.size.width,
                        height: geo.size.height,
                        alignment: .topLeading
                    )
                    .scaleEffect(state.zoom, anchor: .topLeading)
                    .frame(
                        width: geo.size.width * state.zoom,
                        height: geo.size.height * state.zoom,
                        alignment: .topLeading
                    )
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in state.applyMagnification(value) }
                    .onEnded { _ in state.commitMagnification() }
            )
            .overlay(alignment: .bottomTrailing) {
                CanvasZoomHUD(state: state)
                    .padding(12)
            }
        }
    }
}

/// Floating pill-shaped HUD anchored bottom-right of the canvas. Mirrors
/// the trackpad pinch behavior with discrete buttons + a reset action.
private struct CanvasZoomHUD: View {
    @ObservedObject var state: CanvasZoomState

    var body: some View {
        HStack(spacing: 8) {
            // Note: keyboard shortcuts (⌘0 / ⌘+ / ⌘-) are intentionally not
            // bound here. CLAUDE.md mandates that every cmux-owned shortcut
            // be registered in `KeyboardShortcutSettings`, supported in
            // `~/.config/cmux/settings.json`, and documented. Wiring them up
            // is tracked as a follow-up so this PR stays scoped to the HUD.
            Button(action: { state.zoomOut() }) {
                Image(systemName: "minus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(state.zoom <= CanvasZoomState.minZoom + 0.0001)
            .help(String(localized: "ghost.canvas.zoom.out", defaultValue: "Zoom out"))
            .accessibilityLabel(Text(String(localized: "ghost.canvas.zoom.out", defaultValue: "Zoom out")))

            Text(state.percentLabel)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 44)
                .accessibilityLabel(Text(String(
                    localized: "ghost.canvas.zoom.level",
                    defaultValue: "Zoom level"
                )))

            Button(action: { state.zoomIn() }) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(state.zoom >= CanvasZoomState.maxZoom - 0.0001)
            .help(String(localized: "ghost.canvas.zoom.in", defaultValue: "Zoom in"))
            .accessibilityLabel(Text(String(localized: "ghost.canvas.zoom.in", defaultValue: "Zoom in")))

            Button(action: { state.resetZoom() }) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(String(localized: "ghost.canvas.zoom.reset", defaultValue: "Reset zoom"))
            .accessibilityLabel(Text(String(localized: "ghost.canvas.zoom.reset", defaultValue: "Reset zoom")))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
    }
}
