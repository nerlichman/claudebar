import Foundation

/// Pricing per million tokens, verified against the Claude API docs on
/// 2026-08-14. Matched on the family name appearing anywhere in the model id,
/// not as a prefix: transcripts also carry bare aliases (`sonnet`) and
/// platform-prefixed ids (`anthropic.claude-opus-5`), both of which a
/// `claude-`-anchored prefix match misses. Point releases like
/// `claude-sonnet-5` resolve without a table edit; an unknown model falls
/// back to `table[0]` (the most expensive tier) and is flagged approximate.
/// Family entries carry current pricing, so a future release inherits it; a
/// version-prefixed entry above its family is an exception for a release whose
/// rates differ from the family default.
enum CostModel {
    struct Pricing {
        let inputPerMTok: Double
        let outputPerMTok: Double
        /// Cache reads bill at this fraction of the base input price. Every
        /// model uses 0.1 except Fable/Mythos 5.1, which read at 0.025 —
        /// $0.25/MTok against the same $10 base as Fable 5's $1/MTok.
        var cacheReadMultiplier: Double = 0.1
    }

    /// Order matters: a version is a substring of its own point releases, so
    /// `fable-5` also matches `claude-fable-5-1`. More specific ids must come
    /// first, and each family's trailing entry holds the current rates for
    /// bare aliases (`fable`) and releases that don't exist yet.
    private static let table: [(family: String, pricing: Pricing)] = [
        ("fable-5-1", Pricing(inputPerMTok: 10, outputPerMTok: 50, cacheReadMultiplier: 0.025)),
        ("mythos-5-1", Pricing(inputPerMTok: 10, outputPerMTok: 50, cacheReadMultiplier: 0.025)),
        // Fable/Mythos 5 read at the standard 0.1x, 4x their 5.1 successors.
        ("fable-5", Pricing(inputPerMTok: 10, outputPerMTok: 50)),
        ("mythos-5", Pricing(inputPerMTok: 10, outputPerMTok: 50)),
        ("fable", Pricing(inputPerMTok: 10, outputPerMTok: 50, cacheReadMultiplier: 0.025)),
        ("mythos", Pricing(inputPerMTok: 10, outputPerMTok: 50, cacheReadMultiplier: 0.025)),
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
            + Double(event.cacheReadTokens) * p.inputPerMTok * p.cacheReadMultiplier * perTok
            + Double(event.cacheCreation5mTokens) * p.inputPerMTok * 1.25 * perTok
            + Double(event.cacheCreation1hTokens) * p.inputPerMTok * 2.0 * perTok
            + Double(event.webSearchRequests) * webSearchPerRequest
        return (usd, known)
    }
}
