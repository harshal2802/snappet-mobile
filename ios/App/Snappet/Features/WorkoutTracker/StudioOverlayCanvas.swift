import SwiftUI

/// The **WYSIWYG overlay editing layer** drawn on top of the studio preview — the edits/CapCut
/// pattern: overlays are NOT baked into the live preview video for the Core Animation kinds (the tool
/// is export-only — decisions.md), so each text/sticker/climb-name overlay is a draggable + **pinch-
/// to-resize** SwiftUI chip here. A `.video` (picture-in-picture) overlay IS composited into the
/// player underneath, so its chip is a draggable + corner-resizable **frame outline** (you see the
/// real PiP through it). The **base video** can likewise be framed into a collage cell, shown here as
/// a labelled "Main" frame. While any frame moves/resizes, rule-of-thirds **alignment guides** are
/// drawn and the frame **snaps** to them (when enabled).
///
/// Correctness: a chip/frame is placed against the **displayed video rect** (the aspect-fit area
/// inside the player, via `ClipEditGeometry.displayRect`) using the SAME normalized values the export
/// reads — so what you place is what renders. Pure SwiftUI ⇒ works on the simulator too.
struct StudioOverlayCanvas: View {
    let overlays: [OverlayItem]
    /// Canvas width:height (e.g. 9/16) — the preview video rect this layer aligns to.
    let ratio: CGFloat
    let selectedID: UUID?
    /// Whether a moving/resizing frame snaps to the alignment grid (drives the live guide lines too).
    let snapEnabled: Bool
    /// The main video's collage frame (normalized centre + size), or `nil` when it fills the canvas.
    let baseFrame: StudioFrameRect?
    let onSelect: (UUID?) -> Void
    let onMove: (UUID, CGPoint) -> Void           // text/sticker/climbName: normalized 0…1 centre
    let onScale: (UUID, Double) -> Void           // text/sticker/climbName: font scale (pinch)
    let onFrame: (UUID, CGPoint, CGSize) -> Void  // video PiP: normalized centre + size (0…1)
    let onBaseFrame: (CGPoint, CGSize) -> Void     // base-video collage frame: normalized centre + size

    /// Guide lines reported live by the active frame gesture (cleared on end).
    @State private var activeGuides: [StudioGridLayout.Guide] = []

    var body: some View {
        GeometryReader { geo in
            let rect = ClipEditGeometry.displayRect(ratio: ratio, in: geo.size)
            ZStack {
                // Tapping empty canvas deselects (so the selection ring / delete affordance clears).
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { onSelect(nil) }
                AlignmentGuides(guides: activeGuides, rect: rect)
                // Base-video collage frame (under the overlays) — always interactive when present.
                if let bf = baseFrame {
                    ResizableFrame(center: bf.center, size: bf.size, rect: rect, selected: true,
                                   snapEnabled: snapEnabled, label: "Main",
                                   onSelect: {}, onFrame: { onBaseFrame($0, $1) },
                                   onGuides: { activeGuides = $0 })
                        .accessibilityIdentifier("studioBaseFrame")
                }
                ForEach(overlays) { overlay in
                    if overlay.kind == .video {
                        ResizableFrame(center: overlay.position, size: overlay.pipSize, rect: rect,
                                       selected: overlay.id == selectedID, snapEnabled: snapEnabled,
                                       label: nil,
                                       onSelect: { onSelect(overlay.id) },
                                       onFrame: { onFrame(overlay.id, $0, $1) },
                                       onGuides: { activeGuides = $0 })
                    } else {
                        TextOverlayChip(overlay: overlay, rect: rect, selected: overlay.id == selectedID,
                                        onSelect: { onSelect(overlay.id) },
                                        onMove: { onMove(overlay.id, $0) },
                                        onScale: { onScale(overlay.id, $0) })
                    }
                }
            }
        }
        .allowsHitTesting(true)
    }
}

/// The rule-of-thirds / centre guide lines drawn over the display rect while a frame is being placed.
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

