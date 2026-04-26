import SwiftUI

/// SwiftUI shell for the Ghost Projects dashboard. Defines the 5-region
/// layout: sidebar / center 2x2 grid (WebView) / right detail / bottom
/// action bar / right terminal dock placeholder.
///
/// Real Workspace data binds in #2; action handlers wire in #5/#6; ghost
/// state injection happens in #3/#4.
struct GhostDashboardView: View {
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                GhostDashboardSidebar()
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

                GhostDashboardCenter()
                    .frame(minWidth: 480)

                GhostDashboardRightPanel()
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }

            GhostDashboardActionBar()
        }
        .frame(minWidth: 1024, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct GhostDashboardCenter: View {
    var body: some View {
        HSplitView {
            GhostGridWebView()
                .frame(minWidth: 480, minHeight: 360)

            GhostTerminalDockPlaceholder()
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
        }
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
