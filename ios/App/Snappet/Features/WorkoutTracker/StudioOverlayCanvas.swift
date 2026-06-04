import SwiftUI

/// The **WYSIWYG overlay editing layer** drawn on top of the studio preview — the edits/CapCut
/// pattern: overlays are NOT baked into the live preview video (the Core Animation tool is
/// export-only — decisions.md), so each text/sticker overlay is a draggable SwiftUI chip here.
///
/// Correctness: the chip is placed against the **displayed video rect** (the aspect-fit area inside
/// the player, via `ClipEditGeometry.displayRect`) using the SAME normalized `OverlayItem.position`
/// (0…1, top-left) that the export `ClipEditGeometry.layerPoint` consumes — so a dragged overlay
/// lands at exactly the same spot in the exported file. Sizes mirror `StudioOverlays` (font =
/// canvas-height · 0.05 · scale; sticker = canvas-height · 0.12 · scale) so the preview matches.
///
/// Pure SwiftUI ⇒ this works on the **simulator** too (no device/Photos needed to position overlays).
struct StudioOverlayCanvas: View {
    let overlays: [OverlayItem]
    /// Canvas width:height (e.g. 9/16) — the preview video rect this layer aligns to.
    let ratio: CGFloat
    let selectedID: UUID?
    let onSelect: (UUID?) -> Void
    let onMove: (UUID, CGPoint) -> Void   // normalized 0…1, top-left

    var body: some View {
        GeometryReader { geo in
            let rect = ClipEditGeometry.displayRect(ratio: ratio, in: geo.size)
            ZStack {
                // Tapping empty canvas deselects (so the selection ring / delete affordance clears).
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { onSelect(nil) }
                ForEach(overlays) { overlay in
                    OverlayChip(overlay: overlay, rect: rect, selected: overlay.id == selectedID,
                                onSelect: { onSelect(overlay.id) },
                                onMove: { onMove(overlay.id, $0) })
                }
            }
        }
        .allowsHitTesting(true)
    }
}

/// One draggable overlay. Live drag feedback comes from a `@GestureState` offset; the new normalized
/// position is committed on drag end (one model write per drag, keeping undo clean).
private struct OverlayChip: View {
    let overlay: OverlayItem
    let rect: CGRect
    let selected: Bool
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        let base = ClipEditGeometry.previewPoint(normalized: overlay.position, in: rect)
        content
            .padding(6)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SnappetColor.workout, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .position(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onChanged { _ in if !selected { onSelect() } }
                    .onEnded { value in
                        let dropped = CGPoint(x: base.x + value.translation.width,
                                              y: base.y + value.translation.height)
                        onMove(ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: rect))
                    }
            )
    }

    @ViewBuilder private var content: some View {
        let color = Color(studioHex: overlay.colorHex)
        Group {
            if overlay.kind == .sticker {
                Image(systemName: overlay.content)
                    .font(.system(size: max(12, rect.height * 0.12 * overlay.scale), weight: .semibold))
            } else {
                Text(overlay.content)
                    .font(.system(size: max(8, rect.height * 0.05 * overlay.scale), weight: .semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: rect.width * 0.9)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
        }
        .foregroundStyle(color)
        .rotationEffect(.degrees(overlay.rotationDegrees))
        .opacity(max(0.15, overlay.opacity))   // keep faintly visible even at 0 so it stays draggable
    }
}

private extension Color {
    /// Parse a `#RRGGBB` hex (matches `StudioOverlays.uiColor`); falls back to white.
    init(studioHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .white; return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
