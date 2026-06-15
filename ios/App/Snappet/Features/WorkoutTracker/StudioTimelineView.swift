import SwiftUI

/// The edits/CapCut **scrubbable timeline**: clip strips laid out left-to-right by output duration, a
/// **fixed centre playhead**, a time ruler, tap-to-select, and **drag-to-trim** handles on the
/// selected clip. Dragging the strip scrubs (seeks the preview + moves the playhead); during playback
/// the strip auto-advances because it's offset by `vm.currentTime`. The playhead always reads the time
/// under the centre line, so timecode ↔ timeline ↔ preview stay in sync.
///
/// Trimming is committed **once on drag-end** (live handle feedback is view-local), so there's one
/// undo entry + one preview rebuild per trim. Thumbnails are a device-only follow-up — strips are
/// coloured placeholders for now (the sim has no Photos either way).
struct StudioTimelineView: View {
    @Bindable var vm: StudioEditorViewModel

    /// Horizontal zoom: screen points per output second. `zoomPps` is the committed level; a live
    /// pinch multiplies it via `pinchScale`. Clamped 12…200 pt/s. Everything (offset, strip widths,
    /// ruler) reads `pps`, so the whole timeline zooms together.
    @State private var zoomPps: CGFloat = 50
    @GestureState private var pinchScale: CGFloat = 1
    private var pps: CGFloat { min(200, max(12, zoomPps * pinchScale)) }
    private let trackHeight: CGFloat = 56
    private let rulerHeight: CGFloat = 18
    /// Lane below the clips showing each overlay's on-screen window (drag to move, handles to trim).
    private let overlayLaneHeight: CGFloat = 30

