import AppKit
import Combine

/// Emits true when the Ghost Projects dashboard window is key, false when a
/// terminal (or any non-dashboard) window takes focus.
///
/// Consumers must NOT call this from typing-sensitive paths (see
/// `CLAUDE.md` § "Typing-latency-sensitive paths"). Subscribe in
/// `viewDidAppear` / `init` only; the publisher fires at most once per
/// focus transition, never per-keystroke.
///
/// Identifier match: the `GhostDashboardWindowController` (#8) sets its
/// window's `identifier` to `"cmux.ghostDashboard"`. We accept either the
/// `"cmux.ghostDashboard"` namespaced form shipped by #8 or the
/// `"GhostDashboard"` literal called out in issue #5 step 1, so the gate is
/// resilient to a future rename in either direction.
final class DashboardActivityGate {
    static let shared = DashboardActivityGate()

    /// Publishes on the main queue. true = dashboard active, false = terminal
    /// (or other) window focused, or no window key.
    let dashboardActive: AnyPublisher<Bool, Never>

    private init() {
        let prefixes = ["cmux.ghostDashboard", "GhostDashboard"]
        let isDashboardWindow: (NSWindow?) -> Bool = { window in
            guard let raw = window?.identifier?.rawValue else { return false }
            return prefixes.contains(where: { raw.hasPrefix($0) })
        }

        let initial = isDashboardWindow(NSApplication.shared.keyWindow)

        let becomeKey = NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)
            .map { note -> Bool in isDashboardWindow(note.object as? NSWindow) }
        let resignKey = NotificationCenter.default
            .publisher(for: NSWindow.didResignKeyNotification)
            .map { _ in false }

        dashboardActive = Publishers.Merge(becomeKey, resignKey)
            .prepend(initial)
            // removeDuplicates is load-bearing: AppKit can fire `becomeKey(terminal)` and
            // `resignKey(dashboard)` in either order during same-app focus transitions;
            // either ordering ends in two `false`s and we want one.
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
