import AppKit
import SwiftUI

/// Drives the WKWebView's native `magnification` from the SwiftUI HUD and
/// keeps the displayed percentage in sync with trackpad pinches via KVO.
@MainActor
final class EmbeddedGridZoomController: ObservableObject {
    static let minMag: CGFloat = 0.4
    static let maxMag: CGFloat = 3.0
    static let step: CGFloat = 0.1

    @Published private(set) var magnification: CGFloat = 1.0

    weak var webView: GhostDashboardWebViewHost? {
        didSet { observeWebView() }
    }

    private var observer: NSKeyValueObservation?

    func zoomIn() { setMagnification(magnification + Self.step) }
    func zoomOut() { setMagnification(magnification - Self.step) }
    func resetZoom() { setMagnification(1.0) }

    func setMagnification(_ value: CGFloat) {
        let clamped = max(Self.minMag, min(Self.maxMag, value))
        magnification = clamped
        webView?.magnification = clamped
    }

    private func observeWebView() {
        observer?.invalidate()
        observer = webView?.observe(\.magnification, options: [.new]) { [weak self] _, change in
            guard let self, let next = change.newValue else { return }
            Task { @MainActor in
                if abs(self.magnification - next) > 0.001 {
                    self.magnification = max(Self.minMag, min(Self.maxMag, next))
                }
            }
        }
    }

    deinit { observer?.invalidate() }
}

/// NSViewRepresentable that hosts a fresh `GhostDashboardWebViewHost` and
/// binds it to the supplied controller. Sibling of `GhostGridWebView` (used
/// by the standalone dashboard) — kept separate so we don't change the
/// constructor signature on the path other call sites already use.
struct EmbeddedGhostGridWebView: NSViewRepresentable {
    @ObservedObject var controller: EmbeddedGridZoomController

    final class Coordinator {
        let webView: GhostDashboardWebViewHost
        init() { self.webView = GhostDashboardWebViewHost() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GhostDashboardWebViewHost {
        let webView = context.coordinator.webView
        webView.magnification = controller.magnification
        controller.webView = webView
        return webView
    }

    func updateNSView(_ nsView: GhostDashboardWebViewHost, context: Context) {
        // Magnification is driven via the controller; nothing to push here.
    }
}

/// Embedded variant of the Ghost dashboard's center grid for use inside the
/// main cmux window. WebKit handles pinch + scroll-magnify natively; a
/// SwiftUI HUD overlay drives the same `magnification` property for
/// keyboard / mouse zoom.
struct GhostEmbeddedGridView: View {
    @EnvironmentObject private var tabManager: TabManager
    @StateObject private var controller = EmbeddedGridZoomController()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            EmbeddedGhostGridWebView(controller: controller)
            EmbeddedZoomHUD(controller: controller)
                .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            GhostDashboardController.shared.bind(tabManager: tabManager)
        }
    }
}

private struct EmbeddedZoomHUD: View {
    @ObservedObject var controller: EmbeddedGridZoomController

    var body: some View {
        HStack(spacing: 8) {
            Button { controller.zoomOut() } label: {
                Image(systemName: "minus").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(controller.magnification <= EmbeddedGridZoomController.minMag + 0.0001)
            .help(String(localized: "ghost.canvas.zoom.out", defaultValue: "Zoom out"))

            Text("\(Int((controller.magnification * 100).rounded()))%")
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 44)

            Button { controller.zoomIn() } label: {
                Image(systemName: "plus").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(controller.magnification >= EmbeddedGridZoomController.maxMag - 0.0001)
            .help(String(localized: "ghost.canvas.zoom.in", defaultValue: "Zoom in"))

            Button { controller.resetZoom() } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(String(localized: "ghost.canvas.zoom.reset", defaultValue: "Reset zoom"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.92)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
    }
}
