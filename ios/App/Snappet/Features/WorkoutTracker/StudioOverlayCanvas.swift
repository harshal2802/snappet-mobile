import SwiftUI

/// The **WYSIWYG overlay editing layer** drawn on top of the studio preview — the edits/CapCut
/// pattern: overlays are NOT baked into the live preview video (the Core Animation tool is
/// export-only — decisions.md), so each text/sticker overlay is a draggable SwiftUI chip here. A
/// `.video` (picture-in-picture) overlay IS composited into the player underneath, so its chip is a
/// draggable + **pinchable** frame outline (you see the real PiP through it and resize/place it).
///
/// Correctness: a chip is placed against the **displayed video rect** (the aspect-fit area inside the
/// player, via `ClipEditGeometry.displayRect`) using the SAME normalized `OverlayItem.position`
/// (0…1, top-left) the export reads — so what you place is what renders. Pure SwiftUI ⇒ works on the
/// simulator too.
struct StudioOverlayCanvas: View {
    let overlays: [OverlayItem]
    /// Canvas width:height (e.g. 9/16) — the preview video rect this layer aligns to.
    let ratio: CGFloat
    let selectedID: UUID?
    let onSelect: (UUID?) -> Void
    let onMove: (UUID, CGPoint) -> Void   // normalized 0…1, top-left
    let onScale: (UUID, Double) -> Void   // PiP frame size (0…1 of canvas)

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
                                onMove: { onMove(overlay.id, $0) },
                                onScale: { onScale(overlay.id, $0) })
                }
            }
        }
        .allowsHitTesting(true)
    }
}

/// One draggable overlay. Live drag feedback comes from a `@GestureState` offset; the new normalized
/// position is committed on drag end (one model write per drag). A `.video` overlay is also pinchable
/// (committing its scale on pinch end).
private struct OverlayChip: View {
    let overlay: OverlayItem
    let rect: CGRect
    let selected: Bool
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    let onScale: (Double) -> Void
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnify: CGFloat = 1

    var body: some View {
        let base = ClipEditGeometry.previewPoint(normalized: overlay.position, in: rect)
        content
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
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnify) { v, s, _ in if overlay.kind == .video { s = v.magnification } }
                    .onEnded { v in
                        if overlay.kind == .video { onScale(min(1, max(0.1, overlay.scale * v.magnification))) }
                    }
            )
    }

    @ViewBuilder private var content: some View {
        switch overlay.kind {
        case .video:
            // The real PiP shows through from the player; this is just the editable frame.
            let w = rect.width * overlay.scale * magnify
            let h = rect.height * overlay.scale * magnify
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
                .overlay(Image(systemName: "rectangle.on.rectangle").font(.caption2).foregroundStyle(.white.opacity(0.8)))
                .frame(width: max(24, w), height: max(24, h))
        case .sticker:
            Image(systemName: overlay.content)
                .font(.system(size: max(12, rect.height * 0.12 * overlay.scale), weight: .semibold))
                .foregroundStyle(Color(studioHex: overlay.colorHex))
                .rotationEffect(.degrees(overlay.rotationDegrees))
                .opacity(max(0.15, overlay.opacity)).padding(6)
        case .text:
            Text(overlay.content)
                .font(.system(size: max(8, rect.height * 0.05 * overlay.scale), weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: rect.width * 0.9)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .foregroundStyle(Color(studioHex: overlay.colorHex))
                .rotationEffect(.degrees(overlay.rotationDegrees))
                .opacity(max(0.15, overlay.opacity)).padding(6)
        }
    }
}

