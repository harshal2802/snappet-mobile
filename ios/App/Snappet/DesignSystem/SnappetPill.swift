import SwiftUI

// MARK: - Pills (prompt 213; shared app-wide since 216)

/// The calm chip of the restyled screens (Kilter, Clips): hairline outline, the accent (or a meaning `tint`) only when
/// selected / tinted. Browse chips (213) and the climb page's tags + log buttons (214) share it.
struct SnappetPill: ViewModifier {
    let selected: Bool
    var large = false
    /// A meaning colour for the outline + text (send green, project amber) instead of ink / the accent.
    var tint: Color? = nil

    func body(content: Content) -> some View {
        let edge = tint.map { $0.opacity(0.6) } ?? (selected ? SnappetColor.brand : SnappetColor.hairline)
        content
            .padding(.horizontal, large ? 16 : 11).padding(.vertical, large ? 9 : 6)
            .foregroundStyle(tint ?? (selected ? SnappetColor.brand : SnappetColor.ink))
            .background(selected ? (tint ?? SnappetColor.brand).opacity(0.12) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            .contentShape(Capsule())
    }
}

extension View {
    /// The calm chip: hairline outline, the accent only when selected (design-system step 3a).
    func snappetPill(selected: Bool, large: Bool = false, tint: Color? = nil) -> some View {
        modifier(SnappetPill(selected: selected, large: large, tint: tint))
    }
}
