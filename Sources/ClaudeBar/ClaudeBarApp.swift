import SwiftUI

@main
struct ClaudeBarApp: App {
    private let appState: AppState

    init() {
        Log.info("ClaudeBar launched (version 0.1.0)")
        appState = AppState.shared
        appState.start()
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
