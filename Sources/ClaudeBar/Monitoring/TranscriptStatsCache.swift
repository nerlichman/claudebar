import Foundation

/// Rolling-window token/cost totals (the current week, and later the month)
/// over a set of transcript files whose lower bound moves — old events fall
/// out at the window boundary, which the append-only tail parser can't express.
///
/// A naive implementation re-reads and re-parses every in-window file on every
/// pass; with a week of heavy use that's ~100 MB of JSON parsed every few
/// minutes, whose transient high-water mark is what pins the app's resident
/// memory. But a transcript's bytes are immutable once written: a file only
/// ever grows, and the events already in it never change. So each file is
/// parsed once into per-calendar-day buckets, keyed on (mtime, size); a later
/// pass that finds the same (mtime, size) reuses the cached buckets untouched.
///
/// In practice that means only the one or two transcripts being actively
/// written get re-read on a given pass — every file from a past day, and every
/// idle session's file, is served from cache. Widening the window (week →
/// month) costs nothing beyond the one-time parse of each newly-included file.
final class TranscriptStatsCache {
    private struct Entry {
        let mtime: Date
        let size: UInt64
        let byDay: [Date: DayStats]
    }

    private var entries: [String: Entry] = [:]
    private let fm = FileManager.default
    private let calendar = Calendar.current

    /// Total across every candidate file's events dated on/after `cutoff`.
    /// `files` is the set of transcripts touched within the window; anything
    /// cached but no longer in that set is dropped so the cache can't grow
    /// without bound as days roll off the window.
    func totals(since cutoff: Date, files: Set<URL>) -> DayStats {
        let cutoffDay = calendar.startOfDay(for: cutoff)
        var live: Set<String> = []
        var total = DayStats.empty

        for url in files {
            let path = url.path
            live.insert(path)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value
            else { continue }

            let entry: Entry
            if let cached = entries[path], cached.mtime == mtime, cached.size == size {
                entry = cached
            } else {
                entry = Entry(
                    mtime: mtime, size: size,
                    byDay: parseByDay(url, fallbackDay: calendar.startOfDay(for: mtime))
                )
                entries[path] = entry
            }

            for (day, stats) in entry.byDay where day >= cutoffDay {
                total.merge(stats)
            }
        }

        entries = entries.filter { live.contains($0.key) }
        return total
    }

    /// Parses a whole transcript once, folding its usage events into buckets
    /// keyed by the event's calendar day. Timestamp-less events (rare) fall
    /// under `fallbackDay` — the file's mtime day, so the bucketing is stable
    /// across re-parses. Dedup on message.id is per-file (a streamed assistant
    /// message repeats its usage line within one file); ids never collide
    /// across session files, so a shared set would only cost memory.
    private func parseByDay(_ url: URL, fallbackDay: Date) -> [Date: DayStats] {
        var seen: Set<String> = []
        var meta = TranscriptTailParser.FileMeta()
        var byDay: [Date: DayStats] = [:]
        _ = TranscriptTailParser.streamLines(of: url, from: 0) { line in
            guard let event = TranscriptTailParser.parseUsageLine(line, seen: &seen, meta: &meta)
            else { return }
            let day = event.timestamp.map { calendar.startOfDay(for: $0) } ?? fallbackDay
            byDay[day, default: .empty].add(event)
        }
        return byDay
    }
}
