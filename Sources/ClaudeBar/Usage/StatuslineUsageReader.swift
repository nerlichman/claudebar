import Foundation

/// Reads the statusline JSON that the ClaudeBar statusline hook captures to
/// ~/Library/Application Support/ClaudeBar/usage.json. Claude Code itself
/// pushes rate_limits data into statusline scripts, so this needs no
/// credentials and no network — the trade-off is that the file only updates
/// while a session is interacting.
final class StatuslineUsageReader {
    static let dataDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeBar", isDirectory: true)
    static let usageFile = dataDir.appendingPathComponent("usage.json")

    private var lastMtime: Date?
    private var lastReport: UsageReport?
    private let fm = FileManager.default

    /// Latest report, re-parsing only when the file's mtime changes.
    /// Nil when the hook hasn't captured anything yet.
    func read(now: Date = Date()) -> UsageReport? {
        guard let attrs = try? fm.attributesOfItem(atPath: Self.usageFile.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }

        if mtime != lastMtime {
            lastMtime = mtime
            lastReport = parse(mtime: mtime)
        }
        return lastReport.map { normalize($0, now: now) }
    }

    private func parse(mtime: Date) -> UsageReport? {
        guard let data = try? Data(contentsOf: Self.usageFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // rate_limits only appears for subscription accounts after the
        // session's first API response — absence is normal, not an error.
        guard let limits = json["rate_limits"] as? [String: Any] else { return nil }

        let fiveHour = Self.window(limits["five_hour"])
        let sevenDay = Self.window(limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }

        // Best-effort; statusline omits the sonnet window and credit balance,
        // in which case these stay nil and the rows simply don't render.
        let sonnet = Self.window(limits["seven_day_sonnet"])

        return UsageReport(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDaySonnet: sonnet,
            source: .statusline(asOf: mtime)
        )
    }

    /// Once a window's reset moment passes, the captured utilization is no
    /// longer true (the real value snapped back to ~0) — show that instead.
    private func normalize(_ report: UsageReport, now: Date) -> UsageReport {
        func norm(_ window: UsageWindow?) -> UsageWindow? {
            guard let window else { return nil }
            if let resetsAt = window.resetsAt, resetsAt < now {
                return UsageWindow(utilization: 0, resetsAt: nil)
            }
            return window
        }
        return UsageReport(
            fiveHour: norm(report.fiveHour),
            sevenDay: norm(report.sevenDay),
            sevenDaySonnet: norm(report.sevenDaySonnet),
            credit: report.credit,
            source: report.source
        )
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }

        let pct: Double
        switch dict["used_percentage"] {
        case let d as Double: pct = d
        case let i as Int: pct = Double(i)
        default: return nil
        }

        var resetsAt: Date?
        switch dict["resets_at"] {
        case let seconds as Double:
            resetsAt = Date(timeIntervalSince1970: seconds)
        case let seconds as Int:
            resetsAt = Date(timeIntervalSince1970: Double(seconds))
        case let string as String:
            // Tolerate format drift to ISO 8601.
            resetsAt = ISO8601DateFormatter().date(from: string)
        default:
            break
        }

        return UsageWindow(utilization: pct, resetsAt: resetsAt)
    }
}
