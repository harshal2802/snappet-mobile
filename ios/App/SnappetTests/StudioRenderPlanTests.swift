import XCTest
import CoreGraphics
@testable import Snappet

/// The pure render plan (prompt 300): which layers are on screen in each stretch of the output,
/// with which parameters. No AVFoundation — the compositor that draws the plan is covered by
/// `StudioCompositorRenderTests`.
final class StudioRenderPlanTests: XCTestCase {

    private let canvas = CGSize(width: 180, height: 320)

    private func clip(_ order: Int, seconds: Double = 4, speed: Double = 1,
                      filter: StudioFilter = .none, media: UUID? = nil) -> TimelineClip {
        TimelineClip(sessionMediaID: media, localIdentifier: "L\(order)", isPhoto: false, order: order,
                     trimEnd: seconds, speed: speed, filter: filter)
    }

    private func plan(_ clips: [TimelineClip], transitions: [StudioTransition] = [],
                      overlays: [OverlayItem] = [], pipSeconds: Double = 60,
                      baseFrame: StudioFrameRect? = nil,
                      background: StudioBackground = .black) -> StudioRenderPlan.Plan {
        let durations = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, 60.0) })
        let sizes = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, canvas) })
        let pips = Dictionary(uniqueKeysWithValues: overlays.filter { $0.kind == .video }.map {
            ($0.id, StudioRenderPlan.PiPSource(orientedSize: CGSize(width: 160, height: 90), durationSec: pipSeconds))
        })
        return StudioRenderPlan.make(clips: clips, sourceDurations: durations, orientedSizes: sizes,
                                     transitions: transitions, overlays: overlays, pipSources: pips,
                                     canvas: canvas, baseFrame: baseFrame, background: background)
    }

    private func total(_ clips: [TimelineClip], _ transitions: [StudioTransition]) -> Double {
        StudioGeometry.totalDuration(clips: clips,
                                     sourceDurations: Dictionary(uniqueKeysWithValues: clips.map { ($0.id, 60.0) }),
                                     transitions: transitions)
    }

    /// Segments are back to back from zero to the end, and every one has a main clip.
    private func assertContiguous(_ p: StudioRenderPlan.Plan, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.segments.first?.startSec, 0, file: file, line: line)
        XCTAssertEqual(p.segments.last?.endSec ?? -1, p.totalDuration, accuracy: 1e-9, file: file, line: line)
        for (a, b) in zip(p.segments, p.segments.dropFirst()) {
            XCTAssertEqual(a.endSec, b.startSec, accuracy: 1e-9, file: file, line: line)
        }
        for s in p.segments {
            XCTAssertGreaterThan(s.endSec, s.startSec, file: file, line: line)
            XCTAssertFalse(s.main.isEmpty, file: file, line: line)
        }
    }

    // MARK: Cuts

    func testCutsAreOneSegmentPerClipOnOneTrack() {
        let a = clip(0), b = clip(1, seconds: 2), c = clip(2, seconds: 3)
        let p = plan([c, a, b])                                   // order comes from `order`
        assertContiguous(p)
        XCTAssertEqual(p.totalDuration, 9, accuracy: 1e-9)
        XCTAssertEqual(p.totalDuration, total([a, b, c], []), accuracy: 1e-9)
        XCTAssertEqual(p.mainTrackCount, 1)
        XCTAssertEqual(p.segments.map { $0.main.map(\.clipID) }, [[a.id], [b.id], [c.id]])
        XCTAssertEqual(p.segments.map(\.startSec), [0, 4, 6])
        XCTAssertTrue(p.segments.allSatisfy { $0.clipB == nil && $0.transitionKind == nil && !$0.containsTweening })
        XCTAssertTrue(p.clips.allSatisfy { $0.audioFadeIn == nil && $0.audioFadeOut == nil })
        // A stored "cut" transition is a cut.
        let cut = plan([a, b], transitions: [StudioTransition(afterClipID: a.id, kind: .none, durationSec: 1)])
        XCTAssertEqual(cut.totalDuration, 6, accuracy: 1e-9)
        XCTAssertEqual(cut.segments.count, 2)
    }

    /// Trim and speed give the source range to insert; the output length is the editor's.
    func testSourceRangeFollowsTrimAndSpeed() {
        var a = clip(0, seconds: 10, speed: 2)
        a.trimStart = 2                                           // 8 s of source at 2× → 4 s out
        a.volume = 0.25
        let p = plan([a])
        XCTAssertEqual(p.clips[0].sourceStartSec, 2, accuracy: 1e-9)
        XCTAssertEqual(p.clips[0].sourceDurationSec, 8, accuracy: 1e-9)
        XCTAssertEqual(p.clips[0].durationSec, 4, accuracy: 1e-9)
        XCTAssertEqual(p.clips[0].volume, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.totalDuration, total([a], []), accuracy: 1e-9)
    }

    // MARK: Transitions

    /// Every kind: A alone, A + B over the overlap, B alone; two tracks; the audio cross-fades.
    func testEachTransitionKindMakesAnOverlapSegment() {
        for kind in StudioTransitionKind.allCases where kind != .none {
            let a = clip(0), b = clip(1)
            let t = [StudioTransition(afterClipID: a.id, kind: kind, durationSec: 1)]
            let p = plan([a, b], transitions: t)
            assertContiguous(p)
            XCTAssertEqual(p.totalDuration, 7, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(p.totalDuration, total([a, b], t), accuracy: 1e-9)
            XCTAssertEqual(p.mainTrackCount, 2)
            XCTAssertEqual(p.clips.map(\.trackIndex), [0, 1])
            XCTAssertEqual(p.segments.map { $0.main.map(\.clipID) }, [[a.id], [a.id, b.id], [b.id]])
            let mid = p.segments[1]
            XCTAssertEqual(mid.startSec, 3, accuracy: 1e-9)
            XCTAssertEqual(mid.endSec, 4, accuracy: 1e-9)
            XCTAssertEqual(mid.transitionKind, kind)
            XCTAssertEqual(mid.clipA?.leaving?.kind, kind)
            XCTAssertNil(mid.clipA?.entering)
            XCTAssertEqual(mid.clipB?.entering, StudioRenderPlan.TransitionPhase(kind: kind, startSec: 3, endSec: 4))
            XCTAssertEqual(mid.progressRange, 0 ... 1)
            XCTAssertTrue(mid.containsTweening)
            XCTAssertNil(p.segments[0].clipA?.leaving)            // before the overlap: no pose
            XCTAssertNil(p.segments[2].clipA?.entering)           // after it: no pose
            XCTAssertEqual(p.clips[0].audioFadeOut, 3 ... 4)
            XCTAssertEqual(p.clips[1].audioFadeIn, 3 ... 4)
            XCTAssertNil(p.clips[0].audioFadeIn)
            XCTAssertNil(p.clips[1].audioFadeOut)
        }
    }

    /// The overlap cannot be longer than either clip (the editor's rule).
    func testOverlapIsLimitedByTheShorterClip() {
        let a = clip(0), b = clip(1, seconds: 0.5)
        let t = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 2)]
        let p = plan([a, b], transitions: t)
        assertContiguous(p)
        XCTAssertEqual(p.totalDuration, 4, accuracy: 1e-9)
        XCTAssertEqual(p.totalDuration, total([a, b], t), accuracy: 1e-9)
        XCTAssertEqual(p.segments.last?.main.map(\.clipID), [a.id, b.id])
    }

    /// Three clips with two transitions alternate between two tracks.
    func testThreeClipsAlternateTracks() {
        let a = clip(0), b = clip(1), c = clip(2)
        let t = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1),
                 StudioTransition(afterClipID: b.id, kind: .slideLeft, durationSec: 1)]
        let p = plan([a, b, c], transitions: t)
        assertContiguous(p)
        XCTAssertEqual(p.totalDuration, total([a, b, c], t), accuracy: 1e-9)
        XCTAssertEqual(p.clips.map(\.trackIndex), [0, 1, 0])
        XCTAssertEqual(p.mainTrackCount, 2)
        XCTAssertEqual(p.segments.map { $0.main.count }, [1, 2, 1, 2, 1])
        XCTAssertEqual(p.segments[3].transitionKind, .slideLeft)
        XCTAssertEqual(p.clips[1].audioFadeIn, 3 ... 4)
        XCTAssertEqual(p.clips[1].audioFadeOut, 6 ... 7)
    }

    /// A short middle clip whose two transitions would meet: every moment still has a clip, no
    /// clip shares a track with one it overlaps, and its audio rises and then falls to silence —
    /// the shared stretch is split in the middle (it used to end at full volume, prompt 303).
    func testAShortMiddleClipKeepsTracksAndFadesApart() throws {
        let a = clip(0), b = clip(1, seconds: 1), c = clip(2)
        let t = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1),
                 StudioTransition(afterClipID: b.id, kind: .dissolve, durationSec: 1)]
        let p = plan([a, b, c], transitions: t)
        assertContiguous(p)
        XCTAssertEqual(p.totalDuration, total([a, b, c], t), accuracy: 1e-9)
        for (i, x) in p.clips.enumerated() {
            for y in p.clips[(i + 1)...] where x.trackIndex == y.trackIndex {
                XCTAssertTrue(x.endSec <= y.startSec + 1e-9 || y.endSec <= x.startSec + 1e-9)
            }
        }
        // B is 1 s long at 3…4, under both 1 s transitions: up over 3…3.5, down over 3.5…4.
        let mid = p.clips[1]
        XCTAssertEqual(mid.startSec, 3, accuracy: 1e-9)
        XCTAssertEqual(mid.endSec, 4, accuracy: 1e-9)
        let fadeIn = try XCTUnwrap(mid.audioFadeIn), fadeOut = try XCTUnwrap(mid.audioFadeOut)
        XCTAssertEqual(fadeIn.lowerBound, 3, accuracy: 1e-9)
        XCTAssertEqual(fadeIn.upperBound, 3.5, accuracy: 1e-9)
        XCTAssertEqual(fadeOut.lowerBound, 3.5, accuracy: 1e-9)
        XCTAssertEqual(fadeOut.upperBound, 4, accuracy: 1e-9)        // silent when the clip ends
        // The neighbours keep their whole transition.
        XCTAssertEqual(p.clips[0].audioFadeOut, 3 ... 4)
        XCTAssertEqual(p.clips[2].audioFadeIn, 3 ... 4)
    }

    /// The fade rule by itself: untouched when the two transitions do not meet, split in the
    /// middle of the shared stretch when they do.
    func testAudioFadesSplitTheSharedStretch() throws {
        typealias Phase = StudioRenderPlan.TransitionPhase
        let apart = StudioRenderPlan.audioFades(entering: Phase(kind: .dissolve, startSec: 3, endSec: 4),
                                                leaving: Phase(kind: .dissolve, startSec: 6, endSec: 7))
        XCTAssertEqual(apart.fadeIn, 3 ... 4)
        XCTAssertEqual(apart.fadeOut, 6 ... 7)
        let touching = StudioRenderPlan.audioFades(entering: Phase(kind: .dissolve, startSec: 3, endSec: 4),
                                                   leaving: Phase(kind: .dissolve, startSec: 4, endSec: 5))
        XCTAssertEqual(touching.fadeIn, 3 ... 4)
        XCTAssertEqual(touching.fadeOut, 4 ... 5)
        // 1.5 s clip at 3…4.5 under two 1 s transitions: they share 3.5…4, split at 3.75
        let meeting = StudioRenderPlan.audioFades(entering: Phase(kind: .dissolve, startSec: 3, endSec: 4),
                                                  leaving: Phase(kind: .slideLeft, startSec: 3.5, endSec: 4.5))
        XCTAssertEqual(try XCTUnwrap(meeting.fadeIn), 3 ... 3.75)
        XCTAssertEqual(try XCTUnwrap(meeting.fadeOut), 3.75 ... 4.5)
        let only = StudioRenderPlan.audioFades(entering: nil, leaving: Phase(kind: .dissolve, startSec: 1, endSec: 2))
        XCTAssertNil(only.fadeIn)
        XCTAssertEqual(only.fadeOut, 1 ... 2)
    }

    // MARK: Which clip a moment belongs to (prompt 303)

    /// The heart-rate tile's rule: during a transition the outgoing clip's tile holds until the
    /// middle, then the incoming clip's takes over. No moment has two tiles, none has no tile.
    func testEachClipOwnsItsSlotWithTransitionsSplitInTheMiddle() {
        let a = clip(0), b = clip(1), c = clip(2)
        let t = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)]   // A→B; B→C is a cut
        let p = plan([a, b, c], transitions: t)                   // A 0–4, B 3–7, C 7–11
        XCTAssertEqual(p.clips.map(\.ownedStartSec), [0, 3.5, 7])
        XCTAssertEqual(p.clips.map(\.ownedEndSec), [3.5, 7, 11])
        // back to back from zero to the end
        XCTAssertEqual(p.clips.first?.ownedStartSec, 0)
        XCTAssertEqual(p.clips.last?.ownedEndSec, p.totalDuration)
        for (x, y) in zip(p.clips, p.clips.dropFirst()) {
            XCTAssertEqual(x.ownedEndSec, y.ownedStartSec, accuracy: 1e-9)
        }
        // each window is inside the clip's own slot
        for m in p.clips {
            XCTAssertGreaterThanOrEqual(m.ownedStartSec, m.startSec)
            XCTAssertLessThanOrEqual(m.ownedEndSec, m.endSec)
        }

        // The short middle clip (1 s under two 1 s transitions): still no overlap and no gap.
        let short = clip(1, seconds: 1)
        let both = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1),
                    StudioTransition(afterClipID: short.id, kind: .dissolve, durationSec: 1)]
        let q = plan([a, short, c], transitions: both)
        for (x, y) in zip(q.clips, q.clips.dropFirst()) {
            XCTAssertEqual(x.ownedEndSec, y.ownedStartSec, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(x.ownedStartSec, x.ownedEndSec)
        }
        XCTAssertEqual(q.clips.first?.ownedStartSec, 0)
        XCTAssertEqual(q.clips.last?.ownedEndSec ?? -1, q.totalDuration, accuracy: 1e-9)

        // The editor asks the same rule which clip is under the playhead.
        let durations = [a.id: 60.0, b.id: 60.0, c.id: 60.0]
        let placed = StudioGeometry.timeline(clips: [a, b, c], sourceDurations: durations, transitions: t)
        XCTAssertEqual(StudioGeometry.ownerIndex(at: 3.2, in: placed), 0)     // first half of the dissolve
        XCTAssertEqual(StudioGeometry.ownerIndex(at: 3.5, in: placed), 1)     // the middle: B takes over
        XCTAssertEqual(StudioGeometry.ownerIndex(at: 3.9, in: placed), 1)
        XCTAssertEqual(StudioGeometry.ownerIndex(at: 7, in: placed), 2)       // a cut
        XCTAssertNil(StudioGeometry.ownerIndex(at: 11, in: placed))           // the very end
        XCTAssertNil(StudioGeometry.ownerIndex(at: 0, in: []))

        // The export shows a tile over the owned stretch, never outside the clip's slot.
        let gate = StudioOverlays.tileGate(slotStartSec: 3, slotDurationSec: 4,
                                           visibleStartSec: 3.5, visibleEndSec: 7)
        XCTAssertEqual(gate.start, 3.5)
        XCTAssertEqual(gate.end, 7)
        let whole = StudioOverlays.tileGate(slotStartSec: 3, slotDurationSec: 4,
                                            visibleStartSec: nil, visibleEndSec: nil)
        XCTAssertEqual(whole.start, 3)
        XCTAssertEqual(whole.end, 7)
        let clamped = StudioOverlays.tileGate(slotStartSec: 3, slotDurationSec: 4,
                                              visibleStartSec: 1, visibleEndSec: 9)
        XCTAssertEqual(clamped.start, 3)
        XCTAssertEqual(clamped.end, 7)
    }

    // MARK: Source lengths (prompt 303)

    /// The timeline's lengths: the real one where it has been read, the recorded one for a clip
    /// the caller says may fall back, nothing otherwise. A trim needs a known length.
    func testTimelineLengthsFallBackToTheRecordedLength() {
        let here = clip(0, seconds: 4), cloud = TimelineClip(sessionMediaID: nil, localIdentifier: "C",
                                                             isPhoto: false, order: 1)
        let unknown = TimelineClip(sessionMediaID: nil, localIdentifier: "U", isPhoto: false, order: 2)
        let photo = TimelineClip(sessionMediaID: nil, localIdentifier: "P", isPhoto: true, order: 3)
        let lengths = StudioGeometry.timelineSourceDurations(
            clips: [here, cloud, unknown, photo], resolved: [here.id: 10]) { clip in
                clip.id == here.id ? 99 : clip.id == cloud.id ? 6 : clip.id == photo.id ? 5 : nil
            }
        XCTAssertEqual(lengths, [here.id: 10, cloud.id: 6])       // resolved wins; a photo has none
        // never trimmed and not resolved: 0 s without the fallback, its recorded length with it
        XCTAssertEqual(StudioGeometry.clipOutputDuration(cloud, sourceDuration: nil), 0)
        XCTAssertEqual(StudioGeometry.clipOutputDuration(cloud, sourceDuration: lengths[cloud.id]), 6)
        XCTAssertEqual(StudioGeometry.totalDuration(clips: [here, cloud], sourceDurations: lengths,
                                                    transitions: []), 10)
        let bad = StudioGeometry.timelineSourceDurations(clips: [cloud], resolved: [:]) { _ in .nan }
        XCTAssertTrue(bad.isEmpty)

        XCTAssertEqual(StudioGeometry.trimSourceLength(cloud, resolved: 7, recorded: 6), 7)
        XCTAssertEqual(StudioGeometry.trimSourceLength(cloud, resolved: nil, recorded: 6), 6)
        XCTAssertEqual(StudioGeometry.trimSourceLength(here, resolved: nil, recorded: nil), 4)   // its trimmed end
        XCTAssertNil(StudioGeometry.trimSourceLength(unknown, resolved: nil, recorded: nil))
        XCTAssertNil(StudioGeometry.trimSourceLength(unknown, resolved: 0, recorded: 0))
        XCTAssertNil(StudioGeometry.trimSourceLength(photo, resolved: 5, recorded: 5))
    }

    // MARK: Transitions that do not apply

    /// A transition on the last clip, and one keyed to a clip that is not rendered, change nothing.
    func testUnusedTransitionsAreIgnored() {
        let a = clip(0), b = clip(1)
        let hidden = clip(2)
        let t = [StudioTransition(afterClipID: b.id, kind: .dissolve, durationSec: 1),       // last clip
                 StudioTransition(afterClipID: hidden.id, kind: .zoomIn, durationSec: 1)]    // not rendered
        let p = plan([a, b], transitions: t)
        XCTAssertEqual(p, plan([a, b]))
        XCTAssertEqual(p.totalDuration, 8, accuracy: 1e-9)
        XCTAssertEqual(p.mainTrackCount, 1)
        XCTAssertTrue(p.segments.allSatisfy { $0.transitionKind == nil })
    }

    /// "Edit this clip": the list is scoped before the plan is made. The transition out of the one
    /// visible clip leads to a hidden clip, so it does not shorten or change the render.
    func testScopedListDropsTheTransitionIntoAHiddenClip() {
        let mediaA = UUID(), mediaB = UUID()
        let a = clip(0, media: mediaA), b = clip(1, media: mediaB)
        let t = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)]
        let scoped = StudioGeometry.filterByMedia([a, b], to: [mediaA])
        let p = plan(scoped, transitions: t)
        XCTAssertEqual(p.totalDuration, 4, accuracy: 1e-9)
        XCTAssertEqual(p.totalDuration, total(scoped, t), accuracy: 1e-9)
        XCTAssertEqual(p.segments.count, 1)
        XCTAssertNil(p.segments[0].clipA?.leaving)
        XCTAssertNil(p.clips[0].audioFadeOut)
        // The whole list: the transition applies.
        XCTAssertEqual(plan([a, b], transitions: t).totalDuration, 7, accuracy: 1e-9)
    }

    // MARK: Everything together

    func testTransitionFilterAndPictureInPictureTogether() {
        var a = clip(0, filter: .mono)
        a.filterIntensity = 0.5
        a.adjust = ClipAdjust(brightness: 0.1, contrast: 1.2, saturation: 0.8)
        a.cropRect = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let b = clip(1, filter: .warm)
        let t = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)]
        let keys = [StudioKeyframe(timeSec: 2, value: 0, easing: .linear),
                    StudioKeyframe(timeSec: 6, value: 1, easing: .linear)]
        // The window starts in the middle of the dissolve and ends before the end.
        let pip = OverlayItem(kind: .video, content: "P", startSec: 3.5, endSec: 6,
                              position: CGPoint(x: 0.75, y: 0.25), normalizedWidth: 0.4, normalizedHeight: 0.3,
                              rotationDegrees: 10, opacity: 0.8, opacityKeyframes: keys)
        let text = OverlayItem(kind: .text, content: "Hi", startSec: 0, endSec: 2)
        let p = plan([a, b], transitions: t, overlays: [text, pip], background: .white)
        assertContiguous(p)
        XCTAssertEqual(p.background, .white)
        XCTAssertEqual(p.totalDuration, total([a, b], t), accuracy: 1e-9)
        XCTAssertEqual(p.pips.map(\.overlay.id), [pip.id])                    // text is not a layer
        XCTAssertEqual(p.segments.map(\.startSec), [0, 3, 3.5, 4, 6])
        XCTAssertEqual(p.segments.map { $0.main.count }, [1, 2, 2, 1, 1])
        XCTAssertEqual(p.segments.map { $0.pips.count }, [0, 0, 1, 1, 0])
        // The picture-in-picture cut the dissolve into two segments that share one progress.
        XCTAssertEqual(p.segments[1].progressRange, 0 ... 0.5)
        XCTAssertEqual(p.segments[2].progressRange, 0.5 ... 1)
        // Per-layer parameters survive into the segment that has all three.
        let all = p.segments[2]
        XCTAssertEqual(all.clipA?.filter, .mono)
        XCTAssertEqual(all.clipA?.filterIntensity, 0.5)
        XCTAssertEqual(all.clipA?.adjust, a.adjust)
        XCTAssertEqual(all.clipB?.filter, .warm)
        XCTAssertEqual(all.clipA?.placement.transform,
                       ClipEditGeometry.cropTransform(cropRect: a.cropRect, sourceSize: canvas, renderSize: canvas))
        let layer = try? XCTUnwrap(all.pips.first)
        XCTAssertEqual(layer?.frame, ClipEditGeometry.pipRect(normalizedCenter: pip.position, size: pip.pipSize, canvas: canvas))
        XCTAssertEqual(layer?.rotationDegrees, 10)
        XCTAssertEqual(layer?.opacity, 0.8)
        XCTAssertEqual(layer?.startSec, 3.5)
        XCTAssertEqual(layer?.endSec, 6)
        // Keyframes win over the fixed opacity, on absolute output time.
        if let layer {
            XCTAssertEqual(StudioRenderPlan.pipOpacity(layer, at: 4), 0.5, accuracy: 1e-9)
            XCTAssertEqual(StudioRenderPlan.pipOpacity(layer, at: 6), 1, accuracy: 1e-9)
            XCTAssertTrue(layer.isTweened)
        }
    }

    // MARK: Picture-in-picture windows

    func testPictureInPictureWindowIsCutToTheTimelineAndTheSource() {
        let a = clip(0)                                                       // 4 s
        let past = OverlayItem(kind: .video, content: "P", startSec: 3, endSec: 9)
        let p = plan([a], overlays: [past])
        XCTAssertEqual(p.totalDuration, 4, accuracy: 1e-9)                    // not made longer
        XCTAssertEqual(p.pips.first?.endSec, 4)
        assertContiguous(p)
        // Starts 0.05 s before the end: kept at its real length, the output is not made longer.
        let late = OverlayItem(kind: .video, content: "P", startSec: 3.95, endSec: 3.96)
        let lp = plan([a], overlays: [late])
        XCTAssertEqual(lp.totalDuration, 4, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(lp.pips.first?.endSec ?? 0, 4)
        // Starts after the end: left out.
        let after = OverlayItem(kind: .video, content: "P", startSec: 5, endSec: 9)
        XCTAssertTrue(plan([a], overlays: [after]).pips.isEmpty)
        // A 1 s source in a 3 s window plays for 1 s.
        let short = OverlayItem(kind: .video, content: "P", startSec: 1, endSec: 4)
        let sp = plan([a], overlays: [short], pipSeconds: 1)
        XCTAssertEqual(sp.pips.first?.endSec, 2)
        XCTAssertEqual(sp.segments.map { $0.pips.count }, [0, 1, 0])
        // With no keyframes the fixed opacity is used.
        let fixed = OverlayItem(kind: .video, content: "P", startSec: 0, endSec: 4, opacity: 0.3)
        let layer = plan([a], overlays: [fixed]).segments[0].pips[0]
        XCTAssertEqual(StudioRenderPlan.pipOpacity(layer, at: 2), 0.3, accuracy: 1e-9)
        XCTAssertFalse(layer.isTweened)
        // An overlay with no resolved source is not a layer.
        let none = StudioRenderPlan.make(clips: [a], sourceDurations: [a.id: 60], orientedSizes: [a.id: canvas],
                                         overlays: [fixed], pipSources: [:], canvas: canvas)
        XCTAssertTrue(none.pips.isEmpty)
    }

    /// Later overlays are drawn on top, as on the editor canvas.
    func testPictureInPictureOrderIsOverlayOrder() {
        let a = clip(0)
        let first = OverlayItem(kind: .video, content: "P1", startSec: 0, endSec: 4)
        let second = OverlayItem(kind: .video, content: "P2", startSec: 0, endSec: 4)
        let p = plan([a], overlays: [first, second])
        XCTAssertEqual(p.segments[0].pips.map(\.overlayID), [first.id, second.id])
        XCTAssertEqual(p.segments[0].pips.map(\.pipIndex), [0, 1])
    }

    // MARK: Placement

    func testBaseFramePlacesTheCropInsideItsCell() {
        let frame = StudioFrameRect.half                                      // centre y 0.27, full width, half height
        let cell = ClipEditGeometry.pipRect(normalizedCenter: frame.center, size: frame.size, canvas: canvas)
        // Whole source: fitted into the cell (the pre-300 behaviour).
        let whole = StudioRenderPlan.mainPlacement(orientedSize: canvas, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                   canvas: canvas, baseFrame: frame)
        XCTAssertEqual(whole.transform, ClipEditGeometry.fitTransform(sourceSize: canvas, into: cell))
        XCTAssertTrue(cell.insetBy(dx: -0.01, dy: -0.01).contains(whole.clip))
        XCTAssertEqual(whole.clip.height, cell.height, accuracy: 0.01)
        XCTAssertEqual(whole.clip.midX, cell.midX, accuracy: 0.01)
        // A crop to the top half: that region alone is fitted, and it is all that may draw.
        let crop = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let cropped = StudioRenderPlan.mainPlacement(orientedSize: canvas, cropRect: crop, canvas: canvas, baseFrame: frame)
        let cropPx = CGRect(x: 0, y: 0, width: 180, height: 160)
        XCTAssertEqual(cropped.clip.width / cropped.clip.height, cropPx.width / cropPx.height, accuracy: 0.001)
        XCTAssertTrue(cell.insetBy(dx: -0.01, dy: -0.01).contains(cropped.clip))
        XCTAssertEqual(cropPx.applying(cropped.transform).midX, cropped.clip.midX, accuracy: 0.001)
        // No frame, or a full one: the crop fills the canvas.
        for bf in [nil, StudioFrameRect(centerX: 0.5, centerY: 0.5, width: 1, height: 1)] {
            let full = StudioRenderPlan.mainPlacement(orientedSize: canvas, cropRect: crop, canvas: canvas, baseFrame: bf)
            XCTAssertEqual(full.clip, CGRect(origin: .zero, size: canvas))
            XCTAssertEqual(full.transform, ClipEditGeometry.cropTransform(cropRect: crop, sourceSize: canvas, renderSize: canvas))
        }
    }

    func testKenBurnsScaleIsOnTheClipsOwnTime() {
        var a = clip(0)
        var b = clip(1)
        b.scaleKeyframes = [StudioKeyframe(timeSec: 0, value: 1, easing: .linear),
                            StudioKeyframe(timeSec: 4, value: 2, easing: .linear)]
        a.scaleKeyframes = []
        let p = plan([a, b])
        let first = p.segments[0].main[0], second = p.segments[1].main[0]
        XCTAssertEqual(StudioRenderPlan.kenBurnsScale(first, at: 2), 1)
        XCTAssertFalse(p.segments[0].containsTweening)
        XCTAssertEqual(StudioRenderPlan.kenBurnsScale(second, at: 4), 1, accuracy: 1e-9)   // its first frame
        XCTAssertEqual(StudioRenderPlan.kenBurnsScale(second, at: 6), 1.5, accuracy: 1e-9)
        XCTAssertEqual(StudioRenderPlan.kenBurnsScale(second, at: 8), 2, accuracy: 1e-9)
        XCTAssertTrue(p.segments[1].containsTweening)
    }

    // MARK: Poses

    func testTransitionPoses() {
        let c = canvas
        func pose(_ k: StudioTransitionKind, _ r: StudioRenderPlan.TransitionRole, _ p: Double) -> StudioRenderPlan.Pose {
            StudioRenderPlan.pose(kind: k, role: r, progress: p, canvas: c)
        }
        // Every kind starts on the outgoing clip and ends on the incoming one, in place.
        for kind in StudioTransitionKind.allCases where kind != .none {
            XCTAssertEqual(pose(kind, .outgoing, 0), StudioRenderPlan.Pose(), "\(kind)")
            let end = pose(kind, .incoming, 1)
            XCTAssertEqual(end.opacity, 1, "\(kind)")
            XCTAssertEqual(end.transform.tx, 0, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(end.transform.a, 1, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(StudioRenderPlan.curtain(kind: kind, progress: 0), 0)
            XCTAssertEqual(StudioRenderPlan.curtain(kind: kind, progress: 1), 0)
        }
        XCTAssertEqual(pose(.dissolve, .incoming, 0.25).opacity, 0.25)
        XCTAssertEqual(pose(.dissolve, .outgoing, 0.25).opacity, 1)
        XCTAssertEqual(pose(.slideLeft, .incoming, 0.5).transform.tx, 90)
        XCTAssertEqual(pose(.slideLeft, .outgoing, 0.5).transform.tx, -90)
        XCTAssertEqual(pose(.slideRight, .incoming, 0.5).transform.tx, -90)
        XCTAssertEqual(pose(.slideRight, .outgoing, 0.5).transform.tx, 90)
        let zoom = pose(.zoomIn, .incoming, 0.5).transform
        XCTAssertEqual(zoom.a, 0.6, accuracy: 1e-9)
        let centre = CGPoint(x: 90, y: 160).applying(zoom)
        XCTAssertEqual(centre.x, 90, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 160, accuracy: 1e-9)
        XCTAssertEqual(pose(.fadeThroughBlack, .outgoing, 0.25).opacity, 1)
        XCTAssertEqual(pose(.fadeThroughBlack, .incoming, 0.25).opacity, 0)
        XCTAssertEqual(pose(.fadeThroughBlack, .outgoing, 0.75).opacity, 0)
        XCTAssertEqual(pose(.fadeThroughBlack, .incoming, 0.75).opacity, 1)
        XCTAssertEqual(StudioRenderPlan.curtain(kind: .fadeThroughBlack, progress: 0.5), 1)
        XCTAssertEqual(StudioRenderPlan.curtain(kind: .fadeThroughBlack, progress: 0.25), 0.5)
        XCTAssertEqual(StudioRenderPlan.curtain(kind: .dissolve, progress: 0.5), 0)
        XCTAssertEqual(pose(.none, .incoming, 0.5), StudioRenderPlan.Pose())
        // Progress is clamped.
        let phase = StudioRenderPlan.TransitionPhase(kind: .dissolve, startSec: 3, endSec: 4)
        XCTAssertEqual(phase.progress(at: 2), 0)
        XCTAssertEqual(phase.progress(at: 3.5), 0.5)
        XCTAssertEqual(phase.progress(at: 9), 1)
    }

    /// A clip with no playable length is not a layer and does not break the timeline.
    func testEmptyAndZeroLengthInputs() {
        let empty = plan([])
        XCTAssertEqual(empty.totalDuration, 0)
        XCTAssertTrue(empty.segments.isEmpty)
        var zero = clip(0)
        zero.trimStart = 4                                        // trimmed to nothing
        let a = clip(1)
        let p = plan([zero, a])
        XCTAssertEqual(p.clips.map(\.clip.id), [a.id])
        XCTAssertEqual(p.totalDuration, 4, accuracy: 1e-9)
        assertContiguous(p)
    }
}
