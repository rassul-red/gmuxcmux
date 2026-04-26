import SwiftUI

/// SwiftUI shell for the Ghost Projects dashboard. Per epic #1 the layout is
/// sidebar (left) + 2×2 isometric grid WebView (center, owns the bulk of the
/// canvas) + detail / Quick Actions (right) + collapsible terminal dock
/// (rightmost) + action bar (bottom).
///
/// The terminal dock is hidden by default (`terminalDockCollapsed = true`)
/// so the ghost grid commands the full center column until the user opts
/// the dock in via the action bar / shortcut. Real Workspace data binds in
/// #2; action handlers wire in #5/#6; ghost state injection happens in #3/#4.
struct GhostDashboardView: View {
    @AppStorage("terminalDockCollapsed") private var terminalDockCollapsed: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                GhostDashboardSidebar()
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

                GhostGridWebView()
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
