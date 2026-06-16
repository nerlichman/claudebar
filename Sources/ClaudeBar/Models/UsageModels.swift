import Foundation

struct UsageWindow: Equatable {
    /// 0–100. Nil utilization rows from the endpoint are dropped upstream.
    let utilization: Double
    let resetsAt: Date?
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
/// retried/interrupted requests that never reach a transcript.
struct CreditBalance: Equatable {
    let usedUSD: Double
    let limitUSD: Double
    /// 0–100, as reported by the endpoint (kept rather than recomputed so the
    /// bar matches the desktop app exactly).
    let utilization: Double
}

struct UsageReport: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let credit: CreditBalance?
    let source: UsageSource

    // Defaults keep the credential-free statusline path and the cache loader
    // working unchanged — only the OAuth fetcher populates the richer fields.
    init(fiveHour: UsageWindow?, sevenDay: UsageWindow?,
         sevenDaySonnet: UsageWindow? = nil, credit: CreditBalance? = nil,
         source: UsageSource) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.credit = credit
        self.source = source
    }
}