/// The four corners of a frame, relative to its centre.
private enum FrameCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    /// x = -1 leading / +1 trailing, y = -1 top / +1 bottom.
    var x: CGFloat { (self == .topTrailing || self == .bottomTrailing) ? 1 : -1 }
    var y: CGFloat { (self == .bottomLeading || self == .bottomTrailing) ? 1 : -1 }
}

/// A draggable + corner-resizable **frame outline** — the shared implementation for a picture-in-
/// picture cell and the base-video collage cell (the real video shows through the player beneath; this
/// is just the editable frame). Crucially the outline **and all four handles track the gesture live**
/// (corner-drag and pinch), so the box always matches where the video will land; the model is written
/// once on gesture end. `label` shows a caption ("Main") for the base frame; `nil` shows the PiP icon.
private struct ResizableFrame: View {
    let center: CGPoint        // committed normalized centre (0…1)
    let size: CGSize           // committed normalized size (0…1 per axis)
    let rect: CGRect
    let selected: Bool
    let snapEnabled: Bool
    let label: String?
    let onSelect: () -> Void
    let onFrame: (CGPoint, CGSize) -> Void
    let onGuides: ([StudioGridLayout.Guide]) -> Void

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnify: CGFloat = 1
    /// Live frame (normalized centre + size) during a corner-resize — drives both the outline and the
    /// handle positions so they move together; committed + cleared on drag-end.
    @State private var liveResize: ResizeFrame?

    private struct ResizeFrame { var center: CGPoint; var size: CGSize }

    /// The frame currently being shown: a live corner-resize wins, else the committed values, with the
    /// live pinch magnification folded into the size.
    private var effectiveCenter: CGPoint { liveResize?.center ?? center }
    private var effectiveSize: CGSize {
        let s = liveResize?.size ?? size
        return CGSize(width: clampSide(s.width * magnify), height: clampSide(s.height * magnify))
    }

    private var pointW: CGFloat { max(8, rect.width * effectiveSize.width) }
    private var pointH: CGFloat { max(8, rect.height * effectiveSize.height) }

