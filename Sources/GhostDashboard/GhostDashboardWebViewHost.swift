import AppKit
import Bonsplit
import Combine
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
/// `bridgeHost.attach(...)`. The `WKNavigationDelegate` conformance and the
/// activity-gate plumbing are owned by #5.
final class GhostDashboardWebViewHost: WKWebView, WKNavigationDelegate {
    /// The bridge host that owns Swift↔JS message routing for this WebView.
    /// Callers wire it to a `GhostRosterManager` via `bridgeHost.attach(...)`.
    let bridgeHost: GhostBridgeHost

    /// True once the WebView's main document has finished loading and the
    /// in-page lifecycle/RAF shim has been installed. We buffer the latest
    /// gate value here so the first "active" event after load is replayed.
    private var pageReady = false
    private var lastPendingActive: Bool?
    private var gateCancellable: AnyCancellable?

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
        navigationDelegate = self
        subscribeToActivityGate()
        loadDashboardAsset()
    }

    deinit {
        gateCancellable?.cancel()
    }

    // MARK: - Activity gate

    /// Subscribes once at init time. The publisher is main-thread; closures
    /// run on main. This is called at most on focus transitions — never on a
    /// keystroke — so it is safe to read from outside the typing-latency
    /// hotpath set.
    private func subscribeToActivityGate() {
        gateCancellable = DashboardActivityGate.shared.dashboardActive
            .sink { [weak self] active in
                self?.dispatchLifecycle(active: active)
            }
    }

    private func dispatchLifecycle(active: Bool) {
        guard pageReady else {
            // Buffer the most recent value until the page finishes loading;
            // navigation completion will replay it.
            lastPendingActive = active
            return
        }
        let payload: [String: Any] = ["active": active]
        sendEnvelope(type: "ghost.lifecycle.v1", version: 1, payload: payload)
    }

    /// Encodes a `{ type, version, payload }` envelope (the #3 bridge shape)
    /// and dispatches it via `window.cmux.host.dispatch(...)` if present, else
    /// falls back to `window.__ghostLifecycle(payload)` which the in-page
    /// lifecycle shim installs at load time.
    private func sendEnvelope(type: String, version: Int, payload: [String: Any]) {
        let envelope: [String: Any] = [
            "type": type,
            "version": version,
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else {
            #if DEBUG
            dlog("ghost.lifecycle envelope serialization failed")
            #endif
            return
        }
        // Prefer the structured #3 bridge if it has been installed; otherwise
        // call the lifecycle shim directly. Both branches are no-ops when the
        // page isn't ready.
        let js = """
        (function(env){
          try {
            if (window.cmux && window.cmux.host && typeof window.cmux.host.dispatch === 'function') {
              window.cmux.host.dispatch(env);
            } else if (typeof window.__ghostLifecycle === 'function') {
              window.__ghostLifecycle(env.payload);
            }
          } catch (e) { /* swallow: dashboard JS may still be booting */ }
        })(\(json));
        """
        evaluateJavaScript(js, completionHandler: nil)
    }

    /// JS shim installed at navigation completion. Provides
    /// `window.__ghostLifecycle({active: bool})` plus a tiny RAF demo loop so
    /// the gate has something visibly suspendable until the dashboard JS
    /// bundle wires up its own particle system.
    private static let lifecycleShim: String = """
    (function(){
      if (window.__ghostLifecycleInstalled) return;
      window.__ghostLifecycleInstalled = true;

      var rafHandle = 0;
      var paused = false;
      var slowTimer = 0;
      var demoCounter = 0;

      function frame(){
        if (paused) return;
        demoCounter = (demoCounter + 1) | 0;
        window.__ghostFrameCounter = demoCounter;
        rafHandle = window.requestAnimationFrame(frame);
      }

      function suspend(){
        paused = true;
        if (rafHandle) {
          window.cancelAnimationFrame(rafHandle);
          rafHandle = 0;
        }
        // Clamp any keep-alive UI tick to <=5 fps while suspended.
        if (!slowTimer) {
          slowTimer = window.setInterval(function(){
            window.__ghostSlowTick = (window.__ghostSlowTick | 0) + 1;
          }, 200);
        }
      }

      function resume(){
        paused = false;
        if (slowTimer) {
          window.clearInterval(slowTimer);
          slowTimer = 0;
        }
        if (!rafHandle) rafHandle = window.requestAnimationFrame(frame);
      }

      window.__ghostLifecycle = function(msg){
        if (!msg) return;
        if (msg.active === false) suspend();
        else if (msg.active === true) resume();
      };

      // Default to "active" until the host says otherwise.
      resume();
    })();
    """

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        evaluateJavaScript(GhostDashboardWebViewHost.lifecycleShim) { [weak self] _, _ in
            guard let self else { return }
            self.pageReady = true
            if let pending = self.lastPendingActive {
                self.lastPendingActive = nil
                self.dispatchLifecycle(active: pending)
            }
        }
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
