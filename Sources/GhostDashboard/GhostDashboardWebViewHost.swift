import AppKit
import Bonsplit
import WebKit

/// Hosts the Ghost Assets HTML bundle inside a `WKWebView` and wires the
/// Swift↔JS bridge surfaces required by #3:
///
/// - `ghost.action.v1`         — UI action callbacks from the dashboard
/// - `ghost.bridge.metrics`    — bridge throughput telemetry (50 deltas/s soak)
///
/// The handler logic lives on `GhostBridgeHost` (#3); this file owns the
/// `WKScriptMessageHandler` registration plus the `bridge.js` user script
/// injection so downstream callers only need to call
/// `bridgeHost.attach(...)`.
final class GhostDashboardWebViewHost: WKWebView {
    /// The bridge host that owns Swift↔JS message routing for this WebView.
    /// Callers wire it to a `GhostRosterManager` via `bridgeHost.attach(...)`.
    let bridgeHost: GhostBridgeHost

    init() {
        let bridge = GhostBridgeHost()
        self.bridgeHost = bridge

        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(bridge, name: GhostBridgeMessageName.action)
        controller.add(bridge, name: GhostBridgeMessageName.metrics)

        if let script = Self.loadBridgeUserScript() {
            controller.addUserScript(script)
        }

        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        super.init(frame: .zero, configuration: config)
        self.bridgeHost.webView = self
        translatesAutoresizingMaskIntoConstraints = false
        setValue(false, forKey: "drawsBackground")
        loadDashboardAsset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func loadBridgeUserScript() -> WKUserScript? {
        guard let base = Bundle.main.resourceURL else {
            #if DEBUG
            dlog("ghost.bridge.js missing: Bundle.main.resourceURL is nil")
            #endif
            return nil
        }
        let candidate = base.appendingPathComponent("GhostDashboard/bridge.js")
        let url: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            url = candidate
        } else if let bundled = Bundle.main.url(
            forResource: "GhostDashboard/bridge",
            withExtension: "js"
        ) {
            url = bundled
        } else {
            #if DEBUG
            dlog("ghost.bridge.js asset missing at \(candidate.path)")
            #endif
            return nil
        }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            #if DEBUG
            dlog("ghost.bridge.js read failed at \(url.path)")
            #endif
            return nil
        }
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
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
