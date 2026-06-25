import Foundation

/// The `User-Agent` for the usage endpoint (`/api/oauth/usage`), which rate-
/// limits a non-Claude-Code client (the default `CFNetwork` UA) far harder. We
/// send the user's *actual* installed Claude Code version, read from their
/// transcripts, so it tracks what they really run. (The token endpoint must NOT
/// use this — Cloudflare blocks it there; see ClaudeCredentials.tokenUserAgent.)
enum ClaudeCodeIdentity {
    /// Bumped only as a last resort if no transcript reveals a real version.
    private static let fallbackVersion = "2.1.183"

    static let userAgent: String = "claude-code/\(version)"

    /// Resolved once — the version changes at most across launches.
    static let version: String = detectVersion() ?? fallbackVersion

    /// Reads the `version` field off the newest transcript.
    private static func detectVersion() -> String? {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudePaths.projectsDir, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return nil }

        var newest: (url: URL, mtime: Date)?
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if mtime > (newest?.mtime ?? .distantPast) {
                    newest = (file, mtime)
                }
            }
        }
        // Bounded read: transcripts can be hundreds of MB, and the `version`
        // field rides on the first events — so 64 KB is plenty.
        guard let url = newest?.url,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let contents = String(data: head, encoding: .utf8) else { return nil }

        // A truncated final line is simply skipped.
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let version = json["version"] as? String, !version.isEmpty
            else { continue }
            return version
        }
        return nil
    }
}
