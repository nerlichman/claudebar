import SwiftUI

/// A labeled token/cost summary for one time window (Today, This week, …).
/// Cost is what the usage would bill at API prices — informational for
/// subscription plans.
struct TodayStatsView: View {
    var title = "Today"
    let stats: DayStats

    var body: some View {
        if stats.messageCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(alignment: .firstTextBaseline) {
                    Text("\(Formatters.tokenCount(stats.inputOutputTokens)) tokens")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(stats.costIsApproximate ? "~" : "≈")$\(stats.costUSD, specifier: "%.2f")")
                        .font(.callout.monospacedDigit())
                    Text("API-equivalent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("in \(Formatters.tokenCount(stats.inputTokens))"
                    + " · out \(Formatters.tokenCount(stats.outputTokens))"
                    + " · cache read \(Formatters.tokenCount(stats.cacheReadTokens))"
                    + " · cache write \(Formatters.tokenCount(stats.cacheWriteTokens))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help(breakdown)
        }
    }

    private var breakdown: String {
        """
        Input: \(Formatters.tokenCount(stats.inputTokens))
        Output: \(Formatters.tokenCount(stats.outputTokens))
        Cache read: \(Formatters.tokenCount(stats.cacheReadTokens))
        Cache write: \(Formatters.tokenCount(stats.cacheWriteTokens))
        Messages: \(stats.messageCount)
        Cost is what this usage would bill at API prices — informational for subscription plans.
        """
    }
}
