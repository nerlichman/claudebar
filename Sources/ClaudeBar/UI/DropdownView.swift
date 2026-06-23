import ServiceManagement
import SwiftUI

struct DropdownView: View {
    @Environment(AppState.self) private var appState
    @State private var showDormant = false
    @State private var showEnded = false
    @State private var expandedSessions: Set<String> = []
    @State private var showSettings = false
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled = HookInstaller.isInstalled
    @AppStorage("menuBarLabelStyle") private var labelStyleRaw = MenuBarLabelStyle.full.rawValue
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("waitingNotificationsEnabled") private var waitingNotificationsEnabled = false
    // Same key SparkleController reads; the toggle just mirrors it and pushes
    // changes to the live updater (see .onChange below).
    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageSectionView(usage: appState.usage)

            Divider()

            sessionsSection

            Divider()

            TodayStatsView(stats: appState.dayStats)

            // Same local-log estimate, wider window. Only shown once it adds
            // something beyond Today's figure.
            if appState.weekStats.messageCount > appState.dayStats.messageCount {
                TodayStatsView(title: "This week", stats: appState.weekStats)
            }

            if let status = statusCaption {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Divider()

            if let asOf = appState.usage?.source.asOf, asOf > .distantPast {
                Text("Updated \(asOf.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    appState.refreshAll()
                    appState.requestImmediateUsageRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                // A plain Button fills its half (a Menu hugs its label); the
                // options open in a popover, like the reference app's window.
                Button { showSettings.toggle() } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    settingsPopover
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    /// Orange status line above the bottom bar — only when something is off.
    private var statusCaption: String? {
        if let reason = appState.degradedReason { return reason }
        if appState.menuBarAttention, labelStyleRaw != MenuBarLabelStyle.full.rawValue {
            return "showing full menu bar label while something needs attention"
        }
        return nil
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Menu bar shows", selection: $labelStyleRaw) {
                ForEach(MenuBarLabelStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            .pickerStyle(.menu)

            Toggle("Usage notifications", isOn: $notificationsEnabled)

            // Off by default — the desktop app and terminal already alert on
            // these, and Claude re-enters waiting every turn.
            Toggle("\"Waiting for you\" notifications", isOn: $waitingNotificationsEnabled)

            // SMAppService needs a real bundle; hide under `swift run`.
            if Bundle.main.bundleIdentifier != nil {
                Toggle("Launch at login", isOn: launchAtLogin)
            }

            // Only on signed release builds, where Sparkle is live.
            if SparkleController.shared.isAvailable {
                Toggle("Automatically check for updates", isOn: $autoUpdateEnabled)
                    .onChange(of: autoUpdateEnabled) { _, newValue in
                        SparkleController.shared.autoUpdateEnabled = newValue
                    }
            }

            Divider()

            if hooksInstalled {
                settingsCaption("Claude Code hooks: installed")
            } else {
                settingsRow("Install Claude Code hooks") {
                    do {
                        try HookInstaller.install()
                        hooksInstalled = true
                    } catch {
                        Log.error("hooks: install failed (\(error.localizedDescription))")
                    }
                }
            }

            Divider()

            // Connection & usage data — sign-in, token source, and the token
            // status all serve one purpose, so they live in one block.
            if appState.awaitingSignInCode {
                settingsCaption("Waiting for browser sign-in…")
                settingsRow("Paste sign-in code from clipboard") {
                    appState.completeSignInFromClipboard()
                }
                settingsRow("Cancel sign-in") { appState.cancelSignIn() }
            } else {
                settingsRow("Sign in to Claude…") { appState.beginSignIn() }
            }

            Toggle("Use Keychain token for usage", isOn: Binding(
                get: { appState.useKeychainToken },
                set: { appState.useKeychainToken = $0 }
            ))

            switch appState.manualTokenState {
            case .none:
                settingsCaption("Usage token: none")
                settingsRow("Paste usage token from clipboard") {
                    appState.pasteTokenFromClipboard()
                }
            case .active:
                settingsCaption(appState.usageTokenFromKeychain
                     ? "Usage token: active (Keychain)"
                     : "Usage token: active (pasted)")
                if !appState.usageTokenFromKeychain {
                    settingsRow("Clear pasted token") { appState.clearToken() }
                }
            case .expired:
                settingsCaption("Usage token: expired", tint: .orange)
                settingsRow("Paste usage token from clipboard") {
                    appState.pasteTokenFromClipboard()
                }
                settingsRow("Clear pasted token") { appState.clearToken() }
            }

            settingsRow("Copy access token") {
                appState.copyAccessTokenToClipboard()
            }

            Divider()

            settingsRow("Quit ClaudeBar") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 270)
        .padding(14)
        .onAppear {
            // Resync in case it was changed in System Settings > Login Items.
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            hooksInstalled = HookInstaller.isInstalled
        }
    }

    /// A left-aligned, full-width tappable row — the popover's stand-in for a
    /// menu item so the panel reads like the menu it replaced.
    private func settingsRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showSettings = false
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Non-interactive status line inside the popover (e.g. token state).
    private func settingsCaption(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The login item points at whichever bundle is running, so toggle this
    /// from the installed copy (~/Applications), not a build-dir run.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLoginEnabled = enable
                } catch {
                    Log.error("launch at login: \(error.localizedDescription)")
                    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
                }
            }
        )
    }

    private func sessionRow(_ session: Session) -> some View {
        SessionRowView(
            session: session,
            stats: appState.sessionStats[session.sessionId],
            lifetimeStats: appState.sessionLifetimeStats[session.sessionId],
            isExpanded: expandedSessions.contains(session.sessionId),
            onToggleExpand: {
                if expandedSessions.contains(session.sessionId) {
                    expandedSessions.remove(session.sessionId)
                } else {
                    expandedSessions.insert(session.sessionId)
                }
            }
        )
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if appState.sessions.isEmpty {
                Text("No running sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.currentSessions) { session in
                    sessionRow(session)
                }
                if !appState.dormantSessions.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showDormant.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(showDormant ? .degrees(90) : .zero)
                            Text("\(appState.dormantSessions.count) dormant session\(appState.dormantSessions.count == 1 ? "" : "s")")
                                .font(.caption)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showDormant {
                        ForEach(appState.dormantSessions) { session in
                            sessionRow(session)
                                .opacity(0.6)
                        }
                    }
                }

                if !appState.endedSessions.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showEnded.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(showEnded ? .degrees(90) : .zero)
                            Text("\(appState.endedSessions.count) earlier today")
                                .font(.caption)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showEnded {
                        ForEach(appState.endedSessions) { session in
                            sessionRow(session)
                                .opacity(0.6)
                        }
                    }
                }
            }
        }
    }
}
