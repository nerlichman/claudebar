import Foundation

/// Pricing per million tokens. `PricingRegistry` supplies current prices for
/// the models it lists; this table is the fallback, verified against the
/// Claude API docs on 2026-10-09. Matched on the family name appearing
/// anywhere in the model id, not as a prefix: transcripts also carry bare aliases (`sonnet`) and
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
        /// model uses 0.1 except Fable/Mythos 5.1 (0.025) and Opus/Sonnet 5.5
        /// (0.05).
        var cacheReadMultiplier: Double = 0.1
        /// Applied to every token rate, cache included, when the response
        /// reports `speed: "fast"`. 1 for models without fast mode: Opus 4.6
        /// accepts the flag but bills at standard rates.
        var fastModeMultiplier: Double = 1
        var longContext: LongContext? = nil
    }

    /// Higher rates for a request whose whole prompt — uncached input, cache
    /// reads and cache writes together — exceeds `thresholdTokens`. Each
    /// request is tiered on its own, and the higher rates cover all of it.
    struct LongContext {
        let thresholdTokens: Int
        let inputPerMTok: Double
        let outputPerMTok: Double
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
        ("opus-5-5", Pricing(inputPerMTok: 4, outputPerMTok: 20, cacheReadMultiplier: 0.05, fastModeMultiplier: 2)),
        ("opus-5", Pricing(inputPerMTok: 5, outputPerMTok: 25, fastModeMultiplier: 2)),
        ("opus-4-8", Pricing(inputPerMTok: 5, outputPerMTok: 25, fastModeMultiplier: 2)),
        // Opus 4 (`claude-opus-4-20250514`) and 4.1 predate the 4.5 price cut.
        ("opus-4-1", Pricing(inputPerMTok: 15, outputPerMTok: 75)),
        ("opus-4-2025", Pricing(inputPerMTok: 15, outputPerMTok: 75)),
        ("opus-4", Pricing(inputPerMTok: 5, outputPerMTok: 25)),
        ("opus", Pricing(inputPerMTok: 4, outputPerMTok: 20, cacheReadMultiplier: 0.05, fastModeMultiplier: 2)),
        // Sonnet 4.6 and 4.5 stay at $3/$15; must precede the family entry.
        ("sonnet-4", Pricing(inputPerMTok: 3, outputPerMTok: 15)),
        ("sonnet-5-5", Pricing(inputPerMTok: 2, outputPerMTok: 10, cacheReadMultiplier: 0.05)),
        ("sonnet-5", Pricing(inputPerMTok: 2, outputPerMTok: 10)),
        ("sonnet", Pricing(inputPerMTok: 2, outputPerMTok: 10, cacheReadMultiplier: 0.05)),
        ("haiku-4", Pricing(inputPerMTok: 1, outputPerMTok: 5)),
        // Haiku 3.5 puts the version first: `claude-3-5-haiku-20241022`.
        ("3-5-haiku", Pricing(inputPerMTok: 0.8, outputPerMTok: 4)),
        ("haiku", haiku55),
    ]

    private static let haiku55 = Pricing(
        inputPerMTok: 0.1, outputPerMTok: 0.5,
        longContext: LongContext(thresholdTokens: 100_000, inputPerMTok: 0.5, outputPerMTok: 2.5)
    )

    /// Server-side web search is billed per request ($10 / 1,000), independent
    /// of the model. Web fetch is not separately billed.
    private static let webSearchPerRequest = 10.0 / 1_000

    static func pricing(forModel model: String) -> Pricing? {
        let id = model.lowercased()
        let builtIn = table.first { id.contains($0.family) }?.pricing
        guard let rates = PricingRegistry.shared.rates(forModel: id) else { return builtIn }
        return Pricing(
            inputPerMTok: rates.input,
            outputPerMTok: rates.output,
            cacheReadMultiplier: rates.cacheRead.map { $0 / rates.input } ?? 0.1,
            fastModeMultiplier: builtIn?.fastModeMultiplier ?? 1,
            longContext: rates.longContext.map { long in
                LongContext(
                    thresholdTokens: long.thresholdTokens,
                    inputPerMTok: long.input,
                    outputPerMTok: long.output,
                    cacheReadMultiplier: long.cacheRead.map { $0 / long.input } ?? 0.1
                )
            }
        )
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
        let promptTokens = event.inputTokens + event.cacheReadTokens
            + event.cacheCreation5mTokens + event.cacheCreation1hTokens
        let long = p.longContext.flatMap { promptTokens > $0.thresholdTokens ? $0 : nil }
        let input = long?.inputPerMTok ?? p.inputPerMTok
        let output = long?.outputPerMTok ?? p.outputPerMTok
        let cacheRead = long?.cacheReadMultiplier ?? p.cacheReadMultiplier
        let perTok = (event.isFastMode ? p.fastModeMultiplier : 1) / 1_000_000
        let usd = Double(event.inputTokens) * input * perTok
            + Double(event.outputTokens) * output * perTok
            + Double(event.cacheReadTokens) * input * cacheRead * perTok
            + Double(event.cacheCreation5mTokens) * input * 1.25 * perTok
            + Double(event.cacheCreation1hTokens) * input * 2.0 * perTok
            + Double(event.webSearchRequests) * webSearchPerRequest
        return (usd, known)
    }
}
