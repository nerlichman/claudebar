import SwiftUI

enum MenuBarLabelStyle: String, CaseIterable, Identifiable {
    case full      // gauge icon + percentage
    case percent   // percentage only
    case icon      // gauge icon only

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return "Icon + %"
        case .percent: return "% only"
        case .icon: return "Icon only"
        }
    }
}

/// The menu bar item itself. Menu bar extras render as template images, so
/// state is encoded in symbol + text rather than color. Compact styles save
/// menu bar width but expand back to symbol + text whenever something needs
/// attention (a waiting session, or usage ≥ 90%).
struct MenuBarLabel: View {
    let appState: AppState
    @AppStorage("menuBarLabelStyle") private var styleRaw = MenuBarLabelStyle.full.rawValue

    var body: some View {
        let style = MenuBarLabelStyle(rawValue: styleRaw) ?? .full

        // Note: SwiftUI's Label renders icon-only inside a MenuBarExtra
        // label, so icon + text must be composed manually.
        switch appState.menuBarAttention || style == .full ? MenuBarLabelStyle.full : style {
        case .full:
            HStack(spacing: 3) {
                icon
                Text(text)
            }
        case .percent:
            Text(text)
        case .icon:
            icon
        }
    }

    /// Attention states fall back to SF Symbols; the resting state shows the
    /// ClaudeBar brand mark (rendered as a template image so it tints with the
    /// menu bar).
    @ViewBuilder private var icon: some View {
        if let attentionSymbol {
            Image(systemName: attentionSymbol)
        } else {
            Image(nsImage: BrandMark.menuBarImage())
                .renderingMode(.template)
        }
    }

    private var attentionSymbol: String? {
        if appState.recentlyWaiting { return "exclamationmark.bubble.fill" }
        guard let fiveHour = appState.usage?.fiveHour else { return "questionmark.circle" }
        if fiveHour.utilization >= 90 { return "exclamationmark.triangle.fill" }
        return nil
    }

    private var text: String {
        guard let usage = appState.usage, let fiveHour = usage.fiveHour else { return "–" }
        let pct = "\(Int(fiveHour.utilization.rounded()))%"
        if case .estimated = usage.source { return "~\(pct)" }
        return pct
    }
}
