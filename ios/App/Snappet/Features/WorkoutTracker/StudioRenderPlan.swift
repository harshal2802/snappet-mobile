import Foundation
import CoreGraphics

/// The **pure render plan** of a Studio timeline (prompt 300): what is on screen at every moment of
/// the output, and with which parameters. `StudioComposer` builds the AVFoundation composition from
/// it and `StudioCompositor` draws it; neither decides anything the plan did not. Foundation and
/// CoreGraphics only, so it runs in `SnappetTests` with no AVFoundation.
///
/// Clip placement comes from `StudioGeometry.timeline`, the same function the editor's timeline
/// uses, so the render and the editor cannot disagree about where a clip starts or how long the
/// output is. A transition applies only when that function gives two clips an overlap: a transition
/// stored on the last clip, or on a clip that is not in the rendered list, has no effect here.
///
/// All geometry is in **canvas pixels, top-left origin** (the space `ClipEditGeometry` targets).
/// A layer's `transform` maps the source's **oriented** pixels (after `preferredTransform`) into it.
enum StudioRenderPlan {

    /// Times closer than this are one boundary (a composition tick is 1/600 s).
    static let epsilon = 1.0 / 300.0

    // MARK: Inputs

    /// What the plan needs to know about a picture-in-picture source.
    struct PiPSource: Equatable, Sendable {
        var orientedSize: CGSize
        /// The source's length in seconds; `0` or less = not known (the stored window is used).
        var durationSec: Double
    }

    // MARK: Output

    /// A transition between two clips, as the stretch of output time the two share.
    struct TransitionPhase: Equatable, Sendable {
        let kind: StudioTransitionKind
        let startSec: Double
        let endSec: Double

        /// `0` at the start of the overlap, `1` at its end (clamped).
        func progress(at t: Double) -> Double {
            let span = endSec - startSec
            guard span > 0 else { return 1 }
            return min(1, max(0, (t - startSec) / span))
        }
    }

    /// Where a layer's pixels go. `clip` is the part of the canvas the layer may draw into.
    struct Placement: Equatable, Sendable {
        let transform: CGAffineTransform
        let clip: CGRect
    }

    /// One clip of the main track, as drawn during one segment.
    struct MainLayer: Equatable, Sendable {
        let clipID: UUID
        /// Which of the plan's main video tracks holds this clip's frames.
        let trackIndex: Int
        let placement: Placement
        let filter: StudioFilter
        let filterIntensity: Double
        let adjust: ClipAdjust?
        /// Ken-Burns scale over the clip's own output time (seconds from `clipStartSec`).
        let scaleKeyframes: [StudioKeyframe]
        let clipStartSec: Double
        /// Set while this clip is coming in over the previous one.
        let entering: TransitionPhase?
        /// Set while the next clip is coming in over this one.
        let leaving: TransitionPhase?

        var isTweened: Bool { entering != nil || leaving != nil || !scaleKeyframes.isEmpty }
    }

    /// One picture-in-picture, as drawn during one segment.
    struct PiPLayer: Equatable, Sendable {
        let overlayID: UUID
        /// Index into `Plan.pips` (each picture-in-picture has its own video track).
        let pipIndex: Int
        /// The frame the editor outline shows.
        let frame: CGRect
        /// Aspect-fit of the oriented source into `frame`.
        let transform: CGAffineTransform
        let rotationDegrees: Double
        let opacity: Double
        /// Absolute output seconds, the same convention as the overlay canvas.
        let opacityKeyframes: [StudioKeyframe]
        let startSec: Double
        let endSec: Double

        var isTweened: Bool { !opacityKeyframes.isEmpty }
    }

    /// A stretch of output time during which the set of layers does not change.
    struct Segment: Equatable, Sendable {
        let startSec: Double
        let endSec: Double
        /// Main-track clips, bottom first. One during a clip, two during a transition.
        let main: [MainLayer]
        /// Picture-in-picture layers, bottom first (overlay order, the later one on top).
        let pips: [PiPLayer]

        /// The outgoing clip (or the only one).
        var clipA: MainLayer? { main.first }
        /// The incoming clip during a transition.
        var clipB: MainLayer? { main.count > 1 ? main.last : nil }
        var transitionKind: StudioTransitionKind? { clipB?.entering?.kind }
        /// How far the transition gets within this segment (a picture-in-picture that starts in
        /// the middle of a transition cuts it into two segments).
        var progressRange: ClosedRange<Double>? {
            guard let phase = clipB?.entering else { return nil }
            return phase.progress(at: startSec) ... phase.progress(at: endSec)
        }
        /// False when two frames of this segment made from the same source frames are identical.
        var containsTweening: Bool { main.contains(where: \.isTweened) || pips.contains(where: \.isTweened) }
    }

