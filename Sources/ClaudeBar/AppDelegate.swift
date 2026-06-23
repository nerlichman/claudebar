import AppKit

/// SwiftUI's `MenuBarExtra` only handles a plain left-click (toggling the
/// dropdown window). To add a right-click context menu we locate the status
/// item's button after launch and watch for right- / control-clicks with a
/// local event monitor — left-clicks pass straight through, so the existing
/// window behaviour is untouched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusButton: NSStatusBarButton?
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start the Sparkle updater early so automatic checks can run. No-op on
        // unsigned dev builds (see SparkleController).
        _ = SparkleController.shared
        installRightClickMenu()
    }

    /// The status item is created while the scene is built, which can race with
    /// `applicationDidFinishLaunching`, so retry briefly until the button shows.
    private func installRightClickMenu(attempt: Int = 0) {
        guard clickMonitor == nil else { return }

        if let button = Self.findStatusButton() {
            statusButton = button
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let button = self.statusButton, event.window === button.window
                else { return event }

                let isContextClick = event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
                guard isContextClick else { return event }  // ordinary left-click → window

                self.showMenu(for: button)
                return nil  // consume so the window doesn't also toggle
            }
            Log.info("status item right-click menu installed")
            return
        }

        guard attempt < 20 else {
            Log.error("status item button not found; right-click menu unavailable")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.installRightClickMenu(attempt: attempt + 1)
        }
    }

    private func showMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()
        for item in [
            NSMenuItem(title: "Open ClaudeBar", action: #selector(openClaudeBar), keyEquivalent: ""),
            NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: ""),
        ] {
            item.target = self
            menu.addItem(item)
        }
        // Only on signed release builds, where Sparkle is live (see SparkleController).
        if SparkleController.shared.isAvailable {
            let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            updates.target = self
            menu.addItem(updates)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openClaudeBar() {
        // Simulate the normal left-click so SwiftUI opens the dropdown window.
        statusButton?.performClick(nil)
    }

    @objc private func refresh() {
        AppState.shared.refreshAll()
        AppState.shared.requestImmediateUsageRefresh()
    }

    @objc private func checkForUpdates() {
        SparkleController.shared.checkForUpdates()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private static func findStatusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = firstStatusButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func firstStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = firstStatusButton(in: sub) { return found }
        }
        return nil
    }
}
