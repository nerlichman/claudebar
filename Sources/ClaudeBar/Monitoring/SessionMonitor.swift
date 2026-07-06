import Foundation

/// Scans ~/.claude/sessions, filters dead/stale entries, and derives each
/// session's activity state. Read-only: stale files are skipped, never deleted.
final class SessionMonitor {
    /// A transcript modified within this window means Claude is generating.
    static let activeWindow: TimeInterval = 10
    /// Idle sessions with no engagement for this long are demoted to dormant.
    static let dormancyWindow: TimeInterval = 60 * 60
    /// How long a "prompt" hook event keeps a session active without the
    /// transcript moving. An in-flight turn writes the transcript on every
    /// API response and tool result, so the longest legitimate silence is one
    /// slow tool call — minutes, not hours.
    static let promptStalenessWindow: TimeInterval = 15 * 60

    private let transcriptIndex: TranscriptIndex
    private let eventsStore: SessionEventsStore
    private let titleResolver = SessionTitleResolver()
    private let fm = FileManager.default

    init(transcriptIndex: TranscriptIndex, eventsStore: SessionEventsStore) {
        self.transcriptIndex = transcriptIndex
        self.eventsStore = eventsStore
    }

    func snapshot(now: Date = Date()) -> [Session] {
        guard let entries = try? fm.contentsOfDirectory(
            at: ClaudePaths.sessionsDir, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        let decoder = JSONDecoder()
        var sessions: [Session] = []

        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(SessionFile.self, from: data)
            else { continue }
            guard ProcessLiveness.validate(file) else { continue }

            let startedAt = Date(timeIntervalSince1970: file.startedAt / 1000)
            let hookEvent = eventsStore.event(forSessionId: file.sessionId)

            // A SessionEnd hook after this process started means the session
            // is over, even if the host process is still alive (desktop app
            // and VS Code keep them around).
            if let hookEvent, hookEvent.name == "end", hookEvent.timestamp >= startedAt {
                continue
            }

            let transcriptURL = transcriptIndex.url(for: file.sessionId, cwd: file.cwd)
            let lastActivity = transcriptURL.flatMap { transcriptIndex.lastActivity(of: $0) }

            let isGenerating = lastActivity.map { now.timeIntervalSince($0) < Self.activeWindow } ?? false

            let state: ActivityState
            if file.status == "waiting" {
                state = .waiting(reason: file.waitingFor ?? "input")
            } else if let hookEvent, hookEvent.name == "prompt",
                      now.timeIntervalSince(max(hookEvent.timestamp, lastActivity ?? .distantPast))
                        < Self.promptStalenessWindow {
                // The events store holds only the latest lifecycle event, so a
                // "prompt" (UserPromptSubmit) with no following "stop" means the
                // turn is still in flight — Claude is working. The transcript
                // window alone misses this: long thinking, waiting for the first
                // token, or a slow tool/bash call can go >activeWindow seconds
                // without writing the transcript, which would flip a busy
                // session to .idle. But Stop is not guaranteed: it doesn't fire
                // on user interrupts, and desktop sessions have been observed
                // pinned Active for days by an orphaned prompt event. So the
                // prompt only counts while it — or the transcript — is fresh.
                state = .active
            } else if isGenerating {
                state = .active
            } else if hookEvent?.name == "notification" {
                // Desktop and VS Code don't write status:"waiting" into the
                // session file — the Notification hook is the only signal that
                // Claude is blocked on input (permission prompt or idle wait).
                // A live notification stands until the next prompt/stop event
                // overwrites it, so it survives even hours-long waits.
                state = .waiting(reason: file.waitingFor ?? "input")
            } else {
                state = .idle
            }

            let lastInteraction = [
                hookEvent.map(\.timestamp),
                lastActivity,
                file.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            ].compactMap { $0 }.max()

            let isDormant = state == .idle
                && now.timeIntervalSince(lastInteraction ?? startedAt) > Self.dormancyWindow

            sessions.append(Session(
                pid: file.pid,
                sessionId: file.sessionId,
                cwd: file.cwd,
                startedAt: startedAt,
                entrypoint: Entrypoint(rawValue: file.entrypoint),
                title: titleResolver.title(forSessionId: file.sessionId, transcriptURL: transcriptURL),
                desktopSessionId: titleResolver.desktopSessionId(forSessionId: file.sessionId),
                state: state,
                lastTranscriptActivity: lastActivity,
                lastInteraction: lastInteraction,
                isDormant: isDormant,
                gitBranch: Formatters.gitBranch(cwd: file.cwd),
                display: Formatters.projectDisplay(cwd: file.cwd)
            ))
        }

        return sessions.sorted {
            if $0.isDormant != $1.isDormant { return !$0.isDormant }
            if $0.state.sortRank != $1.state.sortRank { return $0.state.sortRank < $1.state.sortRank }
            return ($0.lastInteraction ?? $0.startedAt) > ($1.lastInteraction ?? $1.startedAt)
        }
    }
}
