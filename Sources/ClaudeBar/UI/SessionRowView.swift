import SwiftUI

struct SessionRowView: View {
    let session: Session
    var stats: DayStats?
    var lifetimeStats: DayStats?
    var isExpanded = false
    var onToggleExpand: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    SessionFocus.focus(session)
                } label: {
                    rowContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .onHover { hovering = $0 }
                .help(helpText)

                if let onToggleExpand {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { onToggleExpand() } }) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(isExpanded ? .degrees(90) : .zero)
                            .frame(width: 16, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show details")
                }
            }

            if isExpanded {
                detailBlock
                    .padding(.leading, 26)
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: session.entrypoint.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .help(session.entrypoint.displayName)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? session.display.project)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                stateBadge
                if let stats, stats.messageCount > 0 {
                    Text("\(Formatters.tokenCount(stats.totalTokens)) · $\(stats.costUSD, specifier: "%.2f")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let stats, stats.messageCount > 0 {
                detailLine("Today", "\(Formatters.tokenCount(stats.totalTokens)) tok · $\(String(format: "%.2f", stats.costUSD))")
            }
            if let lifetimeStats, lifetimeStats.messageCount > 0 {
                detailLine("Total", "\(Formatters.tokenCount(lifetimeStats.totalTokens)) tok · $\(String(format: "%.2f", lifetimeStats.costUSD))")
                detailLine("Tokens", "in \(Formatters.tokenCount(lifetimeStats.inputTokens))"
                    + " · out \(Formatters.tokenCount(lifetimeStats.outputTokens))"
                    + " · cache \(Formatters.tokenCount(lifetimeStats.cacheReadTokens))r"
                    + " / \(Formatters.tokenCount(lifetimeStats.cacheWriteTokens))w")
            }
            if case .waiting(let reason) = session.state {
                detailLine("State", "waiting\(age.map { " \($0)" } ?? "") — \(reason)")
            }
            if let branch = session.gitBranch {
                detailLine("Branch", branch)
            }
            detailLine("Path", session.cwd)
            detailLine("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened)
                + (session.lastInteraction.map { " · last activity \(Formatters.ago(from: $0))" } ?? ""))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var helpText: String {
        "\(session.cwd)\nClick to open this session"
    }

    private var subtitle: String {
        var parts: [String] = []
        // What Claude is waiting on leads — it's the actionable bit.
        if case .waiting(let reason) = session.state { parts.append(reason) }
        parts.append(session.entrypoint.displayName)
        // When a title is the headline, the project name moves down here.
        if session.title != nil { parts.append(session.display.project) }
        if let detail = session.display.detail { parts.append(detail) }
        if let branch = session.gitBranch { parts.append("⎇ \(branch)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch session.state {
        case .active:
            badge(text: "Active", color: .green)
        case .waiting:
            // Reason lives in the subtitle/details — the badge stays narrow
            // so the session name keeps its space.
            badge(text: "Waiting\(age.map { " · \($0)" } ?? "")", color: .orange)
        case .idle:
            badge(text: "Idle\(age.map { " · \($0)" } ?? "")", color: .secondary)
        case .ended:
            badge(text: "Ended\(age.map { " · \($0)" } ?? "")", color: .secondary)
        }
    }

    /// Compact age of the last engagement, omitted when very recent.
    private var age: String? {
        guard let last = session.lastInteraction,
              Date().timeIntervalSince(last) > 5 * 60
        else { return nil }
        return Formatters.ageShort(from: last)
    }

    private func badge(text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
