import Foundation

struct UsageWindow: Equatable, Codable {
    /// 0–100. Nil utilization rows from the endpoint are dropped upstream.
    let utilization: Double
    let resetsAt: Date?
}

/// A per-model weekly limit — e.g. the "Fable", "Opus", or "Sonnet" weekly
/// bucket. Which model this covers is plan-dependent (Team, Max, Pro, and the
/// per-seat tiers each expose a different one, or none), so the label is read
/// from the API's `seven_day_<model>` key rather than hard-coded.
struct ModelWeeklyWindow: Equatable, Codable {
    /// Display label, e.g. "Fable" / "Opus" / "Sonnet".
    let model: String
    let window: UsageWindow

    init(model: String, window: UsageWindow) {
        self.model = model
        self.window = window
    }

    /// Derives the label from the API key suffix:
    /// `seven_day_fable` → "Fable"; `seven_day_claude_opus` → "Claude Opus".
    init(key: String, window: UsageWindow) {
        let suffix = key.hasPrefix("seven_day_")
            ? String(key.dropFirst("seven_day_".count))
            : key
        let words = suffix.split(separator: "_").map { $0.capitalized }
        self.model = words.isEmpty ? "Model" : words.joined(separator: " ")
        self.window = window
    }
}

enum UsageSource: Equatable {
    case api(asOf: Date)
    case statusline(asOf: Date)
    case estimated(asOf: Date)
    case unavailable(String)

    var asOf: Date {
        switch self {
        case .api(let date), .statusline(let date), .estimated(let date): return date
        case .unavailable: return .distantPast
        }
    }
}

/// Pay-as-you-go overage balance against a monthly cap, reported directly by
/// the usage API (`extra_usage`). Unlike the per-session token estimate, this
/// is the server's authoritative dollar figure — it already accounts for
/// retried/interrupted requests that never reach a transcript. This is the
/// pool a subscription spills into once a weekly bucket (e.g. Fable) is spent.
struct CreditBalance: Equatable, Codable {
    let usedUSD: Double
    let limitUSD: Double
    /// 0–100, as reported by the endpoint (kept rather than recomputed so the
    /// bar matches the desktop app exactly).
    let utilization: Double
}

struct UsageReport: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    /// Per-model weekly buckets in a stable order. Empty on plans that don't
    /// expose one (e.g. some personal tiers).
    let perModelWeekly: [ModelWeeklyWindow]
    let credit: CreditBalance?
    let source: UsageSource

    // Defaults keep the credential-free statusline path and the cache loader
    // working unchanged — only the OAuth fetcher populates the richer fields.
    init(fiveHour: UsageWindow?, sevenDay: UsageWindow?,
         perModelWeekly: [ModelWeeklyWindow] = [], credit: CreditBalance? = nil,
         source: UsageSource) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.perModelWeekly = perModelWeekly
        self.credit = credit
        self.source = source
    }
}
