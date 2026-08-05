import Foundation

/// Groups transcript files that are snapshots of the same conversation, and
/// decides which session a billed request counts toward.
///
/// Rewinding — "rewind to here", or editing an earlier message — does not
/// truncate the running transcript. Claude Code opens a *new* session file
/// seeded with a copy of the history up to the rewind point, and every copied
/// line keeps its original `message.id` and timestamp. A conversation rewound
/// eight times is therefore nine files on disk whose billed messages overlap
/// almost entirely, and summing them per-file bills the same API request up to
/// nine times. Measured on this machine: $2,619 of apparent all-time spend
/// against $1,105 actually billed.
///
/// Two rules undo that. A `message.id` is one billed request, so it counts once
/// no matter how many snapshots hold it. And the request counts toward the
/// *newest* snapshot in its lineage — the conversation the user is still in and
/// the row they recognize — which the abandoned snapshots then report nothing
/// of, so they drop out of the session list on their own.
///
/// Requests that survive in no descendant are the ones genuinely rewound away.
/// They were still billed, so they roll up into that same newest row rather
/// than disappearing, and are reported separately as `DayStats.rewoundCostUSD`.
/// This is the one place attribution deliberately diverges from Claude's own
/// per-session view, which cannot show them at all — the session that paid for
/// them no longer exists in its UI.
final class TranscriptLineageIndex {
    enum Claim {
        /// Not billed yet — count it.
        case fresh
        /// A sibling snapshot already accounted for this request.
        case alreadyBilled
        /// This file just proved it owns the lineage, but older snapshots were
        /// already credited with its history. The caller must restart the pass
        /// so the newest file claims that history first.
        case supersededOwner
    }

    private var billedBy: [String: String] = [:]
    private var parent: [String: String] = [:]
    private var newest: [String: String] = [:]
    private var birth: [String: Date] = [:]
    private let fm = FileManager.default

    func reset() {
        billedBy = [:]
        parent = [:]
        newest = [:]
        birth = [:]
    }

    /// Files ordered so every lineage's newest snapshot is processed first —
    /// the order `claim(_:for:)` assumes. Ties break on path to stay stable.
    func newestFirst(_ urls: some Sequence<URL>) -> [URL] {
        urls.sorted {
            let (a, b) = (created($0), created($1))
            return a == b ? $0.path > $1.path : a > b
        }
    }

    func claim(_ messageId: String?, for url: URL) -> Claim {
        // A usage line with no id can't be matched across snapshots. These are
        // rare and always in the tail of a stream, so counting them is the
        // lesser error.
        guard let messageId else { return .fresh }
        register(url)
        guard let owner = billedBy[messageId] else {
            billedBy[messageId] = url.path
            return .fresh
        }
        guard owner != url.path else { return .alreadyBilled }
        return union(owner, url.path) ? .supersededOwner : .alreadyBilled
    }

    /// Whether `url` is the snapshot its lineage's history counts toward. False
    /// only for abandoned snapshots, whose remaining claims are rewound-away
    /// requests.
    func isRepresentative(_ url: URL) -> Bool {
        representative(of: url).path == url.path
    }

    func representative(of url: URL) -> URL {
        register(url)
        guard let path = newest[find(url.path)], path != url.path else { return url }
        return URL(fileURLWithPath: path)
    }

    private func register(_ url: URL) {
        guard parent[url.path] == nil else { return }
        parent[url.path] = url.path
        newest[url.path] = url.path
        _ = created(url)
    }

    /// Creation date, not mtime: a rewind snapshot is born after the session it
    /// copies, while both files keep being written afterwards. Falls back to
    /// mtime, then to `.distantPast`, on filesystems that withhold birthtime.
    private func created(_ url: URL) -> Date {
        if let cached = birth[url.path] { return cached }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        guard let date = values?.creationDate ?? values?.contentModificationDate else {
            // Not on disk yet — a subagent can be resolved against a parent
            // transcript before it is tracked. Left uncached so the real date is
            // picked up once it exists, rather than pinning the file as oldest.
            return .distantPast
        }
        birth[url.path] = date
        return date
    }

    private func find(_ path: String) -> String {
        var root = path
        while let next = parent[root], next != root {
            parent[root] = parent[next] ?? next
            root = parent[root]!
        }
        return root
    }

    /// Merges two snapshots into one lineage. Returns true when `joining` is now
    /// the lineage's newest file and wasn't before — meaning history already
    /// credited elsewhere has to be re-attributed.
    private func union(_ existing: String, _ joining: String) -> Bool {
        let (a, b) = (find(existing), find(joining))
        let previous = newest[a]
        if a != b {
            parent[b] = a
            let candidates = [newest[a], newest[b]].compactMap { $0 }
            newest[a] = candidates.max {
                let (x, y) = (birthDate($0), birthDate($1))
                return x == y ? $0 > $1 : x < y
            }
            newest[b] = nil
        }
        return newest[a] == joining && previous != joining
    }

    private func birthDate(_ path: String) -> Date {
        birth[path] ?? created(URL(fileURLWithPath: path))
    }
}
