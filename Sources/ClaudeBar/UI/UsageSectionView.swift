import SwiftUI

struct UsageSectionView: View {
    let usage: UsageReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let usage {
                // Countdown text derives from resetsAt − now on each timeline
                // tick, so it self-corrects after sleep with no timer state.
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    VStack(alignment: .leading, spacing: 16) {
                        if let window = usage.fiveHour {
                            windowRow("Current Session", "5-hour window", window, now: context.date)
                        }
                        if let window = usage.sevenDay {
                            windowRow("All Models", "Weekly window (7 days)", window, now: context.date)
                        }
                        // Only shown once there's actual Sonnet usage — an
                        // always-0% row is noise for Opus-only users.
                        if let window = usage.sevenDaySonnet, window.utilization > 0 {
                            windowRow("Sonnet", "Weekly window", window, now: context.date)
                        }
                        // Authoritative dollar spend, straight from the server.
                        if let credit = usage.credit {
                            creditRow(credit)
                        }
                    }
                }
                sourceFootnote(usage.source)
            } else {
                SectionHeader("Usage")
                Text("No usage data yet — it appears after your next interaction with any Claude Code session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func windowRow(_ title: String, _ subtitle: String, _ window: UsageWindow, now: Date) -> some View {
        let color = usageColor(window.utilization)
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title, subtitle: subtitle) {
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(window.utilization >= 75 ? color : .primary)
            }
            CapsuleBar(value: window.utilization, tint: color)
            if let resetsAt = window.resetsAt {
                Text(Formatters.resetLine(to: resetsAt, from: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func creditRow(_ credit: CreditBalance) -> some View {
        let color = usageColor(credit.utilization)
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Usage Credits") {
                Text("$\(credit.usedUSD, specifier: "%.2f") of $\(credit.limitUSD, specifier: "%.2f")")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(credit.utilization >= 75 ? color : .primary)
            }
            CapsuleBar(value: credit.utilization, tint: color)
        }
    }

    @ViewBuilder
    private func sourceFootnote(_ source: UsageSource) -> some View {
        switch source {
        case .api(let asOf):
            agedFootnote(label: "via usage API", asOf: asOf)
        case .statusline(let asOf):
            agedFootnote(label: "via statusline", asOf: asOf)
        case .estimated:
            Text("estimated from local logs")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .unavailable(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    /// Source line that turns orange once the data is old enough to mistrust.
    private func agedFootnote(label: String, asOf: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let stale = context.date.timeIntervalSince(asOf) > 30 * 60
            Text("\(label) · \(Formatters.ago(from: asOf, to: context.date))\(stale ? " — stale" : "")")
                .font(.caption2)
                .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        }
    }
}

#Preview {
    UsageSectionView(usage: UsageReport(
        fiveHour: UsageWindow(utilization: 32, resetsAt: Date().addingTimeInterval(4 * 3600 + 27 * 60)),
        sevenDay: UsageWindow(utilization: 45, resetsAt: Date().addingTimeInterval(3 * 86_400)),
        sevenDaySonnet: nil,
        credit: CreditBalance(usedUSD: 5.29, limitUSD: 10, utilization: 53),
        source: .api(asOf: Date())
    ))
    .padding(16)
    .frame(width: 380)
}
