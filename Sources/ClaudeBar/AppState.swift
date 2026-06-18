import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    enum ManualTokenState: Equatable {
        case none, active, expired
    }

    var sessions: [Session] = []
    var usage: UsageReport?
    var dayStats: DayStats = .empty
    /// Today's token/cost totals per sessionId — same date filter as
    /// dayStats, so visible rows sum (roughly) to the Today section.
    var sessionStats: [String: DayStats] = [:]
    /// Full-transcript totals per sessionId, shown in row tooltips.
    var sessionLifetimeStats: [String: DayStats] = [:]
    /// Sessions that did work today but whose process is gone (the desktop
    /// app kills session processes when you navigate away).
    var endedSessions: [Session] = []
    var degradedReason: String?
    var manualTokenState: ManualTokenState = .none
    /// True while an in-app OAuth sign-in is waiting for the user to paste the
    /// code back from the browser — drives the settings UI.
    var awaitingSignInCode = false
    @ObservationIgnored private var pendingLogin: ClaudeOAuth.PendingLogin?
    /// True once a usage fetch has succeeded with a token read from the
    /// Keychain (vs. one pasted in manually) — drives the settings label.
    var usageTokenFromKeychain = false
    /// Opt-in: when off (the default), the app never touches the Keychain for
    /// usage polling — manual paste is used instead. The "Copy access token"
    /// action reads the Keychain regardless, since that's an explicit click.
    var useKeychainToken: Bool = UserDefaults.standard.bool(forKey: "useKeychainToken") {
        didSet {
            UserDefaults.standard.set(useKeychainToken, forKey: "useKeychainToken")
            if useKeychainToken {
                requestImmediateUsageRefresh()
            } else {
                usageTokenFromKeychain = false
            }
        }
    }

    @ObservationIgnored private let transcriptIndex = TranscriptIndex()
    @ObservationIgnored private let eventsStore = SessionEventsStore()
    @ObservationIgnored private lazy var monitor = SessionMonitor(
        transcriptIndex: transcriptIndex, eventsStore: eventsStore
    )
    @ObservationIgnored private let usageReader = StatuslineUsageReader()
    @ObservationIgnored private let oauthFetcher = OAuthUsageFetcher()
    @ObservationIgnored private var oauthTask: Task<Void, Never>?
    @ObservationIgnored private let notifier = NotificationManager()
    @ObservationIgnored private let tailParser = TranscriptTailParser()
    @ObservationIgnored private let endedTitleResolver = SessionTitleResolver()
    @ObservationIgnored private var trackedTranscripts: Set<URL> = []
    @ObservationIgnored private var dayStart = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var lastTranscriptScan = Date.distantPast
    @ObservationIgnored private var fastTimer: Timer?
    @ObservationIgnored private var sessionsWatcher: DirectoryWatcher?
    @ObservationIgnored private var usageWatcher: DirectoryWatcher?
    @ObservationIgnored private var lastLoggedSummary = ""
    @ObservationIgnored private var lastLoggedUsage = ""
    @ObservationIgnored private var lastHeartbeat = Date.distantPast

    private init() {}

    func start() {
        Task { await notifier.requestAuthorizationIfNeeded() }
        // Last good API reading survives relaunches; the freshest-wins rule
        // in refreshUsage() keeps it unless something newer appears.
        usage = UsageCache.load()
        refreshAll()
        // Drives usage polling from a pasted token, or — only if the user has
        // opted in — a token read from the Keychain. No Keychain touch here
        // unless that opt-in is on.
        startOAuthLoop()

        fastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }

        sessionsWatcher = DirectoryWatcher(url: ClaudePaths.sessionsDir) { [weak self] in
            self?.refreshSessions()
        }
        usageWatcher = DirectoryWatcher(url: StatuslineUsageReader.dataDir) { [weak self] in
            self?.refreshUsage()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.info("woke from sleep, refreshing")
                self?.refreshAll()
            }
        }
    }

    func refreshAll() {
        refreshSessions()
        refreshUsage()
        refreshDayStats()
    }

    // MARK: - Manual token / OAuth usage polling

    /// Reads the live access token from the Keychain and puts it on the
    /// clipboard — the one-click replacement for the `security … | jq | pbcopy`
    /// command. Runs the (potentially prompting) Keychain read off the main
    /// thread so the menu never beachballs.
    func copyAccessTokenToClipboard() {
        Task {
            let token = await ClaudeTokenProvider.shared.validToken()
            guard let token else {
                degradedReason = "Couldn't read the Claude Code token from Keychain"
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(token, forType: .string)
            degradedReason = nil
            Log.info("copied access token to clipboard (\(token.count) chars)")
        }
    }

    // MARK: - In-app OAuth sign-in

    /// Opens the Claude authorize page in the browser and arms the flow to
    /// accept the code the callback page shows. Independent of the CLI: the
    /// resulting token is stored in ClaudeBar's own Keychain item.
    func beginSignIn() {
        let login = ClaudeOAuth.begin()
        pendingLogin = login
        awaitingSignInCode = true
        useKeychainToken = true
        degradedReason = "Log in via the browser, copy the code it shows, then click \u{201C}Paste sign-in code\u{201D}"
        NSWorkspace.shared.open(login.url)
        Log.info("oauth login: opened authorize URL, awaiting code")
    }

    /// Finishes sign-in with the `code#state` the user copied from the browser.
    func completeSignInFromClipboard() {
        guard let login = pendingLogin else { return }
        let pasted = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task {
            switch await ClaudeOAuth.complete(pasted: pasted, login: login) {
            case .success(let creds):
                await ClaudeTokenProvider.shared.adopt(creds)
                pendingLogin = nil
                awaitingSignInCode = false
                degradedReason = nil
                Log.info("oauth login: success")
                startOAuthLoop()
                requestImmediateUsageRefresh()
            case .failure(let error):
                degradedReason = error.userMessage
                Log.error("oauth login: \(error.userMessage)")
            }
        }
    }

    func cancelSignIn() {
        pendingLogin = nil
        awaitingSignInCode = false
        degradedReason = nil
    }

    func pasteTokenFromClipboard() {
        let pasted = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pasted, pasted.count > 20, !pasted.contains(" ") else {
            degradedReason = "Clipboard doesn't look like a token"
            return
        }
        ManualTokenStore.set(pasted)
        Log.info("manual usage token set (\(pasted.count) chars)")
        startOAuthLoop()
        requestImmediateUsageRefresh()
    }

    func clearToken() {
        ManualTokenStore.set(nil)
        manualTokenState = .none
        Log.info("manual usage token cleared")
    }

    /// The token used for the usage API: the Keychain token wins (self-refreshed
    /// when expired, so it stays valid even during desktop-only stretches), a
    /// manually-pasted token is the fallback when the read is denied. The
    /// provider is an actor and may spawn a `security` subprocess / refresh
    /// request, so this never touches the main thread synchronously.
    private func resolveUsageToken(forceRefresh: Bool = false) async -> (token: String, fromKeychain: Bool)? {
        // Only reach into the Keychain when the user has explicitly opted in,
        // so a Keychain prompt is never raised unprompted at launch.
        if useKeychainToken {
            if let keychain = await ClaudeTokenProvider.shared.validToken(forceRefresh: forceRefresh) {
                return (keychain, true)
            }
        }
        if let manual = ManualTokenStore.token { return (manual, false) }
        return nil
    }

    /// Normal poll cadence. The endpoint rate-limits aggressively, so this
    /// stays conservative and 429s back off exponentially. The next-allowed
    /// fetch time is persisted so relaunches can't hammer the endpoint.
    private static let usagePollInterval: TimeInterval = 180
    private static let nextFetchKey = "nextUsageFetchAt"
    @ObservationIgnored private var consecutiveRateLimits = 0

    private func setNextFetch(after seconds: TimeInterval) {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970 + seconds, forKey: Self.nextFetchKey
        )
    }

    private func startOAuthLoop() {
        guard oauthTask == nil else { return }
        oauthTask = Task { [weak self] in
            while !Task.isCancelled {
                let next = UserDefaults.standard.double(forKey: AppState.nextFetchKey)
                let wait = next - Date().timeIntervalSince1970
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    if Task.isCancelled { return }
                }
                guard let self else { return }
                await self.refreshUsageFromAPI()
            }
        }
    }

    /// Manual refresh: also nudge the API poll, but never bypass the
    /// rate-limit cooldown.
    func requestImmediateUsageRefresh() {
        let next = UserDefaults.standard.double(forKey: Self.nextFetchKey)
        guard Date().timeIntervalSince1970 >= next else { return }
        Task { await refreshUsageFromAPI() }
    }

    private func refreshUsageFromAPI() async {
        guard let resolved = await resolveUsageToken() else {
            // No token anywhere — idle the loop without hammering anything.
            manualTokenState = .none
            setNextFetch(after: Self.usagePollInterval)
            return
        }
        switch await oauthFetcher.fetch(token: resolved.token) {
        case .success(let report):
            usage = report
            UsageCache.save(report)
            degradedReason = nil
            consecutiveRateLimits = 0
            manualTokenState = .active
            usageTokenFromKeychain = resolved.fromKeychain
            setNextFetch(after: Self.usagePollInterval)
            let five = report.fiveHour.map { "\(Int($0.utilization.rounded()))%" } ?? "n/a"
            let seven = report.sevenDay.map { "\(Int($0.utilization.rounded()))%" } ?? "n/a"
            Log.info("usage: source=api five_hour=\(five) seven_day=\(seven)")
            notifier.evaluate(usage: usage, sessions: sessions)
        case .failure(.unauthorized):
            if resolved.fromKeychain {
                // The token can be rejected before its clock-expiry (e.g. a
                // server-side rotation). Force a refresh via the stored refresh
                // token now and retry shortly, rather than hard-stopping.
                _ = await ClaudeTokenProvider.shared.validToken(forceRefresh: true)
                degradedReason = "Keychain usage token expired — refreshing"
                setNextFetch(after: 10)
                Log.error("usage api: keychain token rejected, forcing token refresh")
            } else {
                manualTokenState = .expired
                degradedReason = OAuthUsageFetcher.FetchError.unauthorized.userMessage
                Log.error("usage api: manual token rejected, stopping polls")
                oauthTask?.cancel()
                oauthTask = nil
            }
        case .failure(.rateLimited):
            consecutiveRateLimits += 1
            let cooldown = min(300 * pow(2, Double(consecutiveRateLimits - 1)), 1800)
            setNextFetch(after: cooldown)
            degradedReason = "usage API rate-limited — retrying in \(Int(cooldown / 60))m"
            Log.error("usage api: rate-limited, cooling down \(Int(cooldown))s")
        case .failure(let error):
            // Transient — keep the loop running, keep last good data.
            setNextFetch(after: Self.usagePollInterval)
            Log.error("usage api: \(error.userMessage)")
        }
    }

    /// Token/cost totals from transcript files: a Today aggregate
    /// (timestamp-filtered) plus per-session lifetime totals, both fed by
    /// the same byte-offset tail pass. Tracked files are those modified
    /// today plus every live session's transcript.
    func refreshDayStats() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        if today != dayStart {
            // Midnight rollover — re-read everything fresh.
            dayStart = today
            dayStats = .empty
            sessionStats = [:]
            sessionLifetimeStats = [:]
            tailParser.resetAll()
            trackedTranscripts = []
            lastTranscriptScan = .distantPast
        }

        if now.timeIntervalSince(lastTranscriptScan) > 60 {
            lastTranscriptScan = now
            trackedTranscripts.formUnion(transcriptsModified(since: dayStart))
        }
        // Live sessions are tracked even when their transcript predates today.
        for session in sessions {
            if let url = transcriptIndex.url(for: session.sessionId, cwd: session.cwd) {
                trackedTranscripts.insert(url)
            }
        }

        var day = dayStats
        var perSessionToday = sessionStats
        var perSessionLifetime = sessionLifetimeStats
        var changed = false
        for url in trackedTranscripts {
            let events = tailParser.newEvents(in: url)
            guard !events.isEmpty else { continue }
            changed = true
            let sessionId = url.deletingPathExtension().lastPathComponent
            var lifetime = perSessionLifetime[sessionId] ?? .empty
            var todayShare = perSessionToday[sessionId] ?? .empty
            for event in events {
                lifetime.add(event)
                if (event.timestamp ?? now) >= dayStart {
                    todayShare.add(event)
                    day.add(event)
                }
            }
            perSessionLifetime[sessionId] = lifetime
            perSessionToday[sessionId] = todayShare
        }
        if changed {
            dayStats = day
            sessionStats = perSessionToday
            sessionLifetimeStats = perSessionLifetime
        }
        rebuildEndedSessions(now: now)
        logDayStats()
    }

    @ObservationIgnored private var lastDayStatsLog = ""
    private func logDayStats() {
        guard dayStats.messageCount > 0 else { return }
        let line = "today: tokens=\(dayStats.totalTokens) messages=\(dayStats.messageCount)"
            + String(format: " cost=$%.2f", dayStats.costUSD)
        if line != lastDayStatsLog {
            Log.info(line)
            lastDayStatsLog = line
        }
    }

    /// Synthesizes Session entries for today's transcripts with no live
    /// process, using context captured while tailing them for costs.
    private func rebuildEndedSessions(now: Date) {
        let liveIds = Set(sessions.map(\.sessionId))
        var ended: [Session] = []
        for url in trackedTranscripts {
            let sessionId = url.deletingPathExtension().lastPathComponent
            guard !liveIds.contains(sessionId),
                  let todayShare = sessionStats[sessionId], todayShare.messageCount > 0
            else { continue }
            let meta = tailParser.metadata(for: url)
            let cwd = meta?.cwd ?? ""
            let lastActivity = transcriptIndex.lastActivity(of: url)
            ended.append(Session(
                pid: 0,
                sessionId: sessionId,
                cwd: cwd,
                startedAt: lastActivity ?? now,
                entrypoint: Entrypoint(rawValue: meta?.entrypoint),
                title: endedTitleResolver.title(forSessionId: sessionId, transcriptURL: url),
                desktopSessionId: endedTitleResolver.desktopSessionId(forSessionId: sessionId),
                state: .ended,
                lastTranscriptActivity: lastActivity,
                lastInteraction: lastActivity,
                isDormant: false,
                gitBranch: meta?.gitBranch,
                display: cwd.isEmpty
                    ? ProjectDisplay(project: "unknown project", detail: nil)
                    : Formatters.projectDisplay(cwd: cwd)
            ))
        }
        ended.sort { ($0.lastInteraction ?? .distantPast) > ($1.lastInteraction ?? .distantPast) }
        if ended != endedSessions {
            endedSessions = ended
        }
    }

    private func transcriptsModified(since cutoff: Date) -> Set<URL> {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudePaths.projectsDir, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var result: Set<URL> = []
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let mtime, mtime >= cutoff {
                    result.insert(file)
                }
            }
        }
        return result
    }

    func refreshUsage() {
        // Freshest source wins: a statusline capture only replaces what we
        // have if it's newer (the API poll usually is).
        if let report = usageReader.read(), report.source.asOf > (usage?.source.asOf ?? .distantPast) {
            // Statusline carries only the 5h/weekly windows — never the credit
            // balance or Sonnet window. With active terminals it's often the
            // freshest source, so a blind replace would flicker those rows out
            // every few seconds. Carry the last known values forward; a fresh
            // API poll still overwrites them authoritatively (incl. clearing).
            usage = UsageReport(
                fiveHour: report.fiveHour,
                sevenDay: report.sevenDay,
                sevenDaySonnet: report.sevenDaySonnet ?? usage?.sevenDaySonnet,
                credit: report.credit ?? usage?.credit,
                source: report.source
            )
            degradedReason = nil
            let five = report.fiveHour.map { "\(Int($0.utilization.rounded()))%" } ?? "n/a"
            let seven = report.sevenDay.map { "\(Int($0.utilization.rounded()))%" } ?? "n/a"
            let line = "usage: source=statusline five_hour=\(five) seven_day=\(seven)"
            if line != lastLoggedUsage {
                Log.info(line)
                lastLoggedUsage = line
            }
        }
        // No file yet (hook hasn't fired) or no rate_limits in the capture:
        // keep whatever we last had; the UI explains the empty state.
        notifier.evaluate(usage: usage, sessions: sessions)
    }

    func refreshSessions() {
        let snapshot = monitor.snapshot()
        if snapshot != sessions {
            sessions = snapshot
        }
        logStateSummary()
        notifier.evaluate(usage: usage, sessions: sessions)
    }

    var anySessionWaiting: Bool {
        sessions.contains { if case .waiting = $0.state { return true } else { return false } }
    }

    /// Sessions that entered waiting recently. Only these pin the menu bar —
    /// a prompt forgotten for days stays orange in the list but shouldn't
    /// hold the menu bar's attention state forever.
    var recentlyWaiting: Bool {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        return sessions.contains { session in
            guard case .waiting = session.state else { return false }
            return (session.lastInteraction ?? session.startedAt) > cutoff
        }
    }

    /// True while the menu bar label overrides the user's compact style.
    var menuBarAttention: Bool {
        recentlyWaiting || (usage?.fiveHour?.utilization ?? 0) >= 90
    }

    var currentSessions: [Session] { sessions.filter { !$0.isDormant } }
    var dormantSessions: [Session] { sessions.filter(\.isDormant) }

    /// One-line summary, written when state changes and as a 30s heartbeat.
    /// scripts/verify.sh greps these lines — keep the format stable.
    private func logStateSummary() {
        let counts = Dictionary(grouping: sessions, by: { $0.state.logToken })
        let detail = sessions
            .map { "\($0.pid):\($0.entrypoint.displayName):\($0.isDormant ? "dormant" : $0.state.logToken)" }
            .joined(separator: " ")
        let summary = "state: sessions=\(sessions.count)"
            + " waiting=\(counts["waiting"]?.count ?? 0)"
            + " active=\(counts["active"]?.count ?? 0)"
            + " idle=\(counts["idle"]?.count ?? 0)"
            + " dormant=\(dormantSessions.count)"
            + (detail.isEmpty ? "" : " [\(detail)]")

        let now = Date()
        if summary != lastLoggedSummary || now.timeIntervalSince(lastHeartbeat) > 30 {
            Log.info(summary)
            lastLoggedSummary = summary
            lastHeartbeat = now
        }
    }
}
