import SwiftUI

/// **Pulse Pro** shared chrome (workout-redesign E0) — the score-first hero numeral, the rolled-up stat
/// ribbon, and the glass-on-chrome modifier. These elevate the existing `SnappetColor`/`SnappetCard`
/// tokens (no rebrand) and are reused across the redesigned dashboard (E1), session detail (E2), and the
/// planner (E7). Pure SwiftUI value types — no HealthKit/SwiftData — so they preview + render anywhere.

/// One oversized, glanceable hero metric: a big rounded numeral with a caption above and an optional
/// secondary line, tinted by a discipline accent with a soft accent halo so the number "luminates" in
/// dark mode. The single dominant number per surface (Whoop/Gentler-Streak discipline); everything else
/// stays small + secondary. Coral (`brand`) is NOT used here — the hero is content, not a button.
struct DisciplineHero: View {
    let value: String
    let caption: String
    var sublabel: String? = nil
    var systemImage: String? = nil
    /// The discipline accent (wayfinding). Defaults to the gym-tracker ember.
    var accent: Color = SnappetColor.workout

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                }
                Text(caption.uppercased())
                    .font(.caption.weight(.bold)).tracking(0.6)
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(SnappetColor.ink)
                .contentTransition(.numericText())
                // A soft accent halo so the number reads as the focal point (calmer than a filled tile).
                .shadow(color: accent.opacity(reduceMotion ? 0 : 0.28), radius: 14, x: 0, y: 4)
                .accessibilityLabel("\(value) \(caption)")
            if let sublabel {
                Text(sublabel).font(.footnote).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rolled-up "stat ribbon" — a wrapping row of compact value chips, each tinted on its own axis: a
/// discipline accent for identity figures (top set, sends) or the performance ramp / a neutral ghost for
/// state. Mirrors the wireframes' `.spill` chips. Keep it to ~3 chips so it stays glanceable.
struct StatRibbon: View {
    struct Item: Identifiable {
        let id = UUID()
        var text: String
        var tint: Color = SnappetColor.textSecondary
        /// `true` → a soft tinted fill (identity/PR chip); `false` → a neutral ghost chip.
        var emphasized: Bool = false
        var systemImage: String? = nil
    }
    let items: [Item]

    var body: some View {
        // A wrapping HStack via a flexible layout; ≤3 items keeps it single-line on phones.
        HStack(spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    if let s = item.systemImage { Image(systemName: s).font(.caption2.weight(.bold)) }
                    Text(item.text).font(.caption.weight(.bold)).monospacedDigit().lineLimit(1)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(item.emphasized ? item.tint : SnappetColor.textSecondary)
                .background(
                    (item.emphasized ? item.tint.opacity(0.15) : SnappetColor.surfaceMuted),
                    in: Capsule()
                )
            }
        }
    }
}

extension View {
    /// Glass-on-chrome: a floating bar / control surface using `.ultraThinMaterial` over the discipline
    /// accent, with a hairline. Per the Pulse Pro rule, glass goes ONLY on floating chrome (command bars,
    /// the live ribbon, timer HUDs) — content cards stay flat (`snappetCard`/`snappetTile`). Degrades to
    /// a solid `surface` fill when `reduceTransparency` is on (the accessible fallback).
    func pulseGlassChrome(cornerRadius: CGFloat = SnappetRadius.lg,
                          reduceTransparency: Bool = false) -> some View {
        modifier(PulseGlassChrome(cornerRadius: cornerRadius, reduceTransparency: reduceTransparency))
    }
}

private struct PulseGlassChrome: ViewModifier {
    var cornerRadius: CGFloat
    var reduceTransparency: Bool

    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                if reduceTransparency {
                    shape.fill(SnappetColor.surface)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SnappetColor.hairline, lineWidth: 0.5)
            )
    }
}
