import Foundation

/// Pricing per million tokens, verified against the Claude API docs on
/// 2026-08-11. Matched on the family name appearing anywhere in the model id,
/// not as a prefix: transcripts also carry bare aliases (`sonnet`) and
/// platform-prefixed ids (`anthropic.claude-opus-5`), both of which a
/// `claude-`-anchored prefix match misses. Point releases like
/// `claude-sonnet-5` resolve without a table edit; an unknown model falls
/// back to `table[0]` (the most expensive tier) and is flagged approximate.
/// Family entries carry current pricing, so a future release inherits it; a
/// version-prefixed entry above its family is a legacy exception for an older
/// tier whose price never changed.
enum CostModel {
    struct Pricing {
        let inputPerMTok: Double
        let outputPerMTok: Double
    }

    private static let table: [(family: String, pricing: Pricing)] = [
        ("fable", Pricing(inputPerMTok: 10, outputPerMTok: 50)),
        ("mythos", Pricing(inputPerMTok: 10, outputPerMTok: 50)),
        ("opus", Pricing(inputPerMTok: 5, outputPerMTok: 25)),
        // Sonnet 4.6 and 4.5 stay at $3/$15; must precede the family entry.
        ("sonnet-4", Pricing(inputPerMTok: 3, outputPerMTok: 15)),
        ("sonnet", Pricing(inputPerMTok: 2, outputPerMTok: 10)),
        ("haiku", Pricing(inputPerMTok: 1, outputPerMTok: 5)),
    ]

    /// Server-side web search is billed per request ($10 / 1,000), independent
    /// of the model. Web fetch is not separately billed.
    private static let webSearchPerRequest = 10.0 / 1_000

    static func pricing(forModel model: String) -> Pricing? {
        let id = model.lowercased()
        return table.first { id.contains($0.family) }?.pricing
    }

    /// Estimated USD cost of one usage event. `known` is false when the model
    /// wasn't in the table and the most expensive pricing was assumed.
    static func cost(of event: UsageEvent) -> (usd: Double, known: Bool) {
        // Transcripts carry billing-free placeholder events (`<synthetic>`, used
        // for interrupts and error notices) with every counter zeroed. Costing
        // those is exact at $0 whatever the model is, so they must not flip the
        // approximate flag — it is sticky across a whole window once set.
        guard event.inputTokens != 0 || event.outputTokens != 0
            || event.cacheReadTokens != 0 || event.cacheCreation5mTokens != 0
            || event.cacheCreation1hTokens != 0 || event.webSearchRequests != 0
        else { return (0, true) }

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
