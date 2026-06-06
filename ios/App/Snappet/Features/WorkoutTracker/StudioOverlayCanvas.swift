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
    /// Oriented source aspect (w/h) per source `localIdentifier` — locks a frame's corner-resize to its
    /// footage so the outline hugs the aspect-fit video (no letterbox). Missing → free per-axis resize.
    let sourceAspects: [String: CGFloat]
    /// The base video's source aspect (locks the "Main" frame's resize), or `nil` if unresolved.
    let baseAspect: CGFloat?
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
                                   snapEnabled: snapEnabled, label: "Main", contentAspect: baseAspect,
                                   onSelect: {}, onFrame: { onBaseFrame($0, $1) },
                                   onGuides: { activeGuides = $0 })
                        .accessibilityIdentifier("studioBaseFrame")
                }
                ForEach(overlays) { overlay in
                    if overlay.kind == .video {
                        ResizableFrame(center: overlay.position, size: overlay.pipSize, rect: rect,
                                       selected: overlay.id == selectedID, snapEnabled: snapEnabled,
                                       label: nil, contentAspect: sourceAspects[overlay.content],
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
    /// Source aspect (screen w/h) to lock corner-resize to, so the frame keeps the footage aspect and
    /// the aspect-fit video fills it edge-to-edge. `nil` → free per-axis resize.
    let contentAspect: CGFloat?
    let onSelect: () -> Void
    let onFrame: (CGPoint, CGSize) -> Void
    let onGuides: ([StudioGridLayout.Guide]) -> Void

    @GestureState private var dragTranslation: CGSize = .zero   // move the whole frame
    @GestureState private var magnify: CGFloat = 1               // pinch-scale
    /// Live corner-resize state. Using `@GestureState` (not `@State`) is what keeps it flicker-free:
    /// it's bound to the gesture's lifecycle, and — crucially — the gesture-hosting handles stay
    /// anchored at the COMMITTED size (below), so a handle never moves out from under the finger and
    /// re-fires its own gesture. That round-trip (a `@State` driven from the handle's gesture feeding
    /// back into the handle's position) was the resize flicker.
    @GestureState private var cornerDrag: CornerDrag?

    private struct CornerDrag: Equatable { var corner: FrameCorner; var translation: CGSize }

    /// Committed frame size in points (× the live pinch) — the STABLE anchor the handles sit at.
    private var committedSizePts: CGSize {
        CGSize(width: max(8, rect.width * size.width * magnify),
               height: max(8, rect.height * size.height * magnify))
    }
    /// The live resized frame (centre + size, in points) while a corner is dragged — VISUAL only.
    private var liveFramePts: (center: CGPoint, size: CGSize)? {
        cornerDrag.map { resizedFrame(corner: $0.corner, translation: $0.translation).pts }
    }

    var body: some View {
        let committedCenter = ClipEditGeometry.previewPoint(normalized: center, in: rect)
        let outline = liveFramePts ?? (center: committedCenter, size: committedSizePts)
        ZStack {
            // The box outline resizes live but hosts NO gesture, so it can't feed back into the drag.
            // Drawn offset from the committed centre so the opposite corner stays put as it grows.
            boxOutline(size: outline.size)
                .offset(x: outline.center.x - committedCenter.x,
                        y: outline.center.y - committedCenter.y)
            if selected { cornerHandles }
        }
        .contentShape(Rectangle())
        .position(x: committedCenter.x + dragTranslation.width,
                  y: committedCenter.y + dragTranslation.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragTranslation) { value, state, _ in state = value.translation }
                .onChanged { value in
                    if !selected { onSelect() }
                    onGuides(liveGuides(translation: value.translation))
                }
                .onEnded { value in
                    let dropped = CGPoint(x: committedCenter.x + value.translation.width,
                                          y: committedCenter.y + value.translation.height)
                    onFrame(ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: rect), size)
                    onGuides([])
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

    /// The box rectangle + dashed selection outline + label/icon, sized to `size` (points). Hosts no
    /// gesture, so resizing it live can't disturb the corner drag.
    @ViewBuilder private func boxOutline(size: CGSize) -> some View {
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
            if selected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SnappetColor.workout, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .frame(width: size.width, height: size.height)
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

    /// Clamp a normalized size into [0.1, 1] on both axes **while preserving its w:h ratio** (so the
    /// aspect-locked frame doesn't distort when it hits a canvas edge).
    private func clampedAspectSize(_ s: CGSize) -> CGSize {
        var w = s.width, h = s.height
        if w > 1 { h *= 1 / w; w = 1 }
        if h > 1 { w *= 1 / h; h = 1 }
        if w < 0.1 { h *= 0.1 / w; w = 0.1 }
        if h < 0.1 { w *= 0.1 / h; h = 0.1 }
        return CGSize(width: min(1, max(0.1, w)), height: min(1, max(0.1, h)))
    }

    // MARK: Corner resize handles (gesture hosts anchored at the committed size → no feedback loop)

    private var cornerHandles: some View {
        let s = committedSizePts
        return ZStack {
            ForEach(FrameCorner.allCases, id: \.self) { corner in
                Circle()
                    .fill(SnappetColor.workout)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .position(x: (s.width / 2) * corner.x + s.width / 2,
                              y: (s.height / 2) * corner.y + s.height / 2)
                    // Only the dragged dot follows the finger; its committed anchor never moves, so the
                    // gesture's translation stays stable (this is the standard draggable pattern).
                    .offset(cornerDrag?.corner == corner ? cornerDrag!.translation : .zero)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .updating($cornerDrag) { v, state, _ in
                                state = CornerDrag(corner: corner, translation: v.translation)
                            }
                            .onChanged { v in
                                guard snapEnabled else { return }
                                let r = resizedFrame(corner: corner, translation: v.translation)
                                onGuides(StudioGridLayout.snap(center: r.centerNorm, size: r.sizeNorm).guides)
                            }
                            .onEnded { v in
                                let r = resizedFrame(corner: corner, translation: v.translation)
                                onFrame(r.centerNorm, r.sizeNorm); onGuides([])
                            }
                    )
            }
        }
        .frame(width: s.width, height: s.height)
    }

    /// Resize from a corner with the opposite corner fixed. Returns the new frame as normalized
    /// (centre + size, for commit / guides) AND in points (for the live outline). Locks to
    /// `contentAspect` when set so the box keeps the footage aspect and hugs the aspect-fit video.
    private func resizedFrame(corner: FrameCorner, translation: CGSize)
        -> (centerNorm: CGPoint, sizeNorm: CGSize, pts: (center: CGPoint, size: CGSize)) {
        let baseCenter = ClipEditGeometry.previewPoint(normalized: center, in: rect)
        let halfW = rect.width * size.width / 2, halfH = rect.height * size.height / 2
        let fixed = CGPoint(x: baseCenter.x - corner.x * halfW, y: baseCenter.y - corner.y * halfH)
        let dragged = CGPoint(x: baseCenter.x + corner.x * halfW + translation.width,
                              y: baseCenter.y + corner.y * halfH + translation.height)
        var newW = abs(dragged.x - fixed.x), newH = abs(dragged.y - fixed.y)
        if let r = contentAspect, r > 0 {
            if newW >= newH * r { newH = newW / r } else { newW = newH * r }
        }
        let sizeNorm = contentAspect != nil
            ? clampedAspectSize(CGSize(width: newW / rect.width, height: newH / rect.height))
            : CGSize(width: clampSide(newW / rect.width), height: clampSide(newH / rect.height))
        let sizePts = CGSize(width: max(8, sizeNorm.width * rect.width),
                             height: max(8, sizeNorm.height * rect.height))
        let signX: CGFloat = dragged.x >= fixed.x ? 1 : -1
        let signY: CGFloat = dragged.y >= fixed.y ? 1 : -1
        let centerPts = CGPoint(x: fixed.x + signX * sizePts.width / 2,
                                y: fixed.y + signY * sizePts.height / 2)
        let centerNorm = ClipEditGeometry.normalizedPoint(fromPreview: centerPts, in: rect)
        return (centerNorm, sizeNorm, (centerPts, sizePts))
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

