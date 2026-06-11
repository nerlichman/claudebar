import Foundation

struct UsageEvent {
    let timestamp: Date?
    let model: String
    let messageId: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreation5mTokens: Int
    let cacheCreation1hTokens: Int
}

/// Incremental parser for transcript .jsonl files. Tracks a byte offset per
/// file so multi-MB transcripts are read once, then only their appended tail.
/// Streaming writes the same assistant message's usage line more than once
/// (verified on this machine), so events are deduped on message.id.
final class TranscriptTailParser {
    /// Latest context fields seen in a transcript — enough to describe a
    /// session whose process is gone.
    struct FileMeta {
        var cwd: String?
        var gitBranch: String?
        var entrypoint: String?
    }

    private var offsets: [String: UInt64] = [:]
    private var seenMessageIds: Set<String> = []
    private var fileMeta: [String: FileMeta] = [:]
    private let fm = FileManager.default

    func metadata(for url: URL) -> FileMeta? {
        fileMeta[url.path]
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Clears all per-file state — used at midnight rollover before
    /// re-bootstrapping the day.
    func resetAll() {
        offsets = [:]
        seenMessageIds = []
        fileMeta = [:]
    }

    /// Reads from the stored offset to EOF and returns newly appended events.
    func newEvents(in url: URL) -> [UsageEvent] {
        let path = url.path
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return [] }

        var offset = offsets[path] ?? 0
        if size < offset {
            // File truncated or replaced — start over.
            offset = 0
        }
        guard size > offset else { return [] }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return [] }

        // Only consume up to the last complete line; a partially-written
        // trailing line is left for the next pass.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        offsets[path] = offset + UInt64(complete.count)

        var meta = fileMeta[path] ?? FileMeta()
        let events = complete.split(separator: UInt8(ascii: "\n"))
            .compactMap { parseLine(Data($0), meta: &meta) }
        fileMeta[path] = meta
        return events
    }

    private func parseLine(_ data: Data, meta: inout FileMeta) -> UsageEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        if let cwd = json["cwd"] as? String { meta.cwd = cwd }
        if let branch = json["gitBranch"] as? String { meta.gitBranch = branch }
        if let entrypoint = json["entrypoint"] as? String { meta.entrypoint = entrypoint }

        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        if let id = message["id"] as? String {
            if seenMessageIds.contains(id) { return nil }
            seenMessageIds.insert(id)
        }

        func intValue(_ any: Any?) -> Int {
            switch any {
            case let n as Int: return n
            case let n as Double: return Int(n)
            default: return 0
            }
        }

        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let cache5m: Int
        let cache1h: Int
        if let cacheCreation {
            cache5m = intValue(cacheCreation["ephemeral_5m_input_tokens"])
            cache1h = intValue(cacheCreation["ephemeral_1h_input_tokens"])
        } else {
            // Older lines lack the breakdown — assume the cheaper 5m tier.
            cache5m = intValue(usage["cache_creation_input_tokens"])
            cache1h = 0
        }

        let timestamp = (json["timestamp"] as? String).flatMap {
            Self.isoFormatter.date(from: $0) ?? Self.isoPlainFormatter.date(from: $0)
        }

        return UsageEvent(
            timestamp: timestamp,
            model: message["model"] as? String ?? "unknown",
            messageId: message["id"] as? String,
            inputTokens: intValue(usage["input_tokens"]),
            outputTokens: intValue(usage["output_tokens"]),
            cacheReadTokens: intValue(usage["cache_read_input_tokens"]),
            cacheCreation5mTokens: cache5m,
            cacheCreation1hTokens: cache1h
        )
    }
}
