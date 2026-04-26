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
    private var workspaceLabelsCancellable: AnyCancellable?
    private var lastPushedWorkspaceLabels: [String] = []

    init() {
        let bridge = GhostBridgeHost()
        self.bridgeHost = bridge
        GhostDashboardController.shared.wire(bridgeHost: bridge)

        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(bridge, name: GhostBridgeMessageName.action)
        controller.add(bridge, name: GhostBridgeMessageName.metrics)

        for script in Self.loadUserScripts() {
            controller.addUserScript(script)
        }

        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        super.init(frame: .zero, configuration: config)
        self.bridgeHost.webView = self
        translatesAutoresizingMaskIntoConstraints = false
        setValue(false, forKey: "drawsBackground")
        // Use WebKit's native pinch zoom + scroll-magnify. The previous
        // SwiftUI `scaleEffect` path (GhostCanvasZoomView) was unreliable for
        // the metal-backed WebView surface, especially below 1.0. The
        // embedded grid view drives `magnification` programmatically via
        // EmbeddedGridZoomController for HUD buttons; trackpad pinch now
        // works natively.
        allowsMagnification = true
        navigationDelegate = self
        subscribeToActivityGate()
        subscribeToWorkspaceLabels()
        attachRosterBridge()
        loadDashboardAsset()
    }

    /// Subscribes the bridge host to the process-wide `GhostRosterManager`
    /// singleton so roster mutations (project register / tool_use ingestion
    /// from `ClaudeTranscriptWatcher`) flow into the WebView as
    /// `ghost.snapshot.v1` / `ghost.delta.v1` envelopes. The bridge owns its
    /// own coalescing window (20 ms) and snapshot/delta accounting; this
    /// method only wires the inputs.
    private func attachRosterBridge() {
        let manager = GhostRosterManager.shared
        // Read `metadataProvider` per-call rather than capturing it at attach
        // time: a future caller may swap the provider on `GhostRosterManager.shared`
        // after this WebView is initialized (e.g. when workspace metadata
        // becomes available). The thread-safe accessor on the manager guards
        // the closure swap.
        bridgeHost.attach(
            webView: self,
            rosterManager: manager,
            projectMetadataProvider: { [weak manager] pid in
                manager?.metadataProvider(pid) ?? (pid, "", "")
            }
        )
    }

    deinit {
        gateCancellable?.cancel()
        workspaceLabelsCancellable?.cancel()
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

    /// Push the first four cmux workspace titles to the dashboard whenever
    /// they change. The JS side renders them as a capsule per room — see
    /// `dashboard.js#applyWorkspaceLabels`.
    private func subscribeToWorkspaceLabels() {
        workspaceLabelsCancellable = GhostDashboardController.shared
            .$workspaceLabels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] labels in
                self?.dispatchWorkspaceLabels(labels)
            }
    }

    private func dispatchWorkspaceLabels(_ labels: [String]) {
        lastPushedWorkspaceLabels = labels
        guard pageReady else { return }
        sendWorkspaceLabels(labels)
    }

    private func sendWorkspaceLabels(_ labels: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: labels),
              let json = String(data: data, encoding: .utf8) else {
            #if DEBUG
            dlog("ghost.workspaceLabels serialization failed")
            #endif
            return
        }
        let js = """
        (function(labels){
          window.__cmuxWorkspaceLabels = labels;
          try {
            if (window.cmuxGhostDashboard
                && typeof window.cmuxGhostDashboard.applyWorkspaceLabels === 'function') {
              window.cmuxGhostDashboard.applyWorkspaceLabels(labels);
            }
          } catch (e) { /* dashboard JS may still be booting */ }
        })(\(json));
        """
        evaluateJavaScript(js, completionHandler: nil)
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
            // Replay the most recent workspace labels so a label update that
            // arrived before the page finished loading is not lost.
            self.sendWorkspaceLabels(self.lastPushedWorkspaceLabels)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Loads the dashboard's WKUserScript assets in injection-order:
    ///
    ///   1. `bridge.js`               — atDocumentStart, installs
    ///                                  `window.__ghostBridge` (Task #3).
    ///   2. `ghost-room-overlay.js`   — atDocumentEnd, renders the room scene
    ///                                  on top of the bundled dashboard
    ///                                  (issue #17). Injected after document
    ///                                  end so `document.body` is available.
    ///
    /// A missing optional script does not block the others — the bridge is
    /// required, but the overlay is presentational and degrades cleanly.
    private static func loadUserScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        if let bridge = loadBundledScript(
            name: "bridge",
            injectionTime: .atDocumentStart
        ) {
            scripts.append(bridge)
        }
        if let overlay = loadBundledScript(
            name: "ghost-room-overlay",
            injectionTime: .atDocumentEnd
        ) {
            scripts.append(overlay)
        }
        return scripts
    }

    private static func loadBundledScript(
        name: String,
        injectionTime: WKUserScriptInjectionTime
    ) -> WKUserScript? {
        guard let base = Bundle.main.resourceURL else {
            #if DEBUG
            dlog("ghost.\(name).js missing: Bundle.main.resourceURL is nil")
            #endif
            return nil
        }
        let candidate = base
            .appendingPathComponent("GhostDashboard")
            .appendingPathComponent("\(name).js")
        let url: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            url = candidate
        } else if let bundled = Bundle.main.url(
            forResource: "GhostDashboard/\(name)",
            withExtension: "js"
        ) {
            url = bundled
        } else {
            #if DEBUG
            dlog("ghost.\(name).js asset missing at \(candidate.path)")
            #endif
            return nil
        }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            #if DEBUG
            dlog("ghost.\(name).js read failed at \(url.path)")
            #endif
            return nil
        }
        return WKUserScript(
            source: source,
            injectionTime: injectionTime,
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
