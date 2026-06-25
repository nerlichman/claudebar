import Foundation

/// Fetches the semi-official OAuth usage endpoint with a user-provided
/// bearer token. The token is held in memory only for the request and is
/// never logged. Response parsing is defensive (JSONSerialization, optional
/// chaining) so schema drift degrades to partial data, not total failure.
actor OAuthUsageFetcher {
    enum FetchError: Error {
        case unauthorized
        case rateLimited
        case http(Int)
        case network(String)
        case schemaDrift

        var userMessage: String {
            switch self {
            case .unauthorized: return "Usage token expired — paste a fresh one"
            case .rateLimited: return "Usage API rate-limited"
            case .http(let code): return "Usage API returned HTTP \(code)"
            case .network(let message): return "Usage API unreachable: \(message)"
            case .schemaDrift: return "Usage API response not understood"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(token: String) async -> Result<UsageReport, FetchError> {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // The endpoint gates on a Claude Code User-Agent; without it the
        // default CFNetwork UA is rate-limited far more aggressively.
        request.setValue(ClaudeCodeIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.network("no HTTP response"))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .failure(.unauthorized)
        }
        if http.statusCode == 429 {
            return .failure(.rateLimited)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.http(http.statusCode))
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.schemaDrift)
        }

        let fiveHour = Self.window(json["five_hour"])
        let sevenDay = Self.window(json["seven_day"])
        guard fiveHour != nil || sevenDay != nil else {
            return .failure(.schemaDrift)
        }

        // Best-effort extras — absence never fails the fetch, so the 5h/weekly
        // behavior is preserved if the schema ever drops these.
        let sonnet = Self.window(json["seven_day_sonnet"])
        let credit = Self.credit(json["extra_usage"])

        return .success(UsageReport(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDaySonnet: sonnet,
            credit: credit,
            source: .api(asOf: Date())
        ))
    }

    // Verified response shape (2026-06-12):
    // "extra_usage": {"is_enabled": true, "monthly_limit": 1000,
    //                 "used_credits": 529.0, "utilization": 52.9,
    //                 "currency": "USD"}
    // monthly_limit / used_credits are in cents. Only USD is rendered with a
    // "$"; anything else (or a disabled balance) degrades to no credit row.
    private static func credit(_ value: Any?) -> CreditBalance? {
        guard let dict = value as? [String: Any] else { return nil }
        if let enabled = dict["is_enabled"] as? Bool, !enabled { return nil }
        if let currency = dict["currency"] as? String, currency != "USD" { return nil }

        func num(_ any: Any?) -> Double? {
            switch any {
            case let d as Double: return d
            case let i as Int: return Double(i)
            default: return nil
            }
        }
        guard let limitCents = num(dict["monthly_limit"]), limitCents > 0 else { return nil }
        let usedCents = num(dict["used_credits"]) ?? 0
        let utilization = num(dict["utilization"]) ?? (usedCents / limitCents * 100)
        return CreditBalance(
            usedUSD: usedCents / 100,
            limitUSD: limitCents / 100,
            utilization: utilization
        )
    }

    // Verified response shape (2026-06-10):
    // {"five_hour": {"utilization": 40.0, "resets_at": "2026-06-10T21:50:01.46+00:00"}, ...}
    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let utilization: Double
        switch dict["utilization"] {
        case let d as Double: utilization = d
        case let i as Int: utilization = Double(i)
        default: return nil
        }
        let resetsAt = (dict["resets_at"] as? String).flatMap(parseISO8601)
        return UsageWindow(utilization: utilization, resetsAt: resetsAt)
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

    private static func parseISO8601(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}

/// Last good API report, persisted so app relaunches don't regress to stale
/// statusline data while the endpoint cools down or the token is replaced.
enum UsageCache {
    private static let key = "lastUsageReport"

    static func save(_ report: UsageReport) {
        guard case .api(let asOf) = report.source else { return }
        var dict: [String: Double] = ["asOf": asOf.timeIntervalSince1970]
        if let five = report.fiveHour {
            dict["fivePct"] = five.utilization
            if let reset = five.resetsAt { dict["fiveReset"] = reset.timeIntervalSince1970 }
        }
        if let seven = report.sevenDay {
            dict["sevenPct"] = seven.utilization
            if let reset = seven.resetsAt { dict["sevenReset"] = reset.timeIntervalSince1970 }
        }
        if let sonnet = report.sevenDaySonnet {
            dict["sonnetPct"] = sonnet.utilization
            if let reset = sonnet.resetsAt { dict["sonnetReset"] = reset.timeIntervalSince1970 }
        }
        if let credit = report.credit {
            dict["creditUsed"] = credit.usedUSD
            dict["creditLimit"] = credit.limitUSD
            dict["creditUtil"] = credit.utilization
        }
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func load() -> UsageReport? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let asOf = dict["asOf"]
        else { return nil }
        func window(_ pctKey: String, _ resetKey: String) -> UsageWindow? {
            guard let pct = dict[pctKey] else { return nil }
            return UsageWindow(
                utilization: pct,
                resetsAt: dict[resetKey].map { Date(timeIntervalSince1970: $0) }
            )
        }
        let five = window("fivePct", "fiveReset")
        let seven = window("sevenPct", "sevenReset")
        guard five != nil || seven != nil else { return nil }
        let sonnet = window("sonnetPct", "sonnetReset")
        var credit: CreditBalance?
        if let limit = dict["creditLimit"], let used = dict["creditUsed"] {
            credit = CreditBalance(
                usedUSD: used, limitUSD: limit,
                utilization: dict["creditUtil"] ?? (limit > 0 ? used / limit * 100 : 0)
            )
        }
        return UsageReport(
            fiveHour: five, sevenDay: seven,
            sevenDaySonnet: sonnet, credit: credit,
            source: .api(asOf: Date(timeIntervalSince1970: asOf))
        )
    }
}

/// User-pasted bearer token. Stored in UserDefaults (user-only readable
/// plist). The token rotates on Claude Code's refresh cycle, so expect it to
/// expire within hours — the UI surfaces that instead of failing silently.
enum ManualTokenStore {
    private static let key = "manualAccessToken"

    static var token: String? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func set(_ token: String?) {
        if let token, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
