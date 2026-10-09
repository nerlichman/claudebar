import Foundation

/// Anthropic model prices from RubyLLM's published registry, so a price change
/// reaches the app without a release. RubyLLM rebuilds it every six hours from
/// models.dev and the providers' own APIs and refuses suspicious regressions
/// before publishing. `CostModel` consults it first and falls back to its
/// built-in table for anything missing here: bare aliases (`opus`), retired
/// models, and what the registry doesn't carry (fast mode, 1h cache writes).
final class PricingRegistry: @unchecked Sendable {
    struct Rates: Codable, Equatable {
        let input: Double
        let output: Double
        let cacheRead: Double?
        var longContext: LongContextRates?
    }

    struct LongContextRates: Codable, Equatable {
        let thresholdTokens: Int
        let input: Double
        let output: Double
        let cacheRead: Double?
    }

    private struct Snapshot: Codable {
        /// Bumped whenever `parse` reads more of the registry, so a copy saved
        /// by an older build is refetched instead of kept alive by a 304.
        var version = Snapshot.currentVersion
        static let currentVersion = 2
        let fetchedAt: Date
        let etag: String?
        let rates: [String: Rates]
    }

    static let shared = PricingRegistry()

    private static let source = URL(string: "https://rubyllm.com/models.json")!
    private static let cacheFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeBar/pricing.json")
    private static let maxAge: TimeInterval = 6 * 3600
    /// A response with fewer Anthropic models than this is treated as broken
    /// rather than as Anthropic having retired most of its lineup.
    private static let minimumModels = 5

    private let lock = NSLock()
    private var snapshot: Snapshot?
    /// Longest first, so `claude-opus-5-5` wins over `claude-opus-5`.
    private var ids: [String] = []

    private init() {
        if let data = try? Data(contentsOf: Self.cacheFile),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           saved.version == Snapshot.currentVersion {
            install(saved)
        }
    }

    func rates(forModel model: String) -> Rates? {
        lock.withLock {
            ids.first { Self.matches(model, registryId: $0) }.flatMap { snapshot?.rates[$0] }
        }
    }

    /// Fetches the registry when the saved copy is older than `maxAge`.
    /// Returns true only when the prices actually changed.
    func refreshIfStale() async -> Bool {
        let current = lock.withLock { snapshot }
        if let current, Date().timeIntervalSince(current.fetchedAt) < Self.maxAge { return false }

        var request = URLRequest(url: Self.source, timeoutInterval: 30)
        if let etag = current?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            Log.info("pricing: registry unreachable")
            return false
        }

        if http.statusCode == 304, let current {
            save(Snapshot(fetchedAt: Date(), etag: current.etag, rates: current.rates))
            return false
        }
        guard http.statusCode == 200, let rates = Self.parse(data), rates.count >= Self.minimumModels else {
            Log.info("pricing: registry rejected (HTTP \(http.statusCode))")
            return false
        }

        let changed = rates != current?.rates
        save(Snapshot(fetchedAt: Date(), etag: http.value(forHTTPHeaderField: "ETag"), rates: rates))
        if changed { Log.info("pricing: loaded \(rates.count) Anthropic models from registry") }
        return changed
    }

    private func save(_ new: Snapshot) {
        install(new)
        try? FileManager.default.createDirectory(
            at: Self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(new).write(to: Self.cacheFile, options: .atomic)
    }

    private func install(_ new: Snapshot) {
        lock.withLock {
            snapshot = new
            ids = new.rates.keys.sorted { $0.count > $1.count }
        }
    }

    private static func parse(_ data: Data) -> [String: Rates]? {
        guard let models = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var rates: [String: Rates] = [:]
        for model in models where model["provider"] as? String == "anthropic" {
            guard let id = (model["id"] as? String)?.lowercased(),
                  let text = (model["pricing"] as? [String: Any])?["text_tokens"] as? [String: Any],
                  let standard = text["standard"] as? [String: Any],
                  let input = (standard["input_per_million"] as? NSNumber)?.doubleValue,
                  let output = (standard["output_per_million"] as? NSNumber)?.doubleValue,
                  input > 0, output > 0
            else { continue }
            var entry = Rates(input: input, output: output, cacheRead: cacheRead(standard))
            if let long = text["long_context"] as? [String: Any],
               let threshold = (text["long_context_threshold"] as? NSNumber)?.intValue,
               let longInput = (long["input_per_million"] as? NSNumber)?.doubleValue,
               let longOutput = (long["output_per_million"] as? NSNumber)?.doubleValue,
               threshold > 0, longInput > 0, longOutput > 0 {
                entry.longContext = LongContextRates(
                    thresholdTokens: threshold, input: longInput, output: longOutput,
                    cacheRead: cacheRead(long)
                )
            }
            rates[id] = entry
        }
        return rates
    }

    private static func cacheRead(_ tier: [String: Any]) -> Double? {
        guard let value = (tier["cache_read_input_per_million"] as? NSNumber)?.doubleValue, value > 0
        else { return nil }
        return value
    }

    /// The registry id may sit inside a platform-prefixed or date-suffixed id
    /// (`us.anthropic.claude-opus-5-v1:0`, `claude-opus-4-5-20251101`), but must
    /// not match a newer point release: until the registry lists
    /// `claude-opus-5-5`, that id must fall through to the built-in table rather
    /// than be priced as `claude-opus-5`.
    static func matches(_ model: String, registryId: String) -> Bool {
        guard let range = model.range(of: registryId) else { return false }
        let rest = model[range.upperBound...]
        guard rest.first == "-" else { return true }
        let digits = rest.dropFirst().prefix { $0.isNumber }
        return digits.isEmpty || digits.count >= 8
    }
}
