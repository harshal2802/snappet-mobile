import SwiftUI

/// The **WYSIWYG overlay editing layer** drawn on top of the studio preview — the edits/CapCut
/// pattern: overlays are NOT baked into the live preview video (the Core Animation tool is
/// export-only — decisions.md), so each text/sticker/climb-name overlay is a draggable SwiftUI chip
/// here. A `.video` (picture-in-picture) overlay IS composited into the player underneath, so its
/// chip is a draggable + **resizable** frame outline (drag corners or pinch; you see the real PiP
/// through it). While a PiP moves/resizes, rule-of-thirds **alignment guides** are drawn and the
/// frame **snaps** to them (when enabled).
///
/// Correctness: a chip is placed against the **displayed video rect** (the aspect-fit area inside the
/// player, via `ClipEditGeometry.displayRect`) using the SAME normalized `OverlayItem` position/size
/// the export reads — so what you place is what renders. Pure SwiftUI ⇒ works on the simulator too.
struct StudioOverlayCanvas: View {
    let overlays: [OverlayItem]
    /// Canvas width:height (e.g. 9/16) — the preview video rect this layer aligns to.
    let ratio: CGFloat
    let selectedID: UUID?
    /// Whether a moving/resizing PiP snaps to the alignment grid (drives the live guide lines too).
    let snapEnabled: Bool
    let onSelect: (UUID?) -> Void
    let onMove: (UUID, CGPoint) -> Void           // text/sticker/climbName: normalized 0…1, top-left
    let onFrame: (UUID, CGPoint, CGSize) -> Void  // video PiP: normalized centre + size (0…1)

    /// Guide lines reported live by the active PiP gesture (cleared on end).
    @State private var activeGuides: [StudioGridLayout.Guide] = []

    var body: some View {
        GeometryReader { geo in
            let rect = ClipEditGeometry.displayRect(ratio: ratio, in: geo.size)
            ZStack {
                // Tapping empty canvas deselects (so the selection ring / delete affordance clears).
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { onSelect(nil) }
                AlignmentGuides(guides: activeGuides, rect: rect)
                ForEach(overlays) { overlay in
                    OverlayChip(overlay: overlay, rect: rect, selected: overlay.id == selectedID,
                                snapEnabled: snapEnabled,
                                onSelect: { onSelect(overlay.id) },
                                onMove: { onMove(overlay.id, $0) },
                                onFrame: { onFrame(overlay.id, $0, $1) },
                                onGuides: { activeGuides = $0 })
                }
            }
        }
        .allowsHitTesting(true)
    }
}

/// The rule-of-thirds / centre guide lines drawn over the display rect while a PiP is being placed.
private struct AlignmentGuides: View {
    let guides: [StudioGridLayout.Guide]
    let rect: CGRect

