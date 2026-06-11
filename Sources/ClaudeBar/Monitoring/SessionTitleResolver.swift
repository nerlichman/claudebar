import Foundation

/// Human-readable session titles and desktop session ids. Primary source:
/// the desktop app's session metadata (`local_*.json`, keyed by
/// cliSessionId). Title fallback: the `slug` field Claude Code writes into
/// transcripts, de-kebabed.
final class SessionTitleResolver {
    private struct DesktopMeta {
        var title: String?
        var localId: String?
        var lastFocusedAt: Double
    }

    private static let desktopSessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    private let fm = FileManager.default
    private var metaByCliId: [String: DesktopMeta] = [:]
    private var indexBuiltAt = Date.distantPast
    private var slugCache: [String: (value: String?, at: Date)] = [:]

    func title(forSessionId sessionId: String, transcriptURL: URL?) -> String? {
        rebuildIndexIfNeeded()
        if let title = metaByCliId[sessionId]?.title { return title }
        return slug(forSessionId: sessionId, transcriptURL: transcriptURL)
    }

    /// The desktop app's `local_…` id for a CLI session, used to deep-link
    /// straight to the session view. Nil for sessions the desktop app
    /// doesn't know about (pure CLI / VS Code).
    func desktopSessionId(forSessionId sessionId: String) -> String? {
        rebuildIndexIfNeeded()
        return metaByCliId[sessionId]?.localId
    }

    private func rebuildIndexIfNeeded() {
        guard Date().timeIntervalSince(indexBuiltAt) > 60 else { return }
        indexBuiltAt = Date()

        var map: [String: DesktopMeta] = [:]
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        if let enumerator = fm.enumerator(
            at: Self.desktopSessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator
            where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let mtime, mtime > cutoff else { continue }
                guard let data = try? Data(contentsOf: url),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let cliId = json["cliSessionId"] as? String
                else { continue }
                let focusedAt = json["lastFocusedAt"] as? Double ?? 0
                let isArchived = json["isArchived"] as? Bool ?? false
                let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let localId = isArchived ? nil : json["sessionId"] as? String

                // Duplicate cliSessionIds happen (e.g. a re-imported
                // transcript) — keep the most recently focused entry.
                var entry = map[cliId] ?? DesktopMeta(title: nil, localId: nil, lastFocusedAt: -1)
                if focusedAt > entry.lastFocusedAt {
                    entry.lastFocusedAt = focusedAt
                    if let title { entry.title = title }
                    if let localId { entry.localId = localId }
                }
                if entry.title == nil { entry.title = title }
                if entry.localId == nil { entry.localId = localId }
                map[cliId] = entry
            }
        }
        metaByCliId = map
    }

    /// Last `"slug":"..."` in the transcript's tail, de-kebabed
    /// ("fix-login-bug" → "Fix login bug").
    private func slug(forSessionId sessionId: String, transcriptURL: URL?) -> String? {
        if let cached = slugCache[sessionId], Date().timeIntervalSince(cached.at) < 120 {
            return cached.value
        }
        let value = readSlug(from: transcriptURL)
        slugCache[sessionId] = (value, Date())
        return value
    }

    private func readSlug(from url: URL?) -> String? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 8192 ? size - 8192 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        // The chunk may start mid-codepoint — decode lossily.
        let text = String(decoding: data, as: UTF8.self)
        guard let marker = text.range(of: "\"slug\":\"", options: .backwards) else { return nil }
        let after = text[marker.upperBound...]
        guard let endQuote = after.firstIndex(of: "\""), marker.upperBound < endQuote else { return nil }
        let slug = String(after[..<endQuote])
        guard !slug.isEmpty, slug.count < 120 else { return nil }
        let words = slug.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
