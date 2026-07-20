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
    let webSearchRequests: Int
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

        var meta = fileMeta[path] ?? FileMeta()
        var events: [UsageEvent] = []
        offsets[path] = Self.streamLines(of: url, from: offset) { line in
            if let event = Self.parseUsageLine(line, seen: &self.seenMessageIds, meta: &meta) {
                events.append(event)
            }
        }
        fileMeta[path] = meta
        return events
    }

    /// Reads `url` from byte `offset` to EOF in chunks, invoking `onLine` for
    /// every complete newline-terminated line. A partially-written trailing
    /// line is left unconsumed. Returns the new offset (start + bytes up to and
    /// including the last newline seen). Each chunk's lines are processed inside
    /// an autorelease pool so the Foundation objects `parseUsageLine` produces
    /// drain per chunk instead of piling up across a multi-MB file — and the
    /// file is never loaded whole, only a chunk (plus one straddling line) at a
    /// time.
    static func streamLines(
        of url: URL, from offset: UInt64,
        chunkSize: Int = 256 * 1024, onLine: (Data) -> Void
    ) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return offset }

        var consumed: UInt64 = 0
        var leftover = Data()
        while let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil, !chunk.isEmpty {
            var buffer = leftover
            buffer.append(chunk)
            guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else {
                leftover = buffer
                continue
            }
            let complete = buffer[buffer.startIndex...lastNewline]
            autoreleasepool {
                for line in complete.split(separator: UInt8(ascii: "\n")) {
                    onLine(Data(line))
                }
            }
            consumed += UInt64(complete.count)
            leftover = Data(buffer[buffer.index(after: lastNewline)...])
        }
        return offset + consumed
    }

    static func parseUsageLine(
        _ data: Data, seen: inout Set<String>, meta: inout FileMeta
    ) -> UsageEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        if let cwd = json["cwd"] as? String { meta.cwd = cwd }
        if let branch = json["gitBranch"] as? String { meta.gitBranch = branch }
        if let entrypoint = json["entrypoint"] as? String { meta.entrypoint = entrypoint }

        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        if let id = message["id"] as? String {
            if seen.contains(id) { return nil }
            seen.insert(id)
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

        let serverToolUse = usage["server_tool_use"] as? [String: Any]
        let webSearchRequests = intValue(serverToolUse?["web_search_requests"])

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
            cacheCreation1hTokens: cache1h,
            webSearchRequests: webSearchRequests
        )
    }
}
