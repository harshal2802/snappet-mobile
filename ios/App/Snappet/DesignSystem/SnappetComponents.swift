import SwiftUI

/// Components for the calmer style (design-system reset, prompt 211; mockup
/// `docs/ux-research/design-system/home-periwinkle.html`): one card everywhere, big numbers with small units, thin
/// bars, list rows that show they open something. Colours come from `SnappetColor` (the accent is the user's).

// MARK: - Panel (the one card)

private struct SnappetPanelModifier: ViewModifier {
    var glow: Bool

    func body(content: Content) -> some View {
        content
            .padding(SnappetSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SnappetRadius.panel, style: .continuous)
                    .fill(SnappetColor.surface)
                    .overlay(alignment: .bottomTrailing) {
                        // A soft accent wash on the ONE card you should act on — not on every card.
                        if glow {
                            Circle().fill(SnappetColor.brandGlow).frame(width: 190, height: 190)
                                .blur(radius: 40).offset(x: 50, y: 60)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.panel, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: SnappetRadius.panel, style: .continuous)
                .strokeBorder(SnappetColor.hairline, lineWidth: 1))
    }
}

extension View {
    /// The one card: 20-pt radius, 1-pt hairline, 16-pt padding; `glow` for the card you should act on.
    func snappetPanel(glow: Bool = false) -> some View { modifier(SnappetPanelModifier(glow: glow)) }
}

// MARK: - Metric

/// A big light number with a small unit — "382 XP", "27 weeks".
struct SnappetMetric: View {
    let value: String
    var unit: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(SnappetType.metric).monospacedDigit().foregroundStyle(SnappetColor.ink)
            if let unit { Text(unit).font(SnappetType.metricUnit).foregroundStyle(SnappetColor.textSecondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Thin bars

/// A week's worth of thin bars: zero days show a short neutral stub, active days the accent. Bar heights come
/// from the pure `SnappetBars.heights`.
struct SnappetBars: View {
    let values: [Double]
    var labels: [String] = []
    var height: CGFloat = 38

    /// Fractions 0…1 per value (the tallest = 1). Zero (or no data) → a stub so empty days still read as days.
    static func heights(_ values: [Double], stub: Double = 0.12) -> [Double] {
        let top = values.max() ?? 0
        guard top > 0 else { return values.map { _ in stub } }
        return values.map { $0 > 0 ? max(stub, $0 / top) : stub }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(Self.heights(values).enumerated()), id: \.offset) { i, h in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(values[i] > 0 ? SnappetColor.brand : SnappetColor.hairline)
                        .frame(height: max(3, height * h))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            if !labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 9.5)).foregroundStyle(SnappetColor.textTertiary).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Row

/// A list row that opens something: icon tile, title, grey subtitle, chevron. Every row on Home is one of these —
/// "nothing on Home you can't tap into" (user, 2026-10-29).
struct SnappetRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Text(icon).font(.system(size: 15))
                .frame(width: 32, height: 32)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                if let subtitle { Text(subtitle).snappetDetail().lineLimit(1) }
            }
            Spacer(minLength: 4)
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SnappetColor.textTertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Buttons

/// The primary action: a filled accent capsule with `onBrand` text.
struct SnappetPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(SnappetColor.onBrand)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(SnappetColor.brand, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == SnappetPrimaryButtonStyle {
    static var snappetPrimary: SnappetPrimaryButtonStyle { SnappetPrimaryButtonStyle() }
}