    var body: some View {
        ZStack {
            ForEach(Array(guides.enumerated()), id: \.offset) { _, g in
                switch g.axis {
                case .vertical:
                    Rectangle().fill(SnappetColor.workout.opacity(0.9)).frame(width: 1, height: rect.height)
                        .position(x: rect.minX + g.position * rect.width, y: rect.midY)
                case .horizontal:
                    Rectangle().fill(SnappetColor.workout.opacity(0.9)).frame(width: rect.width, height: 1)
                        .position(x: rect.midX, y: rect.minY + g.position * rect.height)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One draggable overlay. Live drag feedback comes from a `@GestureState` offset; the new normalized
/// position is committed on drag end (one model write per drag). A `.video` overlay is also resizable
/// (pinch or corner handles), committing its frame on gesture end.
private struct OverlayChip: View {
    let overlay: OverlayItem
    let rect: CGRect
    let selected: Bool
    let snapEnabled: Bool
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    let onFrame: (CGPoint, CGSize) -> Void
    let onGuides: ([StudioGridLayout.Guide]) -> Void
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnify: CGFloat = 1

    private var isVideo: Bool { overlay.kind == .video }

    var body: some View {
        let base = ClipEditGeometry.previewPoint(normalized: overlay.position, in: rect)
        content
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SnappetColor.workout, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .overlay { if selected && isVideo { cornerHandles } }
            .contentShape(Rectangle())
            .position(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onChanged { value in
                        if !selected { onSelect() }
                        if isVideo { onGuides(liveGuides(translation: value.translation)) }
                    }
                    .onEnded { value in
                        let dropped = CGPoint(x: base.x + value.translation.width,
                                              y: base.y + value.translation.height)
                        let normalized = ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: rect)
                        if isVideo { onFrame(normalized, overlay.pipSize); onGuides([]) }
                        else { onMove(normalized) }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnify) { v, s, _ in if isVideo { s = v.magnification } }
                    .onEnded { v in
                        if isVideo {
                            let s = overlay.pipSize
                            onFrame(overlay.position,
                                    CGSize(width: clampSide(s.width * v.magnification),
                                           height: clampSide(s.height * v.magnification)))
                        }
                    }
            )
    }

    /// Guides for the PiP's centre as it's being dragged (so the snap lines preview live).
    private func liveGuides(translation: CGSize) -> [StudioGridLayout.Guide] {
        guard snapEnabled else { return [] }
        let dropped = CGPoint(x: ClipEditGeometry.previewPoint(normalized: overlay.position, in: rect).x + translation.width,
                              y: ClipEditGeometry.previewPoint(normalized: overlay.position, in: rect).y + translation.height)
        let center = ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: rect)
        return StudioGridLayout.snap(center: center, size: overlay.pipSize).guides
    }

    private func clampSide(_ v: Double) -> Double { min(1, max(0.1, v)) }

    // MARK: Corner resize handles (video PiP only)

    /// Four draggable corners that resize the frame keeping the opposite corner fixed, committing the
    /// new normalized centre + size on drag-end.
    private var cornerHandles: some View {
        let w = rect.width * overlay.pipSize.width
        let h = rect.height * overlay.pipSize.height
        return ZStack {
            ForEach(Corner.allCases, id: \.self) { corner in
                CornerHandle { translation, ended in
                    commitResize(corner: corner, translation: translation, ended: ended)
                }
                .position(x: (w / 2) * corner.x + w / 2, y: (h / 2) * corner.y + h / 2)
            }
        }
        .frame(width: w, height: h)
    }

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        /// Sign of the corner relative to centre: x = -1 leading / +1 trailing, y = -1 top / +1 bottom.
        var x: CGFloat { (self == .topTrailing || self == .bottomTrailing) ? 1 : -1 }
        var y: CGFloat { (self == .bottomLeading || self == .bottomTrailing) ? 1 : -1 }
    }

    /// Resize from a corner: the opposite corner stays put, the dragged corner follows the gesture.
    private func commitResize(corner: Corner, translation: CGSize, ended: Bool) {
        let baseCenter = ClipEditGeometry.previewPoint(normalized: overlay.position, in: rect)
        let halfW = rect.width * overlay.pipSize.width / 2
        let halfH = rect.height * overlay.pipSize.height / 2
        let fixed = CGPoint(x: baseCenter.x - corner.x * halfW, y: baseCenter.y - corner.y * halfH)
        let dragged = CGPoint(x: baseCenter.x + corner.x * halfW + translation.width,
                              y: baseCenter.y + corner.y * halfH + translation.height)
        let newCenter = CGPoint(x: (fixed.x + dragged.x) / 2, y: (fixed.y + dragged.y) / 2)
        let newW = abs(dragged.x - fixed.x), newH = abs(dragged.y - fixed.y)
        let size = CGSize(width: clampSide(newW / rect.width), height: clampSide(newH / rect.height))
        let center = ClipEditGeometry.normalizedPoint(fromPreview: newCenter, in: rect)
        if ended { onFrame(center, size); onGuides([]) }
        else if snapEnabled { onGuides(StudioGridLayout.snap(center: center, size: size).guides) }
    }

    @ViewBuilder private var content: some View {
        switch overlay.kind {
        case .video:
            // The real PiP shows through from the player; this is just the editable frame.
            let w = rect.width * overlay.pipSize.width * (selected ? 1 : magnify)
            let h = rect.height * overlay.pipSize.height * (selected ? 1 : magnify)
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
        case .climbName:
            Text(overlay.content)
                .font(.system(size: max(8, rect.height * 0.04 * overlay.scale), weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(studioHex: overlay.colorHex))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .rotationEffect(.degrees(overlay.rotationDegrees))
                .opacity(max(0.15, overlay.opacity))
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

/// A small grab dot at a PiP corner. Live drag is local; the translation is reported continuously
/// (for guide previews) and once more on end (the commit), via `onChange(_:ended:)`.
private struct CornerHandle: View {
    let onChange: (CGSize, Bool) -> Void
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        Circle()
            .fill(SnappetColor.workout)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .offset(drag)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onChanged { v in onChange(v.translation, false) }
                    .onEnded { v in onChange(v.translation, true) }
            )
    }
}
