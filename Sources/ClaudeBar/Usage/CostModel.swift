import Foundation

/// Pricing per million tokens, verified against the Claude API docs on
/// 2026-06-10. Matched by model-ID prefix so dated/suffixed variants resolve.
enum CostModel {
    struct Pricing {
        let inputPerMTok: Double
        let outputPerMTok: Double
    }

    private static let table: [(prefix: String, pricing: Pricing)] = [
        ("claude-fable-5", Pricing(inputPerMTok: 10, outputPerMTok: 50)),
        ("claude-opus-4", Pricing(inputPerMTok: 5, outputPerMTok: 25)),
        ("claude-sonnet-4", Pricing(inputPerMTok: 3, outputPerMTok: 15)),
        ("claude-haiku-4", Pricing(inputPerMTok: 1, outputPerMTok: 5)),
    ]

    static func pricing(forModel model: String) -> Pricing? {
        table.first { model.hasPrefix($0.prefix) }?.pricing
    }

    /// Estimated USD cost of one usage event. `known` is false when the model
    /// wasn't in the table and the most expensive pricing was assumed.
    static func cost(of event: UsageEvent) -> (usd: Double, known: Bool) {
        let known = pricing(forModel: event.model) != nil
        let p = pricing(forModel: event.model) ?? table[0].pricing
        let perTok = 1.0 / 1_000_000
        let usd = Double(event.inputTokens) * p.inputPerMTok * perTok
            + Double(event.outputTokens) * p.outputPerMTok * perTok
            + Double(event.cacheReadTokens) * p.inputPerMTok * 0.1 * perTok
            + Double(event.cacheCreation5mTokens) * p.inputPerMTok * 1.25 * perTok
            + Double(event.cacheCreation1hTokens) * p.inputPerMTok * 2.0 * perTok
        return (usd, known)
    }
}
