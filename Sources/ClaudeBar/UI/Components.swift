import SwiftUI

/// Threshold tint shared by every usage bar/figure: accent (blue) when healthy,
/// orange nearing the cap, red at the cap.
func usageColor(_ utilization: Double) -> Color {
    utilization >= 90 ? .red : utilization >= 75 ? .orange : .accentColor
}

/// Thick, fully-rounded progress bar. Replaces the stock hairline
/// `ProgressView(.small)` so the fill is actually legible at a glance.
struct CapsuleBar: View {
    let value: Double        // 0…100
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(value, 100) / 100 * geo.size.width))
            }
        }
        .frame(height: height)
    }
}

/// Big bold section title with an optional gray inline subtitle and an optional
/// trailing accessory. The dropdown's headers all route through this so Usage,
/// Sessions and Today share one rhythm.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .bold))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