    var body: some View {
        let centerPt = ClipEditGeometry.previewPoint(normalized: effectiveCenter, in: rect)
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
                .overlay {
                    if let label {
                        Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.35), in: Capsule())
                    } else {
                        Image(systemName: "rectangle.on.rectangle").font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: pointW, height: pointH)
            if selected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SnappetColor.workout, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: pointW, height: pointH)
                cornerHandles
            }
        }
        .contentShape(Rectangle())
        .position(x: centerPt.x + dragTranslation.width, y: centerPt.y + dragTranslation.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragTranslation) { value, state, _ in state = value.translation }
                .onChanged { value in
                    if !selected { onSelect() }
                    onGuides(liveGuides(translation: value.translation))
                }
                .onEnded { value in
                    let dropped = CGPoint(x: centerPt.x + value.translation.width,
                                          y: centerPt.y + value.translation.height)
                    let normalized = ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: rect)
                    onFrame(normalized, size); onGuides([])
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .updating($magnify) { v, s, _ in s = v.magnification }
                .onEnded { v in
                    onFrame(center, CGSize(width: clampSide(size.width * v.magnification),
                                           height: clampSide(size.height * v.magnification)))
                }
        )
    }

    /// Guides for the frame's centre as it's being dragged (so the snap lines preview live).
    private func liveGuides(translation: CGSize) -> [StudioGridLayout.Guide] {
        guard snapEnabled else { return [] }
        let centerPt = ClipEditGeometry.previewPoint(normalized: center, in: rect)
        let dropped = CGPoint(x: centerPt.x + translation.width, y: centerPt.y + translation.height)
        let c = ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: rect)
        return StudioGridLayout.snap(center: c, size: size).guides
    }

    private func clampSide(_ v: Double) -> Double { min(1, max(0.1, v)) }

    // MARK: Corner resize handles

    private var cornerHandles: some View {
        ZStack {
            ForEach(FrameCorner.allCases, id: \.self) { corner in
                CornerHandle { translation, ended in
                    commitResize(corner: corner, translation: translation, ended: ended)
                }
                .position(x: (pointW / 2) * corner.x + pointW / 2,
                          y: (pointH / 2) * corner.y + pointH / 2)
            }
        }
        .frame(width: pointW, height: pointH)
    }

    /// Resize from a corner: the opposite corner stays put, the dragged corner follows the gesture.
    /// Updates `liveResize` on each change (outline + handles track together) and commits on end.
    private func commitResize(corner: FrameCorner, translation: CGSize, ended: Bool) {
        let baseCenter = ClipEditGeometry.previewPoint(normalized: center, in: rect)
        let halfW = rect.width * size.width / 2
        let halfH = rect.height * size.height / 2
        let fixed = CGPoint(x: baseCenter.x - corner.x * halfW, y: baseCenter.y - corner.y * halfH)
        let dragged = CGPoint(x: baseCenter.x + corner.x * halfW + translation.width,
                              y: baseCenter.y + corner.y * halfH + translation.height)
        let newCenter = CGPoint(x: (fixed.x + dragged.x) / 2, y: (fixed.y + dragged.y) / 2)
        let newW = abs(dragged.x - fixed.x), newH = abs(dragged.y - fixed.y)
        let newSize = CGSize(width: clampSide(newW / rect.width), height: clampSide(newH / rect.height))
        let centerNorm = ClipEditGeometry.normalizedPoint(fromPreview: newCenter, in: rect)
        if ended {
            liveResize = nil
            onFrame(centerNorm, newSize); onGuides([])
        } else {
            liveResize = ResizeFrame(center: centerNorm, size: newSize)
            if snapEnabled { onGuides(StudioGridLayout.snap(center: centerNorm, size: newSize).guides) }
        }
    }
}

/// One draggable + pinch-resizable text/sticker/climb-name overlay. Live drag feedback comes from a
/// `@GestureState` offset; pinch scales the font live and both commit (one model write) on gesture
/// end. These render via the export-only Core Animation tool, so they're a pure SwiftUI chip here.
private struct TextOverlayChip: View {
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
                    .updating($magnify) { v, s, _ in s = v.magnification }
                    .onEnded { v in onScale(overlay.scale * v.magnification) }
            )
    }

    /// The live font scale: the committed `scale` times the in-progress pinch magnification.
    private var liveScale: Double { overlay.scale * magnify }

    @ViewBuilder private var content: some View {
        switch overlay.kind {
        case .sticker:
            Image(systemName: overlay.content)
                .font(.system(size: max(12, rect.height * 0.12 * liveScale), weight: .semibold))
                .foregroundStyle(Color(studioHex: overlay.colorHex))
                .rotationEffect(.degrees(overlay.rotationDegrees))
                .opacity(max(0.15, overlay.opacity)).padding(6)
        case .climbName:
            Text(overlay.content)
                .font(.system(size: max(8, rect.height * 0.04 * liveScale), weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(studioHex: overlay.colorHex))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .rotationEffect(.degrees(overlay.rotationDegrees))
                .opacity(max(0.15, overlay.opacity))
        default:   // .text (and any future Core-Animation kind)
            Text(overlay.content)
                .font(.system(size: max(8, rect.height * 0.05 * liveScale), weight: .semibold))
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

/// A small grab dot at a frame corner. Live drag is reported continuously (for outline + guide
/// previews) and once more on end (the commit), via `onChange(_:ended:)`. No local `.offset` — the
/// parent repositions the handle from the live frame, so the dragged dot tracks the finger exactly.
private struct CornerHandle: View {
    let onChange: (CGSize, Bool) -> Void
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        Circle()
            .fill(SnappetColor.workout)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onChanged { v in onChange(v.translation, false) }
                    .onEnded { v in onChange(v.translation, true) }
            )
    }
}
