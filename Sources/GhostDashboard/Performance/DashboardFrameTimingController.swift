#if DEBUG
import AppKit
import Bonsplit
import QuartzCore

/// Debug-only `CADisplayLink` sampler that records main-thread frame deltas
/// for 10 s and writes them to the unified debug log. Triggered from
/// "Debug > Debug Windows > Dashboard frame timing".
///
/// Usage from the menu:
///   `DashboardFrameTimingController.shared.start()`
///
/// Output goes to `dlog(...)` (see
/// `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`), which is
/// already routed to `/tmp/cmux-debug-<tag>.log` by `reload.sh`.
///
/// Per-tick line:  `dashboard.frameTime delta=16.701ms`
/// Summary line:   `frame.timing.summary count=600 mean=16.67 p99=18.20 dropped=2`
final class DashboardFrameTimingController: NSObject {
    static let shared = DashboardFrameTimingController()

    private var displayLink: CADisplayLink?
    private var samplesMs: [Double] = []
    private var lastTimestamp: CFTimeInterval = 0
    private var stopWorkItem: DispatchWorkItem?

    private override init() { super.init() }

    /// Returns an AppKit object whose `displayLink(target:selector:)` (macOS
    /// 14+) we can hook into, plus a flag indicating fallback. Prefers the
    /// GhostDashboard window's contentView; otherwise any visible window's
    /// contentView.
    private func anyDisplayLinkHost() -> (view: NSView, fallback: Bool)? {
        if let dashboardWindow = NSApp.windows.first(where: { window in
            guard let raw = window.identifier?.rawValue else { return false }
            return raw.hasPrefix("cmux.ghostDashboard") || raw.hasPrefix("GhostDashboard")
        }), let view = dashboardWindow.contentView {
            return (view, false)
        }
        if let view = NSApp.windows.lazy.compactMap({ $0.contentView }).first {
            return (view, true)
        }
        return nil
    }

    /// Starts a 10 s frame timing capture if one is not already running.
    func start(duration: TimeInterval = 10) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard displayLink == nil else {
            dlog("dashboard.frameTime already running, ignoring start()")
            return
        }
        samplesMs.removeAll(keepingCapacity: true)
        lastTimestamp = 0

        // `CADisplayLink(target:selector:)` is iOS-only. On macOS 14+ the
        // canonical AppKit replacement is `NSView.displayLink(...)` (or
        // `NSWindow.displayLink(...)`). Attach to the dashboard window's
        // contentView when available; fall back to any visible window so the
        // sampler still produces deltas if the dashboard hasn't been opened.
        guard let host = anyDisplayLinkHost() else {
            dlog("dashboard.frameTime no AppKit host found, aborting start")
            return
        }
        if host.fallback {
            let id = host.view.window?.identifier?.rawValue ?? "<unknown>"
            dlog("ghostdashboard.frametiming.warning fallback=true reason=\"dashboard window not key; sampling \(id)\"")
        }
        let link = host.view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        dlog("dashboard.frameTime start duration=\(String(format: "%.1f", duration))s")

        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp != 0 {
            let deltaMs = (now - lastTimestamp) * 1000.0
            samplesMs.append(deltaMs)
            dlog("dashboard.frameTime delta=\(String(format: "%.3f", deltaMs))ms")
        }
        lastTimestamp = now
    }

    private func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopWorkItem?.cancel()
        stopWorkItem = nil
        displayLink?.invalidate()
        displayLink = nil

        let count = samplesMs.count
        guard count > 0 else {
            dlog("frame.timing.summary count=0 mean=- p99=- dropped=-")
            return
        }
        let mean = samplesMs.reduce(0, +) / Double(count)
        // Dropped frames: any delta beyond the ~16.667 ms 60 Hz budget.
        let dropped = samplesMs.filter { $0 > 17.0 }.count
        let sorted = samplesMs.sorted()
        let p99Index = max(0, min(count - 1, Int(ceil(Double(count) * 0.99)) - 1))
        let p99 = sorted[p99Index]
        dlog(
            "frame.timing.summary count=\(count) "
                + "mean=\(String(format: "%.2f", mean)) "
                + "p99=\(String(format: "%.2f", p99)) "
                + "dropped=\(dropped)"
        )
    }
}
#endif
