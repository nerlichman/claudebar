import Foundation

/// Reads the per-session lifecycle events recorded by claudebar-hook.sh
/// (Claude Code hooks: start/prompt/stop/notification/end). These tell us
/// when the user last actually interacted with a session — something process
/// liveness alone can't.
final class SessionEventsStore {
    struct Event {
        let name: String
        let timestamp: Date
    }

    static let eventsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeBar/events", isDirectory: true)

    private let fm = FileManager.default

    init() {
        try? fm.createDirectory(at: Self.eventsDir, withIntermediateDirectories: true)
        pruneOldFiles()
    }

    func event(forSessionId sessionId: String) -> Event? {
        let url = Self.eventsDir.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["event"] as? String
        else { return nil }
        let ts: Date
        switch json["ts"] {
        case let seconds as Double: ts = Date(timeIntervalSince1970: seconds)
        case let seconds as Int: ts = Date(timeIntervalSince1970: Double(seconds))
        default: return nil
        }
        return Event(name: name, timestamp: ts)
    }

    /// Event files for sessions ended long ago are useless — drop anything
    /// older than 7 days. This directory belongs to ClaudeBar, not Claude Code.
    private func pruneOldFiles() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        guard let files = try? fm.contentsOfDirectory(
            at: Self.eventsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mtime, mtime < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
