import Foundation

/// Resolves a sessionId to its transcript .jsonl under ~/.claude/projects.
/// Fast path: the path-encoded cwd directory. Slow path: a glob across all
/// project directories (the encoding is lossy, so worktree/dot paths can
/// miss). Misses are retried at most every 10 seconds per session.
final class TranscriptIndex {
    private var cache: [String: URL] = [:]
    private var lastMissAttempt: [String: Date] = [:]
    private let fm = FileManager.default

    func url(for sessionId: String, cwd: String) -> URL? {
        if let cached = cache[sessionId] {
            if fm.fileExists(atPath: cached.path) { return cached }
            cache[sessionId] = nil
        }

        let filename = "\(sessionId).jsonl"
        let fast = ClaudePaths.projectsDir
            .appendingPathComponent(ClaudePaths.encodedProjectDir(for: cwd), isDirectory: true)
            .appendingPathComponent(filename)
        if fm.fileExists(atPath: fast.path) {
            cache[sessionId] = fast
            return fast
        }

        if let last = lastMissAttempt[sessionId], Date().timeIntervalSince(last) < 10 {
            return nil
        }
        lastMissAttempt[sessionId] = Date()

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudePaths.projectsDir, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return nil }

        for dir in projectDirs {
            let candidate = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) {
                cache[sessionId] = candidate
                lastMissAttempt[sessionId] = nil
                return candidate
            }
        }
        return nil
    }

    func lastActivity(of url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