    /// A main-track clip on the output timeline, with the source range to insert and its audio.
    struct PlacedMain: Equatable, Sendable {
        let clip: TimelineClip
        let trackIndex: Int
        let startSec: Double
        let endSec: Double
        /// The part of the source that plays, in source seconds.
        let sourceStartSec: Double
        let sourceDurationSec: Double
        /// The clip's own audio volume, 0…1.
        let volume: Double
        /// Audio rises from 0 to `volume` over this stretch (the transition into the clip).
        let audioFadeIn: ClosedRange<Double>?
        /// Audio falls from `volume` to 0 over this stretch (the transition out of the clip).
        let audioFadeOut: ClosedRange<Double>?
        /// The stretch this clip OWNS (`StudioGeometry.ownedWindows`): its slot, with each
        /// transition split at its middle. Whatever is drawn for one clip at a time (its
        /// heart-rate tile) is shown over this stretch, so two clips' items never overlap and
        /// there is no moment without one (prompt 303).
        let ownedStartSec: Double
        let ownedEndSec: Double

        var durationSec: Double { endSec - startSec }
    }

    /// A picture-in-picture on the output timeline, cut to the timeline and to its source length.
    struct PlacedPiP: Equatable, Sendable {
        let overlay: OverlayItem
        let startSec: Double
        let endSec: Double
    }

    struct Plan: Equatable, Sendable {
        let canvas: CGSize
        let background: StudioBackground
        /// Equal to `StudioGeometry.totalDuration` for the rendered clips.
        let totalDuration: Double
        let clips: [PlacedMain]
        let pips: [PlacedPiP]
        /// Contiguous from `0` to `totalDuration`.
        let segments: [Segment]
        /// How many main video tracks the clips need (1 for cuts only, 2 with transitions).
        let mainTrackCount: Int
    }

    // MARK: Build

