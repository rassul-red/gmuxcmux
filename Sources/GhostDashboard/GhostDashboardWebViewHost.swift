import AppKit
import Bonsplit
import WebKit

/// Hosts the Ghost Assets HTML bundle inside a `WKWebView` and reserves the
/// two Swift↔JS bridge surfaces required by #3:
///
/// - `ghost.action.v1`         — UI action callbacks from the dashboard
/// - `ghost.bridge.metrics`    — bridge throughput telemetry (50 deltas/s soak)
///
/// Real handler logic lands in #3 / #4. The placeholders here keep the bridge
/// surface stable so downstream tasks can wire behavior without re-touching
/// this file.
final class GhostDashboardWebViewHost: WKWebView {
    private final class GhostActionMessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            #if DEBUG
            dlog("ghost.action.v1 received name=\(message.name) bodyType=\(type(of: message.body))")
            #endif
            // Action wiring lands in #4/#5/#6.
        }
    }

    private final class GhostBridgeMetricsHandler: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            #if DEBUG
            dlog("ghost.bridge.metrics received name=\(message.name)")
            #endif
            // Soak metrics aggregation lands in #3.
        }
    }

    init() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(GhostActionMessageHandler(), name: "ghost.action.v1")
        config.userContentController.add(GhostBridgeMetricsHandler(), name: "ghost.bridge.metrics")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        super.init(frame: .zero, configuration: config)
        translatesAutoresizingMaskIntoConstraints = false
        setValue(false, forKey: "drawsBackground")
        loadDashboardAsset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func loadDashboardAsset() {
        guard let base = Bundle.main.resourceURL else {
            #if DEBUG
            dlog("ghost.dashboard load aborted: Bundle.main.resourceURL is nil")
            #endif
            return
        }
        let candidate = base.appendingPathComponent("GhostDashboard/index.html")
        let url: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            url = candidate
        } else if let bundled = Bundle.main.url(
            forResource: "GhostDashboard/index",
            withExtension: "html"
        ) {
            url = bundled
        } else {
            #if DEBUG
            dlog("ghost.dashboard asset missing at \(candidate.path)")
            #endif
            return
        }
        loadFileURL(url, allowingReadAccessTo: base)
    }
}
