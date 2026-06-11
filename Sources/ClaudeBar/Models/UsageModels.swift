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

struct UsageReport: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let source: UsageSource
}
