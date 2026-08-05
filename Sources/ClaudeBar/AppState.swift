import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    enum UsageTokenState: Equatable {
        /// `rateLimited` is a working login we temporarily can't renew — distinct
        /// from `active` so the UI can offer a sign-in as the way out, and from
        /// `expired` so it doesn't claim the login is gone when it isn't.
        case none, active, expired, rateLimited
    }

    var sessions: [Session] = []
    var usage: UsageReport?
    var dayStats: DayStats = .empty
    /// Rolling last-7-days token/cost estimate from local transcripts. Same
    /// source and pricing as `dayStats`, wider window — see refreshWeekStats().
    var weekStats: DayStats = .empty
    /// Today's token/cost totals per sessionId — same date filter as
    /// dayStats, so visible rows sum (roughly) to the Today section.
    var sessionStats: [String: DayStats] = [:]
    /// Full-transcript totals per sessionId, shown in row tooltips.
    var sessionLifetimeStats: [String: DayStats] = [:]
    /// Sessions that did work today but whose process is gone (the desktop
    /// app kills session processes when you navigate away).
    var endedSessions: [Session] = []
    var degradedReason: String?
    var usageTokenState: UsageTokenState = .none
    /// True while an in-app OAuth sign-in is waiting for the user to paste the
    /// code back from the browser — drives the settings UI.
    var awaitingSignInCode = false
    @ObservationIgnored private var pendingLogin: ClaudeOAuth.PendingLogin?
    @ObservationIgnored private var loopbackWait: Task<Void, Never>?
    /// Prevents overlapping sign-in completions (the paste row stays open).
    @ObservationIgnored private var isCompletingSignIn = false
    /// Whether to read a token from the Keychain for usage polling. Enabled by
    /// signing in or by opting into the Claude Code (terminal) token; off by
    /// default so the app never raises a Keychain prompt unprompted.
    var useKeychainToken: Bool = UserDefaults.standard.bool(forKey: "useKeychainToken") {
        didSet {
            UserDefaults.standard.set(useKeychainToken, forKey: "useKeychainToken")
            if useKeychainToken { resumeUsagePollingNow() }
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
    @ObservationIgnored private let weekStatsCache = TranscriptStatsCache()
    @ObservationIgnored private let endedTitleResolver = SessionTitleResolver()
    @ObservationIgnored private let lineage = TranscriptLineageIndex()
    @ObservationIgnored private var trackedTranscripts: Set<URL> = []
    /// Totals per transcript file, not per session. Which session a file's spend
    /// is shown under depends on the other files present — a rewound
    /// conversation leaves several snapshots and only the newest reports — so
    /// attribution is re-derived on every pass instead of accumulated.
    @ObservationIgnored private var fileToday: [URL: DayStats] = [:]
    @ObservationIgnored private var fileLifetime: [URL: DayStats] = [:]
    @ObservationIgnored private var pendingPublish = true
    @ObservationIgnored private var dayStart = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var lastTranscriptScan = Date.distantPast
    @ObservationIgnored private var lastWeekScan = Date.distantPast
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
        // usageTokenState only flips to .active after a live poll succeeds, but
        // that first poll is deferred by the persisted fetch throttle (up to a
        // full poll interval). Without this, an already-signed-in user who opens
        // the menu right after launch sees "Sign in to Claude…" until the poll
        // lands — reading a pending window as signed-out. We have a
        // self-refreshing token in the Keychain, so reflect that now; the poll
        // downgrades to .expired/.none only if the token turns out unusable.
        if useKeychainToken { usageTokenState = .active }
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
        refreshWeekStats()
    }

    // MARK: - In-app OAuth sign-in

    /// Opens the Claude authorize page in the browser and arms the flow to
    /// accept the code the callback page shows. Independent of the CLI: the
    /// resulting token is stored in ClaudeBar's own Keychain item.
    func beginSignIn() {
        let login = ClaudeOAuth.begin()
        pendingLogin?.server?.stop()
        pendingLogin = login
        awaitingSignInCode = true
        useKeychainToken = true
        let automatic = login.server != nil
        degradedReason = automatic
            ? "Approve the sign-in in your browser — it comes straight back here"
            : "Log in via the browser, copy the code it shows, then click \u{201C}Paste sign-in code\u{201D}"
        NSWorkspace.shared.open(login.url)
        Log.info("oauth login: opened authorize URL (\(automatic ? "loopback :\(login.server!.port)" : "paste"))")

        // The paste row stays available throughout: if the browser never comes
        // back, or the listener dies, the manual path is still there.
        guard automatic else { return }
        loopbackWait?.cancel()
        loopbackWait = Task { [weak self] in
            guard let result = await ClaudeOAuth.completeViaLoopback(login: login) else { return }
            guard let self, self.pendingLogin?.state == login.state else { return }
            self.finishSignIn(result, source: "loopback")
        }
    }

    /// Finishes sign-in with the `code#state` the user copied from the browser.
    func completeSignInFromClipboard() {
        guard let login = pendingLogin, !isCompletingSignIn else { return }
        // A fresh sign-in is a separate authorization_code grant and the only way
        // to recover a dead token, so it must NOT be gated by the refresh cooldown.
        let pasted = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isCompletingSignIn = true
        degradedReason = "Checking sign-in code…"
        Task {
            defer { isCompletingSignIn = false }
            finishSignIn(await ClaudeOAuth.complete(pasted: pasted, login: login), source: "paste")
        }
    }

    /// Shared tail of both sign-in paths — the loopback callback and the pasted
    /// code end in exactly the same place.
    private func finishSignIn(
        _ result: Result<ClaudeCredentials.Credentials, ClaudeOAuth.ExchangeError>, source: String
    ) {
        switch result {
        case .success(let creds):
            Task { await ClaudeTokenProvider.shared.adopt(creds) }
            pendingLogin?.server?.stop()
            pendingLogin = nil
            awaitingSignInCode = false
            degradedReason = nil
            consecutiveKeychainAuthFailures = 0
            Log.info("oauth login: success (\(source))")
            resumeUsagePollingNow()
        case .failure(let error):
            // A throttled/down endpoint shows up as a 429, not a bad code.
            if ClaudeCredentials.isTokenEndpointCoolingDown() {
                degradedReason = "Claude's sign-in service is rate-limited or down right now — try again later"
            } else {
                degradedReason = error.userMessage
            }
            Log.error("oauth login: \(error.userMessage) (\(source))")
        }
    }

    func cancelSignIn() {
        loopbackWait?.cancel()
        loopbackWait = nil
        pendingLogin?.server?.stop()
        pendingLogin = nil
        awaitingSignInCode = false
        degradedReason = nil
    }

    /// Opt into the Claude Code (terminal) token without an in-app sign-in: start
    /// reading the Keychain, where `validToken` prefers our own credential and
    /// falls back to the CLI's read-only.
    func useClaudeCodeToken() {
        consecutiveKeychainAuthFailures = 0
        useKeychainToken = true
    }

    /// The token used for the usage API, read from the Keychain (self-refreshed
    /// when expired, so it stays valid even during desktop-only stretches). The
    /// provider is an actor and may spawn a `security` subprocess / refresh
    /// request, so this never touches the main thread synchronously.
    private func resolveUsageToken() async -> String? {
        // Only reach into the Keychain once the user has opted in (signed in or
        // chosen the terminal token), so a prompt is never raised unprompted.
        guard useKeychainToken else { return nil }
        return await ClaudeTokenProvider.shared.validToken()
    }

    /// Poll cadence adapts to activity: tight while a session is actively
    /// working (so the 5-hour/weekly % keeps up), relaxed when idle to spare
    /// the rate-limited endpoint. 429s still back off exponentially, and the
    /// next-allowed fetch time is persisted so relaunches can't hammer it.
    private static let activePollInterval: TimeInterval = 60
    private static let idlePollInterval: TimeInterval = 180
    /// Interval for the *next* scheduled poll, chosen by current activity.
    private var usagePollInterval: TimeInterval {
        hasActiveSession ? Self.activePollInterval : Self.idlePollInterval
    }
    /// Any session actively producing output right now (not idle/waiting/ended).
    private var hasActiveSession: Bool { sessions.contains { $0.state == .active } }
    /// Rising-edge tracker so only the idle→active transition nudges the poll.
    @ObservationIgnored private var hadActiveSession = false
    private static let nextFetchKey = "nextUsageFetchAt"
    /// Usage-429 backoff ramp, held at the last step.
    private static let rateLimitCooldowns: [TimeInterval] = [60, 300, 600, 900]
    @ObservationIgnored private var consecutiveRateLimits = 0
    /// Consecutive 401s on a Keychain token: the 1st forces a refresh, a repeat
    /// means the refresh token is dead → ask for re-auth.
    @ObservationIgnored private var consecutiveKeychainAuthFailures = 0
    /// Single-flight guard so a manual nudge can't fetch alongside the loop.
    @ObservationIgnored private var isFetchingUsage = false

    private func setNextFetch(after seconds: TimeInterval) {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970 + seconds, forKey: Self.nextFetchKey
        )
    }


    /// Resume polling now after a deliberate recovery (sign-in / paste / opt-in):
    /// drop any parked back-off timer and restart the loop, which may otherwise be
    /// asleep on a long deferral a one-shot nudge can't interrupt.
    private func resumeUsagePollingNow() {
        consecutiveRateLimits = 0
        setNextFetch(after: 0)
        oauthTask?.cancel()
        oauthTask = nil
        startOAuthLoop()
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

    @ObservationIgnored private var lastManualFetch = Date.distantPast

    /// A user-initiated nudge (Refresh button): skip the normal poll spacing so a
    /// click does something, but still respect an active rate-limit / cooldown
    /// penalty (clicking through a 429 only resets the server's window) and a 15s
    /// debounce. Recovery actions use `resumeUsagePollingNow` instead.
    func requestImmediateUsageRefresh() {
        let now = Date()
        let remaining = UserDefaults.standard.double(forKey: Self.nextFetchKey) - now.timeIntervalSince1970
        guard remaining <= Self.idlePollInterval,
              consecutiveRateLimits == 0,
              !ClaudeCredentials.isTokenEndpointCoolingDown(),
              now.timeIntervalSince(lastManualFetch) >= 15
        else { return }
        lastManualFetch = now
        setNextFetch(after: 0)
        Task { await refreshUsageFromAPI() }
    }

    private func refreshUsageFromAPI() async {
        // A fetch is already in flight; let it own the schedule (and avoid a spin).
        if isFetchingUsage {
            setNextFetch(after: usagePollInterval)
            return
        }
        isFetchingUsage = true
        defer { isFetchingUsage = false }
        guard let token = await resolveUsageToken() else {
            // No usable Keychain token — idle the loop without hammering anything.
            usageTokenState = .none
            setNextFetch(after: Self.idlePollInterval)
            return
        }
        switch await oauthFetcher.fetch(token: token) {
        case .success(let report):
            usage = report
            UsageCache.save(report)
            degradedReason = nil
            consecutiveRateLimits = 0
            consecutiveKeychainAuthFailures = 0
            usageTokenState = .active
            setNextFetch(after: usagePollInterval)
            let five = report.fiveHour.map { "\(Int($0.utilization.rounded()))%" } ?? "n/a"
            let seven = report.sevenDay.map { "\(Int($0.utilization.rounded()))%" } ?? "n/a"
            let perModel = report.perModelWeekly
                .map { "\($0.model)=\(Int($0.window.utilization.rounded()))%" }
                .joined(separator: ",")
            Log.info("usage: source=api five_hour=\(five) seven_day=\(seven) per_model=[\(perModel)]")
            notifier.evaluate(usage: usage, sessions: sessions)
        case .failure(.unauthorized):
            if ClaudeCredentials.isRefreshTokenDead() {
                // Nothing to retry: the server has forgotten the refresh token and
                // only a new sign-in can mint another. Say so and stop polling,
                // rather than rediscovering it every few minutes.
                usageTokenState = .expired
                degradedReason = "Sign in to Claude again — Claude no longer recognizes the saved login"
                setNextFetch(after: Self.idlePollInterval)
                return
            }
            if ClaudeCredentials.isTokenEndpointCoolingDown() {
                // Can't renew until the penalty clears — park the poll until then.
                let remaining = ClaudeCredentials.tokenCooldownRemaining()
                usageTokenState = .rateLimited
                degradedReason = "Can't refresh the saved login yet (endpoint rate-limited) — auto-retry in \(Int(remaining / 60) + 1)m, or sign in again"
                setNextFetch(after: remaining + 5)
                Log.error("usage api: token endpoint cooling down, deferring \(Int(remaining))s")
                return
            }
            consecutiveKeychainAuthFailures += 1
            if consecutiveKeychainAuthFailures == 1 {
                // May have aged out early (server-side rotation) — force a
                // refresh of our own item and retry shortly.
                _ = await ClaudeTokenProvider.shared.validToken(forceRefresh: true)
                degradedReason = "Keychain usage token expired — refreshing"
                setNextFetch(after: 15)
                Log.error("usage api: keychain token rejected, forcing token refresh")
            } else {
                // Refresh didn't help — the refresh token is dead; ask for re-auth.
                usageTokenState = .expired
                degradedReason = "Sign in to Claude again — saved login expired"
                setNextFetch(after: Self.idlePollInterval)
                Log.error("usage api: keychain token still rejected after refresh, asking for re-auth")
            }
        case .failure(.rateLimited):
            consecutiveRateLimits += 1
            let idx = min(consecutiveRateLimits, Self.rateLimitCooldowns.count) - 1
            let cooldown = Self.rateLimitCooldowns[idx]
            setNextFetch(after: cooldown)
            // A 429 means the token is valid but throttled — keep the label active.
            usageTokenState = .active
            degradedReason = "usage API rate-limited — retrying in \(Int(cooldown / 60))m"
            Log.error("usage api: rate-limited, cooling down \(Int(cooldown))s")
        case .failure(let error):
            // Transient — keep the loop running, keep last good data.
            setNextFetch(after: Self.idlePollInterval)
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
            resetDayAggregation()
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

        // A rewind snapshot is created after the session it copies, so the pass
        // that first sees it has already credited that shared history to the
        // older file. Re-running with the new file in hand re-attributes it, and
        // one retry always suffices: every file is known before it begins, so
        // the newest of each lineage is read first and nothing can supersede it.
        if ingest(now: now) {
            resetDayAggregation()
            _ = ingest(now: now)
        }

        publishDayStats()
        rebuildEndedSessions(now: now)
        logDayStats()
    }

    /// Folds newly appended events into their file's totals. Returns true when a
    /// file turned out to own history already credited to an older snapshot of
    /// the same conversation, which only a restart can fix.
    private func ingest(now: Date) -> Bool {
        for url in lineage.newestFirst(trackedTranscripts) {
            let events = tailParser.newEvents(in: url)
            guard !events.isEmpty else { continue }
            pendingPublish = true
            var today = fileToday[url] ?? .empty
            var lifetime = fileLifetime[url] ?? .empty
            for event in events {
                switch lineage.claim(event.messageId, for: url) {
                case .alreadyBilled: continue
                case .supersededOwner: return true
                case .fresh: break
                }
                lifetime.add(event)
                if (event.timestamp ?? now) >= dayStart {
                    today.add(event)
                }
            }
            fileToday[url] = today
            fileLifetime[url] = lifetime
        }
        return false
    }

    /// Rolls per-file totals up onto the session each one is shown under. Skipped
    /// when no transcript grew, since attribution can only change when one does.
    private func publishDayStats() {
        guard pendingPublish else { return }
        pendingPublish = false
        var day = DayStats.empty
        var perSessionToday: [String: DayStats] = [:]
        var perSessionLifetime: [String: DayStats] = [:]
        for (url, stats) in fileToday {
            day.merge(stats)
            perSessionToday[attributionSessionId(for: url), default: .empty].merge(rewoundAware(stats, url))
        }
        for (url, stats) in fileLifetime {
            perSessionLifetime[attributionSessionId(for: url), default: .empty].merge(rewoundAware(stats, url))
        }
        if dayStats != day { dayStats = day }
        if sessionStats != perSessionToday { sessionStats = perSessionToday }
        if sessionLifetimeStats != perSessionLifetime { sessionLifetimeStats = perSessionLifetime }
    }

    /// Everything an abandoned snapshot still accounts for is, by definition,
    /// requests that survive in no descendant — the ones the user rewound away.
    /// Subagent transcripts are exempt: a rewind leaves them in the old session's
    /// directory without copying them forward, so their absence from the newer
    /// file says nothing about whether their work was discarded.
    private func rewoundAware(_ stats: DayStats, _ url: URL) -> DayStats {
        guard !Self.isSubagentTranscript(url), !lineage.isRepresentative(url) else { return stats }
        var marked = stats
        marked.markRewound()
        return marked
    }

    private func resetDayAggregation() {
        tailParser.resetAll()
        lineage.reset()
        fileToday = [:]
        fileLifetime = [:]
        dayStats = .empty
        sessionStats = [:]
        sessionLifetimeStats = [:]
        pendingPublish = true
    }

    /// The session a transcript's spend is reported under: its lineage's newest
    /// snapshot, so a conversation the user rewound reports once, on the row they
    /// are still in. Subagent transcripts resolve through their parent session
    /// first — a rewind leaves them behind in the old session's directory, and
    /// their tokens belong with the conversation that continued.
    private func attributionSessionId(for url: URL) -> String {
        Self.owningSessionId(forTranscript: lineage.representative(of: Self.topLevelTranscript(for: url)))
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

    /// Current-calendar-week cost/token estimate from local transcripts.
    /// Unlike the live, incrementally-tailed Today aggregate, this window has
    /// a moving lower bound (old events fall out at the week boundary), which
    /// an append-only tail can't express. `weekStatsCache` keeps it cheap: it
    /// parses each file once into per-day buckets keyed on (mtime, size), so a
    /// pass only re-reads the transcripts that actually changed — throttled to
    /// a few minutes on top (timer: 2s).
    func refreshWeekStats(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWeekScan) > 180 else { return }
        lastWeekScan = now

        // Start of the current week, honoring the locale's first weekday
        // (Mon/Sun) from System Settings; falls back to start of today.
        let cutoff = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        weekStats = weekStatsCache.totals(since: cutoff, files: transcriptsModified(since: cutoff))
        logWeekStats()
    }

    @ObservationIgnored private var lastWeekStatsLog = ""
    private func logWeekStats() {
        guard weekStats.messageCount > 0 else { return }
        let line = "week: tokens=\(weekStats.totalTokens) messages=\(weekStats.messageCount)"
            + String(format: " cost=$%.2f", weekStats.costUSD)
        if line != lastWeekStatsLog {
            Log.info(line)
            lastWeekStatsLog = line
        }
    }

    /// Synthesizes Session entries for today's transcripts with no live
    /// process, using context captured while tailing them for costs.
    private func rebuildEndedSessions(now: Date) {
        let liveIds = Set(sessions.map(\.sessionId))
        // The top-level transcript per session id supplies its metadata and
        // activity — subagent transcripts (whose tokens fold into the parent's
        // stats) never front a row of their own.
        var parentURL: [String: URL] = [:]
        for url in trackedTranscripts where !Self.isSubagentTranscript(url) {
            parentURL[url.deletingPathExtension().lastPathComponent] = url
        }
        var ended: [Session] = []
        for (sessionId, todayShare) in sessionStats {
            guard !liveIds.contains(sessionId), todayShare.messageCount > 0,
                  let url = parentURL[sessionId]
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
                title: endedTitleResolver.title(forSessionId: sessionId, name: nil, transcriptURL: url),
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

    /// The session a transcript belongs to. Subagent transcripts live at
    /// `<sessionId>/subagents/agent-*.jsonl` and are attributed to their parent
    /// session; top-level transcripts are `<sessionId>.jsonl`.
    static func owningSessionId(forTranscript url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            return parent.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func isSubagentTranscript(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "subagents"
    }

    /// The `<sessionId>.jsonl` a transcript belongs to — itself, or the parent of
    /// a `<sessionId>/subagents/agent-*.jsonl`. Only top-level transcripts take
    /// part in rewind lineages, so subagent files resolve through their parent.
    static func topLevelTranscript(for url: URL) -> URL {
        guard isSubagentTranscript(url) else { return url }
        return url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathExtension("jsonl")
    }

    private func transcriptsModified(since cutoff: Date) -> Set<URL> {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudePaths.projectsDir, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var result: Set<URL> = []
        // Collect .jsonl files in `dir` modified since the cutoff. Session
        // subdirectories are descended one level into their `subagents/` child,
        // whose transcripts hold token usage that never lands in the parent
        // .jsonl — omitting them undercounts subagent-heavy sessions.
        func collect(in dir: URL) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    collect(in: entry.appendingPathComponent("subagents", isDirectory: true))
                } else if entry.pathExtension == "jsonl",
                          let mtime = values?.contentModificationDate, mtime >= cutoff {
                    result.insert(entry)
                }
            }
        }
        for dir in projectDirs { collect(in: dir) }
        return result
    }

    func refreshUsage() {
        // Freshest source wins: a statusline capture only replaces what we
        // have if it's newer (the API poll usually is).
        if let report = usageReader.read(), report.source.asOf > (usage?.source.asOf ?? .distantPast) {
            // Statusline carries only the 5h/weekly windows — rarely the credit
            // balance or per-model windows. With active terminals it's often the
            // freshest source, so a blind replace would flicker those rows out
            // every few seconds. Carry the last known values forward; a fresh
            // API poll still overwrites them authoritatively (incl. clearing).
            usage = UsageReport(
                fiveHour: report.fiveHour,
                sevenDay: report.sevenDay,
                perModelWeekly: report.perModelWeekly.isEmpty
                    ? (usage?.perModelWeekly ?? [])
                    : report.perModelWeekly,
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
        // The moment work starts, tighten the usage poll so the % reflects it
        // instead of waiting out the idle interval. Rising edge only; the poll's
        // own success path then holds the fast cadence while work continues.
        let active = hasActiveSession
        if active && !hadActiveSession { nudgeUsagePollForActivity() }
        hadActiveSession = active
        logStateSummary()
        notifier.evaluate(usage: usage, sessions: sessions)
    }

    /// A session just went active: pull the next usage poll forward to the
    /// active cadence so the % catches up quickly. Never stomps a rate-limit /
    /// cooldown backoff, never schedules sooner than one active interval (so a
    /// flapping session can't hammer the endpoint), and no-ops if a poll is
    /// already due that soon. Restarts the loop so an idle sleep already under
    /// way adopts the shortened schedule instead of waiting it out.
    private func nudgeUsagePollForActivity() {
        guard useKeychainToken,
              consecutiveRateLimits == 0,
              !ClaudeCredentials.isTokenEndpointCoolingDown(),
              !isFetchingUsage else { return }
        let scheduled = UserDefaults.standard.double(forKey: Self.nextFetchKey) - Date().timeIntervalSince1970
        guard scheduled > Self.activePollInterval else { return }
        setNextFetch(after: Self.activePollInterval)
        oauthTask?.cancel()
        oauthTask = nil
        startOAuthLoop()
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
