import Foundation

struct DayStats: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var costUSD = 0.0
    var costIsApproximate = false
    var messageCount = 0
    /// The slice of `costUSD` billed by requests the user later rewound away.
    /// Those requests live only in an abandoned transcript snapshot, so they are
    /// folded into the surviving session rather than dropped — see
    /// `TranscriptLineageIndex`. Zero for all but a handful of sessions.
    var rewoundCostUSD = 0.0
    var rewoundMessageCount = 0

    static let empty = DayStats()

    /// All four token classes summed. Dominated by cache reads (the whole
    /// context is re-read every turn), so it runs ~50× the new-content count —
    /// useful for the cost estimate, misleading as a headline. Kept for logs.
    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// New content only — input + output, excluding cache reads/writes. This
    /// is what Claude's own usage view headlines as "total tokens"; we display
    /// it for the same reason and break cache out separately below.
    var inputOutputTokens: Int {
        inputTokens + outputTokens
    }

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheWriteTokens += event.cacheCreation5mTokens + event.cacheCreation1hTokens
        let (usd, known) = CostModel.cost(of: event)
        costUSD += usd
        if !known { costIsApproximate = true }
        messageCount += 1
    }

    /// Recasts everything counted so far as spend the user rewound away. Whether
    /// that's true is a property of the transcript these events came from, not of
    /// any single event, and it isn't known until every file has been read — so
    /// it's applied to the finished aggregate rather than event by event.
    mutating func markRewound() {
        rewoundCostUSD = costUSD
        rewoundMessageCount = messageCount
    }

    /// Folds another aggregate into this one — used to sum cached per-day
    /// buckets back into a window total without replaying the raw events.
    mutating func merge(_ other: DayStats) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        costUSD += other.costUSD
        costIsApproximate = costIsApproximate || other.costIsApproximate
        messageCount += other.messageCount
        rewoundCostUSD += other.rewoundCostUSD
        rewoundMessageCount += other.rewoundMessageCount
    }
}
