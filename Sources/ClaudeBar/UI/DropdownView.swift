import ServiceManagement
import SwiftUI

struct DropdownView: View {
    @Environment(AppState.self) private var appState
    @State private var showDormant = false
    @State private var showEnded = false
    @State private var expandedSessions: Set<String> = []
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled = HookInstaller.isInstalled
    @AppStorage("menuBarLabelStyle") private var labelStyleRaw = MenuBarLabelStyle.full.rawValue
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("waitingNotificationsEnabled") private var waitingNotificationsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageSectionView(usage: appState.usage)

            Divider()

            sessionsSection

            Divider()

            TodayStatsView(stats: appState.dayStats)

            if let status = statusCaption {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("Refresh") {
                    appState.refreshAll()
                    appState.requestImmediateUsageRefresh()
                }
                .controlSize(.small)

                Spacer()

                settingsMenu

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
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

    private var settingsMenu: some View {
        Menu {
            Picker("Menu bar shows", selection: $labelStyleRaw) {
                ForEach(MenuBarLabelStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }

            Toggle("Usage notifications", isOn: $notificationsEnabled)

            // Off by default — the desktop app and terminal already alert on
            // these, and Claude re-enters waiting every turn.
            Toggle("\"Waiting for you\" notifications", isOn: $waitingNotificationsEnabled)

            // SMAppService needs a real bundle; hide under `swift run`.
            if Bundle.main.bundleIdentifier != nil {
                Toggle("Launch at login", isOn: launchAtLogin)
            }

            Divider()

            if hooksInstalled {
                Text("Claude Code hooks: installed")
            } else {
                Button("Install Claude Code hooks") {
                    do {
                        try HookInstaller.install()
                        hooksInstalled = true
                    } catch {
                        Log.error("hooks: install failed (\(error.localizedDescription))")
                    }
                }
            }

            Divider()

            switch appState.manualTokenState {
            case .none:
                Button("Paste usage token from clipboard") {
                    appState.pasteTokenFromClipboard()
                }
            case .active:
                Text("Usage token: active")
                Button("Clear usage token") { appState.clearToken() }
            case .expired:
                Text("Usage token: expired")
                Button("Paste usage token from clipboard") {
                    appState.pasteTokenFromClipboard()
                }
                Button("Clear usage token") { appState.clearToken() }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Settings")
        .onAppear {
            // Resync in case it was changed in System Settings > Login Items.
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            hooksInstalled = HookInstaller.isInstalled
        }
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
