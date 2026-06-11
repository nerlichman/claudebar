import Foundation

struct DayStats: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var costUSD = 0.0
    var costIsApproximate = false
    var messageCount = 0

    static let empty = DayStats()

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
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
}