    @State private var scrubStartTime: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let offsetX = w / 2 - CGFloat(vm.currentTime) * pps
            ZStack(alignment: .topLeading) {
                Color(white: 0.08)
                content(offsetX: offsetX)
                // Centre playhead — doubles as the VoiceOver scrubber: swipe up/down seeks ±1 s,
                // since the drag-to-scrub gesture is invisible to VoiceOver (#79).
                Rectangle().fill(.white).frame(width: 2)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .position(x: w / 2, y: geo.size.height / 2)
                    .accessibilityElement()
                    .accessibilityLabel("Playhead")
                    .accessibilityValue("\(timecodeLabel(vm.currentTime)) of \(timecodeLabel(vm.totalDuration))")
                    .accessibilityAdjustableAction { direction in
                        vm.seek(to: vm.currentTime + (direction == .increment ? 1 : -1))
                    }
            }
            .contentShape(Rectangle())
            .gesture(scrub(width: w))
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinchScale) { v, s, _ in s = v.magnification }
                    .onEnded { v in zoomPps = min(200, max(12, zoomPps * v.magnification)) }
            )
        }
        .frame(height: rulerHeight + trackHeight + overlayLaneHeight + 28)
        .clipped()
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Button { zoomPps = max(12, zoomPps * 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityIdentifier("timelineZoomOut")
                Button { zoomPps = min(200, zoomPps * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityIdentifier("timelineZoomIn")
            }
            .font(.footnote).foregroundStyle(.white.opacity(0.85))
            .padding(6).background(.black.opacity(0.35), in: Capsule()).padding(6)
        }
    }

    // MARK: Content (ruler + clip strips), shifted so currentTime sits under the playhead

    @ViewBuilder private func content(offsetX: CGFloat) -> some View {
        let placed = vm.placedClips
        ZStack(alignment: .topLeading) {
            ruler
                .frame(height: rulerHeight)
            ForEach(placed, id: \.clip.id) { p in
                clipStrip(p)
                    .offset(x: CGFloat(p.startSec) * pps, y: rulerHeight + 4)
            }
            ForEach(vm.timelineOverlays) { ov in
                OverlayBar(overlay: ov, pps: pps, height: overlayLaneHeight,
                           selected: ov.id == vm.selectedOverlayID, total: vm.totalDuration,
                           onSelect: { vm.selectOverlay(ov.id) },
                           onCommit: { start, end in vm.setOverlayTimeRange(ov.id, start: start, end: end) })
                    .offset(x: CGFloat(ov.startSec) * pps, y: rulerHeight + trackHeight + 12)
            }
        }
        .offset(x: offsetX)
    }

    private var ruler: some View {
        let total = max(1, Int(vm.totalDuration.rounded(.up)))
        return ZStack(alignment: .topLeading) {
            ForEach(0...total, id: \.self) { s in
                VStack(spacing: 2) {
                    Rectangle().fill(.white.opacity(0.3))
                        .frame(width: 1, height: s % 5 == 0 ? 8 : 4)
                    if s % 5 == 0 {
                        Text("\(s)s").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .offset(x: CGFloat(s) * pps)
            }
        }
    }

    // MARK: One clip strip (selectable; trim handles when selected)

    @ViewBuilder private func clipStrip(_ p: StudioGeometry.PlacedClip) -> some View {
        let selected = p.clip.id == vm.selectedClipID
        let width = max(8, CGFloat(p.durationSec) * pps)
        Button { vm.select(p.clip.id) } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(p.clip.isPhoto ? Color.orange.opacity(0.35) : Color(white: 0.22))
                HStack(spacing: 4) {
                    Image(systemName: p.clip.isPhoto ? "photo" : "video").font(.caption2)
                    if p.clip.filter != .none {
                        Text(p.clip.filter.display).font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(.white.opacity(0.8)).padding(.leading, 8)
            }
            .frame(width: width, height: trackHeight)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(SnappetColor.workout, lineWidth: selected ? 2.5 : 0))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) { if selected && !p.clip.isPhoto { handle(p, edge: .leading) } }
        .overlay(alignment: .trailing) { if selected && !p.clip.isPhoto { handle(p, edge: .trailing) } }
        .accessibilityIdentifier("timelineClip")
        // Meaningful label + (when selected & trimmable) trim actions in the rotor, so a VoiceOver
        // user who can't drag the handles can still trim (#79).
        .accessibilityLabel("\(p.clip.isPhoto ? "Photo" : "Video") clip, \(String(format: "%.1f", p.durationSec)) seconds\(selected ? ", selected" : "")")
        .accessibilityHint(selected ? "" : "Double-tap to select")
        .modifier(ClipTrimActions(enabled: selected && !p.clip.isPhoto, clip: p, vm: vm))
    }

    private enum Edge { case leading, trailing }

    private func handle(_ p: StudioGeometry.PlacedClip, edge: Edge) -> some View {
        TrimHandle(edge: edge == .leading ? .leading : .trailing) { deltaPoints in
            let deltaSec = Double(deltaPoints / pps) * p.clip.speed   // output points → source seconds
            let src = vm.sourceDuration(of: p.clip)
            let end = p.clip.trimEnd ?? src
            switch edge {
            case .leading:  vm.trimSelected(startSeconds: p.clip.trimStart + deltaSec, endSeconds: nil)
            case .trailing: vm.trimSelected(startSeconds: nil, endSeconds: end + deltaSec)
            }
        }
    }

    /// "m:ss" for the VoiceOver playhead value (#79).
    private func timecodeLabel(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: Scrub (drag the timeline → seek)

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if scrubStartTime == nil { scrubStartTime = vm.currentTime; vm.pause() }
                let t = (scrubStartTime ?? 0) - Double(value.translation.width / pps)
                vm.seek(to: t)
            }
            .onEnded { _ in scrubStartTime = nil }
    }
}

/// One overlay's on-screen window as a draggable bar in the timeline lane: drag the body to move the
/// whole window (keeping its length), or the leading/trailing edges to change start / end. Times are
/// committed **once on drag-end** (live feedback is view-local) — one undo entry per gesture.
private struct OverlayBar: View {
    let overlay: OverlayItem
    let pps: CGFloat
    let height: CGFloat
    let selected: Bool
    let total: Double
    let onSelect: () -> Void
    let onCommit: (_ start: Double, _ end: Double) -> Void

    @GestureState private var moveBy: CGFloat = 0

    private var length: Double { max(0.2, overlay.endSec - overlay.startSec) }

