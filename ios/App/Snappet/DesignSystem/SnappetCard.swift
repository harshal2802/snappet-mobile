import SwiftUI

/// The shared "Snappet Pulse" card surface (issue #30 §4): one rounded surface, one soft
/// shadow, consistent padding — replaces the copy-pasted `tint.opacity(0.12)` + mixed
/// 14/16 corner radii across the suite.
private struct SnappetCardModifier: ViewModifier {
    var cornerRadius: CGFloat = SnappetRadius.md
    /// Use the muted tile fill instead of the elevated card surface (no shadow).
    var muted: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(SnappetSpacing.lg)
            .background(
                (muted ? SnappetColor.surfaceMuted : SnappetColor.surface),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(
                color: muted ? .clear : Color.black.opacity(0.06),
                radius: 10, x: 0, y: 4
            )
    }
}

extension View {
    /// An elevated card: `surface` fill, `SnappetRadius.md` corners, one soft shadow,
    /// consistent padding.
    func snappetCard(cornerRadius: CGFloat = SnappetRadius.md) -> some View {
        modifier(SnappetCardModifier(cornerRadius: cornerRadius, muted: false))
    }

    /// A flat "tile" surface using `surfaceMuted` (no shadow) — the token replacement for
    /// the old `tint.opacity(0.12)` tiles.
    func snappetTile(cornerRadius: CGFloat = SnappetRadius.md) -> some View {
        modifier(SnappetCardModifier(cornerRadius: cornerRadius, muted: true))
    }
}
