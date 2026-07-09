import Foundation

/// Pricing per million tokens, verified against the Claude API docs on
/// 2026-07-08. Matched by model-family prefix (not version) so point releases
/// like `claude-sonnet-5` resolve without a table edit; an unknown model falls
/// back to `table[0]` (the most expensive tier) and is flagged approximate.
enum CostModel {
    struct Pricing {
        let inputPerMTok: Double
        let outputPerMTok: Double
    }

    private static let table: [(prefix: String, pricing: Pricing)] = [
        ("claude-fable", Pricing(inputPerMTok: 10, outputPerMTok: 50)),
        ("claude-mythos", Pricing(inputPerMTok: 10, outputPerMTok: 50)),
        ("claude-opus", Pricing(inputPerMTok: 5, outputPerMTok: 25)),
        // Sonnet 5 carries an intro rate of $2/$10 through 2026-08-31; we keep
        // the standard $3/$15 so estimates stay conservative (slightly high).
        ("claude-sonnet", Pricing(inputPerMTok: 3, outputPerMTok: 15)),
        ("claude-haiku", Pricing(inputPerMTok: 1, outputPerMTok: 5)),
    ]

    /// Server-side web search is billed per request ($10 / 1,000), independent
    /// of the model. Web fetch is not separately billed.
    private static let webSearchPerRequest = 10.0 / 1_000

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
            + Double(event.webSearchRequests) * webSearchPerRequest
        return (usd, known)
    }
}