    var body: some View {
        let width = max(10, CGFloat(length) * pps)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(barColor.opacity(selected ? 0.9 : 0.6))
            HStack(spacing: 3) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(.white).padding(.horizontal, 6)
        }
        .frame(width: width, height: height)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: selected ? 1.5 : 0))
        .offset(x: moveBy)
        .onTapGesture { onSelect() }
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .updating($moveBy) { v, s, _ in s = v.translation.width }
                .onChanged { _ in if !selected { onSelect() } }
                .onEnded { v in
                    let delta = Double(v.translation.width / pps)
                    let start = max(0, overlay.startSec + delta)
                    onCommit(start, start + length)
                }
        )
        .overlay(alignment: .leading) { if selected { edge(.leading, width: width) } }
        .overlay(alignment: .trailing) { if selected { edge(.trailing, width: width) } }
        .accessibilityIdentifier("timelineOverlayBar")
    }

    private func edge(_ side: HorizontalEdge, width: CGFloat) -> some View {
        OverlayEdgeHandle(height: height) { deltaPoints in
            let deltaSec = Double(deltaPoints / pps)
            switch side {
            case .leading:  onCommit(overlay.startSec + deltaSec, overlay.endSec)
            case .trailing: onCommit(overlay.startSec, overlay.endSec + deltaSec)
            }
        }
    }

    private var barColor: Color { overlay.kind == .video ? .blue : SnappetColor.workout }
    private var icon: String {
        switch overlay.kind {
        case .video: return "rectangle.on.rectangle"
        case .sticker: return "star.square"
        case .climbName: return "signpost.right"
        case .text: return "textformat"
        }
    }
    private var label: String {
        overlay.content.replacingOccurrences(of: "\n", with: " ")
    }
}

/// A compact leading/trailing grab edge for an `OverlayBar`, sized to the lane. Reports its drag delta
/// (points) on end so the window is trimmed once per gesture.
private struct OverlayEdgeHandle: View {
    let height: CGFloat
    let onCommit: (CGFloat) -> Void
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(0.95))
            .frame(width: 7, height: height)
            .offset(x: drag)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($drag) { v, s, _ in s = v.translation.width }
                    .onEnded { v in onCommit(v.translation.width) }
            )
    }
}

/// A trim grab-handle. Live drag is shown via a local offset; the committed delta (in points) is
/// reported to the caller **on drag-end** (so the model is trimmed once, not per frame).
private struct TrimHandle: View {
    enum Edge { case leading, trailing }
    let edge: Edge
    let onCommit: (CGFloat) -> Void
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(SnappetColor.workout)
            .frame(width: 12, height: 44)
            .overlay(Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.caption2).foregroundStyle(.black))
            .offset(x: (edge == .leading ? -6 : 6) + drag)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($drag) { v, s, _ in s = v.translation.width }
                    .onEnded { v in onCommit(edge == .leading ? v.translation.width : v.translation.width) }
            )
            .accessibilityIdentifier(edge == .leading ? "timelineTrimLeading" : "timelineTrimTrailing")
    }
}

/// VoiceOver trim actions for the selected clip (#79): drag-to-trim handles are invisible to
/// VoiceOver, so the same trims are offered as rotor actions (±0.5 s on each edge). No-op when the
/// clip isn't a trimmable selection. `trimSelected` clamps the result.
private struct ClipTrimActions: ViewModifier {
    let enabled: Bool
    let clip: StudioGeometry.PlacedClip
    let vm: StudioEditorViewModel
    private let step = 0.5

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: "Trim end \(stepLabel) later") {
                    let end = clip.clip.trimEnd ?? vm.sourceDuration(of: clip.clip)
                    vm.trimSelected(startSeconds: nil, endSeconds: end + step)
                }
                .accessibilityAction(named: "Trim end \(stepLabel) earlier") {
                    let end = clip.clip.trimEnd ?? vm.sourceDuration(of: clip.clip)
                    vm.trimSelected(startSeconds: nil, endSeconds: end - step)
                }
                .accessibilityAction(named: "Trim start \(stepLabel) later") {
                    vm.trimSelected(startSeconds: clip.clip.trimStart + step, endSeconds: nil)
                }
                .accessibilityAction(named: "Trim start \(stepLabel) earlier") {
                    vm.trimSelected(startSeconds: clip.clip.trimStart - step, endSeconds: nil)
                }
        } else {
            content
        }
    }

    private var stepLabel: String { "half a second" }
}
