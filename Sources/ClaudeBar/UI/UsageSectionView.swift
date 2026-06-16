import SwiftUI

struct UsageSectionView: View {
    let usage: UsageReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let usage {
                // Countdown text derives from resetsAt − now on each timeline
                // tick, so it self-corrects after sleep with no timer state.
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        if let window = usage.fiveHour {
                            windowRow("5-hour window", window, now: context.date)
                        }
                        if let window = usage.sevenDay {
                            windowRow("Weekly", window, now: context.date)
                        }
                        // Only shown once there's actual Sonnet usage — an
                        // always-0% row is noise for Opus-only users.
                        if let window = usage.sevenDaySonnet, window.utilization > 0 {
                            windowRow("Weekly (Sonnet)", window, now: context.date)
                        }
                        // Authoritative dollar spend, straight from the server.
                        if let credit = usage.credit {
                            creditRow(credit)
                        }
                    }
                }
                sourceFootnote(usage.source)
            } else {
                Text("No usage data yet — it appears after your next interaction with any Claude Code session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func windowRow(_ name: String, _ window: UsageWindow, now: Date) -> some View {
        let color: Color = window.utilization >= 90 ? .red
            : window.utilization >= 75 ? .orange : .accentColor
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name).font(.callout)
                Spacer()
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(window.utilization >= 75 ? color : .primary)
                if let resetsAt = window.resetsAt {
                    Text("· resets in \(Formatters.countdown(to: resetsAt, from: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(window.utilization, 100), total: 100)
                .controlSize(.small)
                .tint(color)
        }
    }

    private func creditRow(_ credit: CreditBalance) -> some View {
        let color: Color = credit.utilization >= 90 ? .red
            : credit.utilization >= 75 ? .orange : .accentColor
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Usage credits").font(.callout)
                Spacer()
                Text("$\(credit.usedUSD, specifier: "%.2f") of $\(credit.limitUSD, specifier: "%.2f")")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(credit.utilization >= 75 ? color : .primary)
            }
            ProgressView(value: min(credit.utilization, 100), total: 100)
                .controlSize(.small)
                .tint(color)
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
