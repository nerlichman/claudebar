import Foundation

/// Human-readable session titles. Primary source: the desktop app's session
/// metadata (`local_*.json`, keyed by cliSessionId). Fallback: the `slug`
/// field Claude Code writes into transcripts, de-kebabed.
final class SessionTitleResolver {
    private static let desktopSessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    private let fm = FileManager.default
    private var titlesByCliId: [String: String] = [:]
    private var indexBuiltAt = Date.distantPast
    private var slugCache: [String: (value: String?, at: Date)] = [:]

    func title(forSessionId sessionId: String, transcriptURL: URL?) -> String? {
        rebuildIndexIfNeeded()
        if let title = titlesByCliId[sessionId] { return title }
        return slug(forSessionId: sessionId, transcriptURL: transcriptURL)
    }

    private func rebuildIndexIfNeeded() {
        guard Date().timeIntervalSince(indexBuiltAt) > 60 else { return }
        indexBuiltAt = Date()

        var map: [String: String] = [:]
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
                      let cliId = json["cliSessionId"] as? String,
                      let title = json["title"] as? String, !title.isEmpty
                else { continue }
                map[cliId] = title
            }
        }
        titlesByCliId = map
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
