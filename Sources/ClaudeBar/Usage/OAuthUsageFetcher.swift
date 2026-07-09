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
        let perModel = Self.perModelWeekly(json)
        let credit = Self.credit(json["extra_usage"])

        return .success(UsageReport(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            perModelWeekly: perModel,
            credit: credit,
            source: .api(asOf: Date())
        ))
    }

    // The per-model weekly bucket is plan-dependent — `seven_day_fable` on a
    // Team seat, `seven_day_opus` on Max, `seven_day_sonnet` elsewhere, or
    // absent entirely. Parse every `seven_day_<model>` key generically and
    // label it from the suffix rather than assuming a single model.
    static func perModelWeekly(_ json: [String: Any]) -> [ModelWeeklyWindow] {
        json.keys
            .filter { $0.hasPrefix("seven_day_") }
            .sorted()
            .compactMap { key in
                Self.window(json[key]).map { ModelWeeklyWindow(key: key, window: $0) }
            }
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
/// Stored as JSON so the variable-length per-model window list round-trips
/// cleanly; a pre-JSON cache entry simply fails to decode and is refetched.
enum UsageCache {
    private static let key = "lastUsageReport"

    private struct Snapshot: Codable {
        let asOf: Date
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let perModelWeekly: [ModelWeeklyWindow]
        let credit: CreditBalance?
    }

    static func save(_ report: UsageReport) {
        guard case .api(let asOf) = report.source else { return }
        let snapshot = Snapshot(
            asOf: asOf,
            fiveHour: report.fiveHour,
            sevenDay: report.sevenDay,
            perModelWeekly: report.perModelWeekly,
            credit: report.credit
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> UsageReport? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.fiveHour != nil || snapshot.sevenDay != nil
        else { return nil }
        return UsageReport(
            fiveHour: snapshot.fiveHour,
            sevenDay: snapshot.sevenDay,
            perModelWeekly: snapshot.perModelWeekly,
            credit: snapshot.credit,
            source: .api(asOf: snapshot.asOf)
        )
    }
}
