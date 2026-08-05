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
///
/// What a cached bucket holds is one entry per billed request rather than a
/// pre-summed total, because a rewound conversation leaves several transcripts
/// holding the same requests and only one of them may count. That costs roughly
/// 150 bytes per request in the window — far below the parse high-water mark the
/// cache exists to avoid, and the only way the window total can match what was
/// actually billed. See `TranscriptLineageIndex`.
final class TranscriptStatsCache {
    /// One billed request's contribution, kept individually rather than folded
    /// straight into a per-day `DayStats`. Whether a request counts depends on
    /// the *other* files in the window — a rewound conversation leaves several
    /// snapshots holding the same requests — and a pre-summed bucket can no
    /// longer express that.
    private struct Billed {
        let id: String?
        let stats: DayStats
    }

    private struct Entry {
        let mtime: Date
        let size: UInt64
        let byDay: [Date: [Billed]]
    }

    private var entries: [String: Entry] = [:]
    private let fm = FileManager.default
    private let calendar = Calendar.current
    /// Held only for its memoized creation dates, which order snapshots so the
    /// newest wins a collision. Birthtimes never change, so it is never reset.
    private let order = TranscriptLineageIndex()

    /// Total across every candidate file's events dated on/after `cutoff`.
    /// `files` is the set of transcripts touched within the window; anything
    /// cached but no longer in that set is dropped so the cache can't grow
    /// without bound as days roll off the window.
    func totals(since cutoff: Date, files: Set<URL>) -> DayStats {
        let cutoffDay = calendar.startOfDay(for: cutoff)
        var live: Set<String> = []
        var total = DayStats.empty
        var billed: Set<String> = []

        for url in order.newestFirst(files) {
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

            // A copied request carries its original timestamp, so both snapshots
            // land in the same day bucket — day-filtering before the dedup can't
            // let one slip through.
            for (day, requests) in entry.byDay where day >= cutoffDay {
                for request in requests {
                    if let id = request.id, !billed.insert(id).inserted { continue }
                    total.merge(request.stats)
                }
            }
        }

        entries = entries.filter { live.contains($0.key) }
        return total
    }

    /// Parses a whole transcript once, bucketing its billed requests by calendar
    /// day. Timestamp-less events (rare) fall under `fallbackDay` — the file's
    /// mtime day, so the bucketing is stable across re-parses.
    ///
    /// The `seen` set here collapses the several lines one response writes, one
    /// per content block, into the single request they describe. Collapsing the
    /// same request across *snapshots* of a rewound conversation is the caller's
    /// job, since it needs every file in the window to do it.
    private func parseByDay(_ url: URL, fallbackDay: Date) -> [Date: [Billed]] {
        var seen: Set<String> = []
        var meta = TranscriptTailParser.FileMeta()
        var byDay: [Date: [Billed]] = [:]
        _ = TranscriptTailParser.streamLines(of: url, from: 0) { line in
            guard let event = TranscriptTailParser.parseUsageLine(line, seen: &seen, meta: &meta)
            else { return }
            let day = event.timestamp.map { calendar.startOfDay(for: $0) } ?? fallbackDay
            var stats = DayStats.empty
            stats.add(event)
            byDay[day, default: []].append(Billed(id: event.messageId, stats: stats))
        }
        return byDay
    }
}
