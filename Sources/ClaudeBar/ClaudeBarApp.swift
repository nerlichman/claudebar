import AppKit
import SwiftUI

@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let appState: AppState

    init() {
        Self.enforceSingleInstance()
        Log.info("ClaudeBar launched (version 0.1.3)")
        appState = AppState.shared
        appState.start()
    }

    /// If another ClaudeBar is already running, hand off to it and exit before
    /// any status item is created — otherwise the menu bar shows two icons.
    /// Matching on bundle identifier also catches a launch from a different
    /// path (e.g. build/ vs ~/Applications), which LaunchServices' own
    /// single-instance guard does not coalesce. Runs in init(), before the
    /// scene is built, so the duplicate exits cleanly.
    private static func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mePID = NSRunningApplication.current.processIdentifier
        let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != mePID }
        guard let existing else { return }
        existing.activate()
        Log.info("ClaudeBar already running (pid \(existing.processIdentifier)); exiting duplicate")
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView()
                .environment(appState)
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
