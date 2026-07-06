import Foundation

/// Resolves a sessionId to its transcript .jsonl under ~/.claude/projects.
/// Fast path: the path-encoded cwd directory. Slow path: a glob across all
/// project directories (the encoding is lossy, so worktree/dot paths can
/// miss). Misses are retried at most every 10 seconds per session.
final class TranscriptIndex {
    private var cache: [String: URL] = [:]
    private var lastMissAttempt: [String: Date] = [:]
    private var activityCache: [String: (mtime: Date, size: UInt64, timestamp: Date)] = [:]
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

    /// Timestamp of the last transcript entry. File mtime alone is unreliable:
    /// other tools sweep ~/.claude/projects and touch transcripts hours or days
    /// after the conversation stopped, which made idle/waiting sessions look
    /// recently active. The entry's own `timestamp` field is authoritative;
    /// mtime+size only serve as the cache key so unchanged files aren't
    /// re-read on every poll.
    func lastActivity(of url: URL) -> Date? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        if let cached = activityCache[url.path], cached.mtime == mtime, cached.size == size {
            return cached.timestamp
        }
        let timestamp = Self.lastEntryTimestamp(of: url, size: size) ?? mtime
        activityCache[url.path] = (mtime: mtime, size: size, timestamp: timestamp)
        return timestamp
    }

    /// Scans the tail of a .jsonl transcript for the newest line carrying a
    /// `timestamp` field. A partially-written last line fails JSON parsing and
    /// is skipped, as is the truncated first line of the tail window. The
    /// window escalates because a transcript can end in timestamp-less
    /// housekeeping lines (`last-prompt`, `mode`) preceded by a single
    /// assistant message line larger than the small window.
    private static func lastEntryTimestamp(of url: URL, size: UInt64) -> Date? {
        for window: UInt64 in [64 * 1024, 2 * 1024 * 1024] {
            if let date = lastEntryTimestamp(of: url, size: size, window: window) {
                return date
            }
            if size <= window { return nil }
        }
        return nil
    }

    private static func lastEntryTimestamp(of url: URL, size: UInt64, window: UInt64) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        if size > window {
            guard (try? handle.seek(toOffset: size - window)) != nil else { return nil }
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let raw = json["timestamp"] as? String,
                  let date = isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
            else { continue }
            return date
        }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