    /// - Parameters:
    ///   - clips: the clips that will be rendered (already scoped; photos and clips whose source
    ///     did not resolve are left out by the caller).
    ///   - sourceDurations: clip id → source length in seconds.
    ///   - orientedSizes: clip id → source size after its orientation.
    ///   - transitions: every stored transition; the ones that do not apply are ignored.
    ///   - overlays: every overlay; only `.video` ones with an entry in `pipSources` are used.
    static func make(clips: [TimelineClip],
                     sourceDurations: [UUID: Double],
                     orientedSizes: [UUID: CGSize],
                     transitions: [StudioTransition] = [],
                     overlays: [OverlayItem] = [],
                     pipSources: [UUID: PiPSource] = [:],
                     canvas: CGSize,
                     baseFrame: StudioFrameRect? = nil,
                     background: StudioBackground = .black) -> Plan {
        let placed = StudioGeometry.timeline(clips: clips, sourceDurations: sourceDurations,
                                             transitions: transitions)
        let total = placed.map(\.endSec).max() ?? 0

        // The overlap each clip shares with the next one, straight from the placement.
        var phaseAfter: [Int: TransitionPhase] = [:]
        for i in placed.indices.dropLast() {
            let start = placed[i + 1].startSec, end = placed[i].endSec
            guard end - start > epsilon,
                  let t = transitions.first(where: { $0.afterClipID == placed[i].clip.id }),
                  t.kind != .none else { continue }
            phaseAfter[i] = TransitionPhase(kind: t.kind, startSec: start, endSec: end)
        }

        // Tracks: a clip goes on the first track that is free when it starts.
        let owned = StudioGeometry.ownedWindows(placed)
        var trackEnds: [Double] = []
        var mains: [PlacedMain] = []
        var indexInPlaced: [Int] = []            // mains[n] is placed[indexInPlaced[n]]
        for (i, p) in placed.enumerated() where p.durationSec > epsilon {
            let track = trackEnds.firstIndex(where: { p.startSec >= $0 - 1e-9 }) ?? trackEnds.count
            if track == trackEnds.count { trackEnds.append(p.endSec) } else { trackEnds[track] = p.endSec }
            let fades = audioFades(entering: i > 0 ? phaseAfter[i - 1] : nil, leaving: phaseAfter[i])
            let speed = StudioGeometry.clampSpeed(p.clip.speed)
            mains.append(PlacedMain(clip: p.clip, trackIndex: track,
                                    startSec: p.startSec, endSec: p.endSec,
                                    sourceStartSec: p.clip.trimStart,
                                    sourceDurationSec: p.durationSec * speed,
                                    volume: min(1, max(0, p.clip.volume ?? 1)),
                                    audioFadeIn: fades.fadeIn, audioFadeOut: fades.fadeOut,
                                    ownedStartSec: owned[i].start, ownedEndSec: owned[i].end))
            indexInPlaced.append(i)
        }

        // Picture-in-picture windows, cut to the timeline and to the source.
        var pips: [PlacedPiP] = []
        for ov in overlays where ov.kind == .video {
            guard let src = pipSources[ov.id] else { continue }
            let start = max(0, ov.startSec)
            var end = min(max(start, ov.endSec), total)
            if src.durationSec > 0 { end = min(end, start + src.durationSec) }
            guard end - start > epsilon else { continue }
            pips.append(PlacedPiP(overlay: ov, startSec: start, endSec: end))
        }

        // Segment boundaries: every time the set of layers, or a transition, starts or ends.
        var cuts: [Double] = [0, total]
        for m in mains { cuts += [m.startSec, m.endSec] }
        for p in pips { cuts += [p.startSec, p.endSec] }
        var bounds: [Double] = []
        for c in cuts.sorted() where c >= 0 && c <= total {
            if let last = bounds.last, c - last <= epsilon { continue }
            bounds.append(c)
        }
        if let last = bounds.last, bounds.count > 1, total - last <= epsilon, last != total {
            bounds[bounds.count - 1] = total
        }

        var segments: [Segment] = []
        for (s, e) in zip(bounds, bounds.dropFirst()) {
            let mid = (s + e) / 2
            let main: [MainLayer] = mains.enumerated().compactMap { n, m in
                guard m.startSec <= mid, mid < m.endSec else { return nil }
                let i = indexInPlaced[n]
                let entering = i > 0 ? phaseAfter[i - 1].flatMap { $0.startSec <= mid && mid < $0.endSec ? $0 : nil } : nil
                let leaving = phaseAfter[i].flatMap { $0.startSec <= mid && mid < $0.endSec ? $0 : nil }
                return MainLayer(
                    clipID: m.clip.id, trackIndex: m.trackIndex,
                    placement: mainPlacement(orientedSize: orientedSizes[m.clip.id] ?? canvas,
                                             cropRect: m.clip.cropRect, canvas: canvas, baseFrame: baseFrame),
                    filter: m.clip.filter, filterIntensity: m.clip.filterIntensity, adjust: m.clip.adjust,
                    scaleKeyframes: m.clip.scaleKeyframes, clipStartSec: m.startSec,
                    entering: entering, leaving: leaving)
            }
            let pip: [PiPLayer] = pips.enumerated().compactMap { n, p in
                guard p.startSec <= mid, mid < p.endSec, let src = pipSources[p.overlay.id] else { return nil }
                let frame = ClipEditGeometry.pipRect(normalizedCenter: p.overlay.position,
                                                     size: p.overlay.pipSize, canvas: canvas)
                return PiPLayer(overlayID: p.overlay.id, pipIndex: n, frame: frame,
                                transform: ClipEditGeometry.fitTransform(sourceSize: src.orientedSize, into: frame),
                                rotationDegrees: p.overlay.rotationDegrees,
                                opacity: min(1, max(0, p.overlay.opacity)),
                                opacityKeyframes: p.overlay.opacityKeyframes,
                                startSec: p.startSec, endSec: p.endSec)
            }
            segments.append(Segment(startSec: s, endSec: e, main: main, pips: pip))
        }

        return Plan(canvas: canvas, background: background, totalDuration: total,
                    clips: mains, pips: pips, segments: segments, mainTrackCount: trackEnds.count)
    }

    // MARK: Audio fades

    /// A clip's audio fades: up over the transition into it, down over the transition out of it.
    /// A clip shorter than its two transitions together has them overlap; the shared part is then
    /// split in the middle, so the clip still rises and then falls to silence — it never ends at
    /// full volume (prompt 303).
    static func audioFades(entering: TransitionPhase?, leaving: TransitionPhase?)
        -> (fadeIn: ClosedRange<Double>?, fadeOut: ClosedRange<Double>?) {
        let fadeIn = entering.map { $0.startSec ... max($0.startSec, $0.endSec) }
        let fadeOut = leaving.map { $0.startSec ... max($0.startSec, $0.endSec) }
        guard let a = fadeIn, let b = fadeOut, b.lowerBound < a.upperBound else { return (fadeIn, fadeOut) }
        let middle = min(b.upperBound, max(a.lowerBound, (b.lowerBound + a.upperBound) / 2))
        return (a.lowerBound ... middle, middle ... b.upperBound)
    }

    // MARK: Per-layer geometry

