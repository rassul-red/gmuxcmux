import AppKit
import SwiftUI

/// Singleton controller for the standalone Ghost Projects dashboard window.
/// Mirrors the Debug Windows pattern (e.g. `SettingsAboutTitlebarDebugWindowController`)
/// in `Sources/cmuxApp.swift`.
final class GhostDashboardWindowController: NSWindowController, NSWindowDelegate {
    static let shared = GhostDashboardWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "dashboard.title",
            defaultValue: "Ghost Projects"
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.ghostDashboard")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GhostDashboardView())
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