    /// Where a main-track clip goes. With no base frame the cropped region fills the canvas
    /// (`ClipEditGeometry.cropTransform`). With a base frame the cropped region is fitted into the
    /// frame's cell and nothing outside the crop is drawn; the rest of the canvas is background.
    static func mainPlacement(orientedSize: CGSize, cropRect: CGRect, canvas: CGSize,
                              baseFrame: StudioFrameRect?) -> Placement {
        guard let bf = baseFrame, !bf.isFull else {
            return Placement(
                transform: ClipEditGeometry.cropTransform(cropRect: cropRect, sourceSize: orientedSize,
                                                          renderSize: canvas),
                clip: CGRect(origin: .zero, size: canvas))
        }
        let crop = ClipEditGeometry.sanitizedCropRect(cropRect)
        let w = max(1, abs(orientedSize.width)), h = max(1, abs(orientedSize.height))
        let cropPx = CGRect(x: crop.minX * w, y: crop.minY * h,
                            width: max(1, crop.width * w), height: max(1, crop.height * h))
        let cell = ClipEditGeometry.pipRect(normalizedCenter: bf.center, size: bf.size, canvas: canvas)
        let transform = CGAffineTransform(translationX: -cropPx.minX, y: -cropPx.minY)
            .concatenating(ClipEditGeometry.fitTransform(sourceSize: cropPx.size, into: cell))
        return Placement(transform: transform, clip: cropPx.applying(transform))
    }

    /// The Ken-Burns scale of a main layer at output time `t` (1 = none). The picture scales about
    /// the centre of its own area and stays clipped to it.
    static func kenBurnsScale(_ layer: MainLayer, at t: Double) -> Double {
        guard !layer.scaleKeyframes.isEmpty else { return 1 }
        let s = StudioGeometry.value(of: layer.scaleKeyframes, at: t - layer.clipStartSec, default: 1)
        return s.isFinite ? min(8, max(0.05, s)) : 1
    }

    /// A picture-in-picture's opacity at output time `t`: its keyframes if it has any, else its
    /// fixed opacity. The overlay canvas uses the same rule for text and tags.
    static func pipOpacity(_ layer: PiPLayer, at t: Double) -> Double {
        min(1, max(0, StudioGeometry.value(of: layer.opacityKeyframes, at: t, default: layer.opacity)))
    }

    // MARK: Transitions

    enum TransitionRole: Sendable { case outgoing, incoming }

    /// What a transition does to one of its two clips at `progress` (0…1): an opacity and a
    /// transform in canvas pixels, applied to the clip after it has been placed.
    struct Pose: Equatable, Sendable {
        var opacity: Double = 1
        var transform: CGAffineTransform = .identity
    }

    /// - dissolve: the incoming clip fades in over the outgoing one.
    /// - fade through black: the outgoing clip is shown for the first half and the incoming one for
    ///   the second, under a black cover (`curtain`) that closes and opens.
    /// - slide left / right: both clips move one canvas width; the incoming one pushes the outgoing
    ///   one off the named side.
    /// - zoom in: the incoming clip grows from a fifth of its size, about the canvas centre, over
    ///   the outgoing one.
    static func pose(kind: StudioTransitionKind, role: TransitionRole, progress: Double,
                     canvas: CGSize) -> Pose {
        let p = min(1, max(0, progress))
        switch (kind, role) {
        case (.none, _):
            return Pose()
        case (.dissolve, .outgoing):
            return Pose()
        case (.dissolve, .incoming):
            return Pose(opacity: p)
        case (.fadeThroughBlack, .outgoing):
            return Pose(opacity: p < 0.5 ? 1 : 0)
        case (.fadeThroughBlack, .incoming):
            return Pose(opacity: p < 0.5 ? 0 : 1)
        case (.slideLeft, .outgoing):
            return Pose(transform: CGAffineTransform(translationX: -p * canvas.width, y: 0))
        case (.slideLeft, .incoming):
            return Pose(transform: CGAffineTransform(translationX: (1 - p) * canvas.width, y: 0))
        case (.slideRight, .outgoing):
            return Pose(transform: CGAffineTransform(translationX: p * canvas.width, y: 0))
        case (.slideRight, .incoming):
            return Pose(transform: CGAffineTransform(translationX: -(1 - p) * canvas.width, y: 0))
        case (.zoomIn, .outgoing):
            return Pose()
        case (.zoomIn, .incoming):
            return Pose(transform: scale(0.2 + 0.8 * p, about: CGPoint(x: canvas.width / 2, y: canvas.height / 2)))
        }
    }

    /// The opacity of the black cover over the main track (0 = none). Only "fade through black"
    /// has one: closed at the middle of the transition.
    static func curtain(kind: StudioTransitionKind, progress: Double) -> Double {
        guard kind == .fadeThroughBlack else { return 0 }
        let p = min(1, max(0, progress))
        return 1 - abs(1 - 2 * p)
    }

    static func scale(_ s: Double, about c: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    }

    static func rotation(degrees: Double, about c: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    }
}
