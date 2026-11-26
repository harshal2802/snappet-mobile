import XCTest
import SwiftData
import AVFoundation
@testable import Snappet

/// A baked clip keeps its heart-rate timing (prompt 305): the pure `BakedTimeMap` a bake computes,
/// the one rule that combines it with `SessionMedia.offsetSec` (`ClipCaptureClock`), every reader
/// that goes through it, and the Studio view model's bake and revert with stand-ins (in-memory
/// store, no device).
///
/// The heart-rate series used throughout is `bpm = 100 + t`, so a reading names the second of the
/// session it was taken from: 112 is session second 12.
final class BakedClipHRTimeTests: XCTestCase {

    private let ramp: [HRPoint] = (0...120).map { HRPoint(t: Double($0), bpm: 100 + Double($0)) }

    private func part(_ order: Int, from: Double = 0, to: Double? = nil, speed: Double = 1,
                      id: UUID = UUID()) -> TimelineClip {
        TimelineClip(id: id, sessionMediaID: nil, localIdentifier: "A", isPhoto: false, order: order,
                     trimStart: from, trimEnd: to, speed: speed)
    }

    /// The map for parts of one 20 s asset.
    private func map(_ parts: [TimelineClip], transitions: [StudioTransition] = [],
                     existing: BakedTimeMap? = nil, isRevertible: Bool = true) -> BakedTimeMap? {
        ClipBakePlan.timeMap(parts: parts,
                             sourceDurations: Dictionary(uniqueKeysWithValues: parts.map { ($0.id, 20.0) }),
                             transitions: transitions, existing: existing, isRevertible: isRevertible)
    }

    private func segment(_ rendition: Double, _ source: Double, _ speed: Double = 1) -> BakedTimeMap.Segment {
        .init(renditionStartSec: rendition, sourceStartSec: source, speed: speed)
    }

    private func assertMap(_ map: BakedTimeMap?, _ segments: [BakedTimeMap.Segment], length: Double,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let map else { return XCTFail("no map", file: file, line: line) }
        XCTAssertEqual(map.segments.count, segments.count, file: file, line: line)
        for (got, want) in zip(map.segments, segments) {
            XCTAssertEqual(got.renditionStartSec, want.renditionStartSec, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(got.sourceStartSec, want.sourceStartSec, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(got.speed, want.speed, accuracy: 1e-6, file: file, line: line)
        }
        XCTAssertEqual(map.renditionDurationSec, length, accuracy: 1e-6, file: file, line: line)
    }

    // MARK: The map a bake computes (pure)

    /// Nothing that changes timing was baked: no map is stored, not an identity map.
    func testNothingTrimmedStoresNoMap() {
        XCTAssertNil(map([part(0)]))
        XCTAssertNil(map([part(0, to: 12)]), "an end trim alone moves no frame")
        // a split with nothing removed is the recording again
        XCTAssertNil(map([part(0, to: 5), part(1, from: 5)]))
        XCTAssertNil(ClipBakePlan.timeMap(parts: [], sourceDurations: [:], transitions: []))
    }

    func testAStartTrim() {
        let m = map([part(0, from: 2)])
        assertMap(m, [segment(0, 2)], length: 18)
        XCTAssertEqual(m?.isPlainShift, true)
        XCTAssertEqual(m?.isIdentity, false)
        XCTAssertEqual(m?.isRevertible, true)
        let clock = ClipCaptureClock(offsetSec: 10, timeMap: m)
        XCTAssertEqual(clock.captureTime(renditionTime: 0), 12)
        XCTAssertEqual(clock.captureTime(renditionTime: 3), 15)
        XCTAssertEqual(clock.captureStartSec, 12)
    }

    func testAStartAndAnEndTrim() {
        let m = map([part(0, from: 2, to: 6)])
        assertMap(m, [segment(0, 2)], length: 4)
        let window = ClipCaptureClock(offsetSec: 10, timeMap: m).captureWindow(renditionStart: 0, renditionEnd: 4)
        XCTAssertEqual(window.start, 12)
        XCTAssertEqual(window.span, 4)
    }

    /// Slow motion: 4 s of the recording play for 8 s, so 8 s of video read 4 s of heart rate.
    func testHalfSpeed() {
        let m = map([part(0, from: 2, to: 6, speed: 0.5)])
        assertMap(m, [segment(0, 2, 0.5)], length: 8)
        let clock = ClipCaptureClock(offsetSec: 10, timeMap: m)
        XCTAssertEqual(clock.captureTime(renditionTime: 4), 14)
        XCTAssertEqual(clock.captureTime(renditionTime: 8), 16)
        let window = clock.captureWindow(renditionStart: 0, renditionEnd: 8)
        XCTAssertEqual(window.start, 12)
        XCTAssertEqual(window.span, 4)
    }

    /// Double speed, also with nothing trimmed: the map is not the identity.
    func testDoubleSpeed() {
        let m = map([part(0, from: 2, to: 6, speed: 2)])
        assertMap(m, [segment(0, 2, 2)], length: 2)
        XCTAssertEqual(ClipCaptureClock(offsetSec: 10, timeMap: m).captureTime(renditionTime: 1), 14)
        let whole = map([part(0, to: 8, speed: 2)])
        assertMap(whole, [segment(0, 0, 2)], length: 4)
        XCTAssertEqual(whole?.isPlainShift, false)
        let window = ClipCaptureClock(offsetSec: 10, timeMap: whole).captureWindow(renditionStart: 0, renditionEnd: 4)
        XCTAssertEqual(window.start, 10)
        XCTAssertEqual(window.span, 8, "4 s of 2× video is 8 s of the session")
    }

    /// Two kept ranges joined, with 2 s left out between them.
    func testTwoSplitPartsWithAGap() {
        let m = map([part(0, to: 3), part(1, from: 5, to: 8)])
        assertMap(m, [segment(0, 0), segment(3, 5)], length: 6)
        let clock = ClipCaptureClock(offsetSec: 10, timeMap: m)
        // a boundary belongs to the segment that starts there
        XCTAssertEqual(clock.captureTime(renditionTime: 2.5), 12.5)
        XCTAssertEqual(clock.captureTime(renditionTime: 3), 15)
        XCTAssertEqual(clock.captureTime(renditionTime: 3.5), 15.5)
        XCTAssertEqual(clock.captureTime(renditionTime: 6), 18)
        XCTAssertEqual(m?.segmentIndex(at: 0), 0)
        XCTAssertEqual(m?.segmentIndex(at: 2.999), 0)
        XCTAssertEqual(m?.segmentIndex(at: 3), 1)
        XCTAssertEqual(m?.segmentIndex(at: -1), 0, "before the start reads the first segment")
        XCTAssertEqual(m?.segmentIndex(at: 99), 1, "past the end reads the last")
        // the window runs from the first kept frame to the last, across the left-out seconds
        let whole = clock.captureWindow(renditionStart: 0, renditionEnd: 6)
        XCTAssertEqual(whole.start, 10)
        XCTAssertEqual(whole.span, 8)
        // a range inside one part is that part's own stretch
        let second = clock.captureWindow(renditionStart: 3, renditionEnd: 6)
        XCTAssertEqual(second.start, 15)
        XCTAssertEqual(second.span, 3)
        // an empty range is the moment itself
        let moment = clock.captureWindow(renditionStart: 3, renditionEnd: 3)
        XCTAssertEqual(moment.start, 15)
        XCTAssertEqual(moment.span, 0)
    }

    /// Parts joined in the other order: the window still runs from the earliest frame to the latest.
    func testPartsOutOfRecordingOrder() {
        let m = map([part(0, from: 5, to: 8), part(1, to: 3)])
        assertMap(m, [segment(0, 5), segment(3, 0)], length: 6)
        XCTAssertEqual(m?.earliestSourceSec, 0)
        let whole = ClipCaptureClock(offsetSec: 10, timeMap: m).captureWindow(renditionStart: 0, renditionEnd: 6)
        XCTAssertEqual(whole.start, 10)
        XCTAssertEqual(whole.span, 8)
    }

    /// A transition between two parts is split at its middle: the outgoing part gives the times
    /// for the first half, the incoming part for the second.
    func testATransitionBetweenPartsIsSplitAtItsMiddle() {
        let a = part(0, to: 4), b = part(1, from: 6, to: 10)
        let m = map([a, b], transitions: [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)])
        // A plays 0–4, B 3–7; A owns 0–3.5, B 3.5–7. B is 0.5 s into its footage at 3.5.
        assertMap(m, [segment(0, 0), segment(3.5, 6.5)], length: 7)
    }

    /// A second bake renders the FIRST bake's video, so its trims are times in that video.
    func testASecondBakeIsComposedWithTheFirst() {
        let first = map([part(0, from: 2, to: 6)])                       // 4 s: recording 2…6
        assertMap(first, [segment(0, 2)], length: 4)
        // trim the baked video to 1…3 and double its speed
        let second = map([part(0, from: 1, to: 3, speed: 2)], existing: first)
        assertMap(second, [segment(0, 3, 2)], length: 1)
        XCTAssertEqual(ClipCaptureClock(offsetSec: 10, timeMap: second).captureTime(renditionTime: 0.5), 14)
        // 2× on top of 2× is 4×
        let fast = map([part(0, to: 8, speed: 2)])
        assertMap(map([part(0, to: 4, speed: 2)], existing: fast), [segment(0, 0, 4)], length: 2)
        // a second bake that changes no timing keeps the first map
        XCTAssertEqual(map([part(0)], existing: first)?.segments, first?.segments)
    }

    /// The second bake's range crosses the first bake's join: the jump is kept, at its new place.
    func testASecondBakeAcrossAJoin() {
        let joined = map([part(0, to: 3), part(1, from: 5, to: 8)])      // recording 0…3, then 5…8
        let second = map([part(0, from: 2, to: 5)], existing: joined)
        assertMap(second, [segment(0, 2), segment(1, 5)], length: 3)
        // at 2× the join comes after half the time
        let fast = map([part(0, from: 2, to: 5, speed: 2)], existing: joined)
        assertMap(fast, [segment(0, 2, 2), segment(0.5, 5, 2)], length: 1.5)
        // undoing the first bake's trim in the second is not possible; a start trim on top adds up
        let trimmedTwice = map([part(0, from: 1)], existing: map([part(0, from: 2)]))
        assertMap(trimmedTwice, [segment(0, 3)], length: 19)
    }

    // MARK: What a bake writes on the row (pure)

    /// "Save to original": the offset stays, the map is written, and it is revertible.
    func testSaveToOriginalKeepsTheOffsetAndWritesTheMap() {
        let m = map([part(0, from: 2, to: 6)], isRevertible: false)
        let update = ClipBakePlan.revertibleMediaUpdate(oldOffsetSec: 10, oldDurationSec: 9,
                                                        renderedDurationSec: 4, timeMap: m)
        XCTAssertEqual(update.offsetSec, 10)
        XCTAssertEqual(update.durationSec, 4)
        XCTAssertEqual(update.timeMap?.segments, [segment(0, 2)])
        XCTAssertEqual(update.timeMap?.isRevertible, true)
        // no timing change and nothing under it: no map is stored, not an identity map
        XCTAssertNil(ClipBakePlan.revertibleMediaUpdate(oldOffsetSec: 10, oldDurationSec: 9,
                                                        renderedDurationSec: 9, timeMap: nil).timeMap)
        // a second "Save to original" on a revertible one still reverts to the recording
        let again = ClipBakePlan.revertibleMediaUpdate(oldOffsetSec: 10, oldDurationSec: 4,
                                                       renderedDurationSec: 3, timeMap: m,
                                                       existing: update.timeMap)
        XCTAssertNil(again.timeMap?.revertsTo)
    }

    /// "Replace original" moves the offset to the earliest kept footage and ALWAYS stores a
    /// not-revertible record: the identity for a plain start trim or no change, a real map for a
    /// speed change or joined parts. The offset's shift is taken out of the map, so the two never
    /// shift the same clip twice.
    func testReplaceOriginalMovesTheOffsetAndAlwaysStoresANotRevertibleRecord() {
        let plain = ClipBakePlan.replacedMediaUpdate(oldOffsetSec: 10, renderedDurationSec: 4,
                                                     timeMap: map([part(0, from: 2, to: 6)]))
        XCTAssertEqual(plain.offsetSec, 12)
        XCTAssertEqual(plain.durationSec, 4)
        XCTAssertEqual(plain.timeMap, .identity(durationSec: 4, isRevertible: false))
        XCTAssertEqual(plain.timeMap?.isIdentity, true)
        XCTAssertEqual(ClipCaptureClock(offsetSec: plain.offsetSec, timeMap: plain.timeMap)
            .captureTime(renditionTime: 1), 13, "the identity record changes no time")
        let untouched = ClipBakePlan.replacedMediaUpdate(oldOffsetSec: 10, renderedDurationSec: 9, timeMap: nil)
        XCTAssertEqual(untouched.offsetSec, 10)
        XCTAssertEqual(untouched.timeMap, .identity(durationSec: 9, isRevertible: false))
        XCTAssertEqual(ClipBakePlan.revertFinding(map: plain.timeMap), .nothingToRevert)

        let before = ClipCaptureClock(offsetSec: 10, timeMap: map([part(0, from: 2, to: 6, speed: 2)]))
        let fast = ClipBakePlan.replacedMediaUpdate(oldOffsetSec: 10, renderedDurationSec: 2,
                                                    timeMap: before.timeMap)
        XCTAssertEqual(fast.offsetSec, 12)
        XCTAssertEqual(fast.timeMap?.segments, [segment(0, 0, 2)])
        XCTAssertEqual(fast.timeMap?.isRevertible, false)
        // the same capture times as before the offset moved
        let after = ClipCaptureClock(offsetSec: fast.offsetSec, timeMap: fast.timeMap)
        for t in [0, 0.5, 1, 2] {
            XCTAssertEqual(after.captureTime(renditionTime: t), before.captureTime(renditionTime: t), accuracy: 1e-9)
        }

        let joined = ClipBakePlan.replacedMediaUpdate(
            oldOffsetSec: 10, renderedDurationSec: 6,
            timeMap: map([part(0, from: 1, to: 4), part(1, from: 6, to: 9)]))
        XCTAssertEqual(joined.offsetSec, 11)
        XCTAssertEqual(joined.timeMap?.segments, [segment(0, 0), segment(3, 5)])

        // an asset that already carries a map and is replaced with a plain trim on top
        let carried = map([part(0, from: 1)], existing: map([part(0, to: 8, speed: 2)]))
        let replaced = ClipBakePlan.replacedMediaUpdate(oldOffsetSec: 10, renderedDurationSec: 3, timeMap: carried)
        XCTAssertEqual(replaced.offsetSec, 12)
        XCTAssertEqual(replaced.timeMap?.segments, [segment(0, 0, 2)])
        XCTAssertNil(replaced.timeMap?.revertsTo, "the old asset is gone, with what it could revert to")
    }

    /// The coordinator's case: 60 s replaced at 2× (a 30 s video), then "Save to original" with
    /// 5 s trimmed off, then "Revert to Original". Photos goes back to the REPLACED video, so the
    /// row goes back to that video's record: 30 s that read 60 s of heart rate, not 30.
    func testARevertOverAReplacedClipGoesBackToTheReplacedRecord() throws {
        let replaced = try XCTUnwrap(ClipBakePlan.replacedMediaUpdate(
            oldOffsetSec: 10, renderedDurationSec: 30, timeMap: map([part(0, to: 60, speed: 2)])).timeMap)
        XCTAssertEqual(replaced.segments, [segment(0, 0, 2)])

        let part5 = part(0, from: 5)
        let composed = ClipBakePlan.timeMap(parts: [part5], sourceDurations: [part5.id: 30], transitions: [],
                                            existing: replaced)
        assertMap(composed, [segment(0, 10, 2)], length: 25)
        let saved = try XCTUnwrap(ClipBakePlan.revertibleMediaUpdate(
            oldOffsetSec: 10, oldDurationSec: 30, renderedDurationSec: 25,
            timeMap: composed, existing: replaced).timeMap)
        XCTAssertTrue(saved.isRevertible)
        XCTAssertEqual(saved.revertsTo, replaced.timing)
        XCTAssertEqual(saved.revertedMap, replaced)

        XCTAssertEqual(ClipBakePlan.revertFinding(map: saved), .backToReplaced(replaced))
        let window = ClipCaptureClock(offsetSec: 10, timeMap: saved.revertedMap)
            .captureWindow(renditionStart: 0, renditionEnd: 30)
        XCTAssertEqual(window.span, 60)

        // a second "Save to original" on top still reverts to the replaced video
        let again = try XCTUnwrap(ClipBakePlan.revertibleMediaUpdate(
            oldOffsetSec: 10, oldDurationSec: 25, renderedDurationSec: 25, timeMap: composed,
            existing: saved).timeMap)
        XCTAssertEqual(again.revertedMap, replaced)
        // a "Save to original" that changes no timing over a replaced PLAIN clip stores the
        // identity, so the row keeps saying what a revert goes back to
        let plain = BakedTimeMap.identity(durationSec: 4, isRevertible: false)
        let untimed = try XCTUnwrap(ClipBakePlan.revertibleMediaUpdate(
            oldOffsetSec: 12, oldDurationSec: 4, renderedDurationSec: 4, timeMap: nil, existing: plain).timeMap)
        XCTAssertTrue(untimed.isIdentity)
        XCTAssertEqual(ClipBakePlan.revertFinding(map: untimed), .backToReplaced(plain))
    }

    /// What "no edited rendition" means for a baked row is read from its record.
    func testWhatAFoundRevertMeansIsReadFromTheRecord() {
        XCTAssertEqual(ClipBakePlan.revertFinding(map: map([part(0, from: 2)])), .backToRecording)
        // no record: a "Save to original" with no timing change, or a clip baked before prompt 305
        XCTAssertEqual(ClipBakePlan.revertFinding(map: nil), .backToRecording)
        XCTAssertEqual(ClipBakePlan.revertFinding(map: map([part(0, from: 2)], isRevertible: false)),
                       .nothingToRevert)
    }

    func testTheMapIsStoredAsJSONAndAnUnreadableValueIsNoMap() throws {
        let m = try XCTUnwrap(map([part(0, to: 3), part(1, from: 5, to: 8, speed: 2)]))
        XCTAssertEqual(BakedTimeMap.decode(m.encoded), m)
        XCTAssertNil(BakedTimeMap.decode(nil))
        XCTAssertNil(BakedTimeMap.decode(Data("not json".utf8)))
        let empty = BakedTimeMap(segments: [], renditionDurationSec: 0)
        XCTAssertNil(BakedTimeMap.decode(empty.encoded), "a map with no segments says nothing")
        // a value stored without `revertsTo` (the key is optional) still decodes
        let bare = Data(#"{"segments":[{"renditionStartSec":0,"sourceStartSec":2,"speed":1}],"renditionDurationSec":4,"isRevertible":true}"#.utf8)
        XCTAssertEqual(BakedTimeMap.decode(bare),
                       BakedTimeMap(segments: [segment(0, 2)], renditionDurationSec: 4, isRevertible: true))
        var withBase = m
        withBase.revertsTo = BakedTimeMap.identity(durationSec: 9, isRevertible: false).timing
        XCTAssertEqual(BakedTimeMap.decode(withBase.encoded), withBase)

        let media = SessionMedia(sessionID: UUID(), localIdentifier: "A", kind: .video, offsetSec: 10)
        XCTAssertNil(media.bakeTimeMapData)
        XCTAssertEqual(media.captureClock, ClipCaptureClock(offsetSec: 10))
        XCTAssertEqual(media.reelStartSec, 10)
        media.bakeTimeMap = map([part(0, from: 2)])
        XCTAssertNotNil(media.bakeTimeMapData)
        XCTAssertEqual(media.captureClock.captureTime(renditionTime: 1), 13)
        XCTAssertEqual(media.reelStartSec, 12, "the reel maker is told when the first baked frame was filmed")
        XCTAssertEqual(KilterWorkoutBuilder.Clip.from(media).offsetSec, 12)
        media.bakeTimeMap = nil
        XCTAssertNil(media.bakeTimeMapData)
    }

    // MARK: Every reader goes through the one rule

    /// A clip with no map: the clock is the offset, and every reader gives what it gave before.
    func testWithoutAMapNothingChanges() {
        let clock = ClipCaptureClock(offsetSec: 10)
        XCTAssertEqual(clock.captureTime(renditionTime: 3), 13)
        let window = clock.captureWindow(renditionStart: 2, renditionEnd: 6)
        XCTAssertEqual(window.start, 12)
        XCTAssertEqual(window.span, 4)
        let studio = StudioHRPlacement.captureWindow(offset: 10, trimStart: 2, trimEnd: 6, sourceDuration: 9)
        XCTAssertEqual(studio.start, 12)
        XCTAssertEqual(studio.span, 4)
        XCTAssertEqual(FeedMedia.clipHRWindow(offsetSec: 10, durationSec: 4, hrSeries: ramp).first?.bpm, 110)
    }

    /// The Studio's window builder (preview tile, HR-window sliders, export) with a map.
    func testTheStudioWindowReadsThroughTheMap() {
        let m = map([part(0, from: 2, to: 6)])
        // the baked clip, untrimmed in the project: 4 s that were filmed at 12…16
        let whole = StudioHRPlacement.captureWindow(offset: 10, trimStart: 0, trimEnd: nil,
                                                    sourceDuration: 4, timeMap: m)
        XCTAssertEqual(whole.start, 12)
        XCTAssertEqual(whole.span, 4)
        // trimmed again in the project, not baked: 1…3 of the baked video is 13…15
        let trimmed = StudioHRPlacement.captureWindow(offset: 10, trimStart: 1, trimEnd: 3,
                                                      sourceDuration: 4, timeMap: m)
        XCTAssertEqual(trimmed.start, 13)
        XCTAssertEqual(trimmed.span, 2)
        // the lead-in is measured back from the mapped start
        let ext = StudioHRPlacement.extendedWindow(offset: 10, trimStart: 0, trimEnd: nil, sourceDuration: 4,
                                                   leadSec: 5, tailSec: 30, timeMap: m)
        XCTAssertEqual(ext.start, 7)
        XCTAssertEqual(ext.window.footageSec, 4)
        // a baked 2× clip of 2 s reads 4 s of heart rate
        let fast = StudioHRPlacement.captureWindow(offset: 10, trimStart: 0, trimEnd: nil, sourceDuration: 2,
                                                   timeMap: map([part(0, from: 2, to: 6, speed: 2)]))
        XCTAssertEqual(fast.start, 12)
        XCTAssertEqual(fast.span, 4)

        let clip = part(0)
        let sampled = StudioHRPlacement.sample(clips: [clip], offsets: [clip.id: 10],
                                               sourceDurations: [clip.id: 4], series: ramp,
                                               timeMaps: m.map { [clip.id: $0] } ?? [:])
        XCTAssertEqual(sampled[clip.id]?.first?.bpm, 112)
        XCTAssertEqual(sampled[clip.id]?.last?.bpm, 116)
        let unmapped = StudioHRPlacement.sample(clips: [clip], offsets: [clip.id: 10],
                                                sourceDurations: [clip.id: 4], series: ramp)
        XCTAssertEqual(unmapped[clip.id]?.first?.bpm, 110)
    }

    /// The offset and the map of a clip come from ONE row, by the media link and then by the
    /// Photos identifier.
    func testAClipsClockIsResolvedLikeItsOffset() {
        let mediaID = UUID()
        let m = map([part(0, from: 2)])
        let linked = TimelineClip(sessionMediaID: mediaID, localIdentifier: "A", isPhoto: false, order: 0)
        let unlinked = TimelineClip(sessionMediaID: UUID(), localIdentifier: "A", isPhoto: false, order: 1)
        let unknown = TimelineClip(sessionMediaID: nil, localIdentifier: "Z", isPhoto: false, order: 2)
        let byMedia = [mediaID: ClipCaptureClock(offsetSec: 10, timeMap: m)]
        let byLocal = ["A": ClipCaptureClock(offsetSec: 30)]
        XCTAssertEqual(StudioHRPlacement.resolveClock(of: linked, byMediaID: byMedia, byLocalID: byLocal)?.timeMap, m)
        XCTAssertEqual(StudioHRPlacement.resolveClock(of: unlinked, byMediaID: byMedia, byLocalID: byLocal),
                       ClipCaptureClock(offsetSec: 30))
        XCTAssertNil(StudioHRPlacement.resolveClock(of: unknown, byMediaID: byMedia, byLocalID: byLocal))
    }

    /// The poster's peak / average chip and the activity pages' average.
    func testThePosterChipAndTheActivityAverageReadThroughTheMap() {
        let m = map([part(0, from: 2, to: 6)])
        let chip = FeedMedia.clipHR(offsetSec: 10, durationSec: 4, hrSeries: ramp, maxHR: 190, timeMap: m)
        XCTAssertEqual(chip.peakBpm, 116)
        XCTAssertEqual(chip.avgBpm, 114)
        XCTAssertEqual(FeedMedia.clipHR(offsetSec: 10, durationSec: 4, hrSeries: ramp, maxHR: 190).peakBpm, 114)

        var input = ActivityMediaInput(id: UUID(), sessionID: UUID(), assignedExerciseID: nil,
                                       assignedSetIndex: nil, kindRaw: "video", offsetSec: 10,
                                       durationSec: 4, localIdentifier: "A")
        XCTAssertEqual(ActivityMediaIndex.averageBPM(for: input, hrSeries: ramp), 112)
        input.timeMap = m
        XCTAssertEqual(ActivityMediaIndex.averageBPM(for: input, hrSeries: ramp), 114)
        XCTAssertEqual(input.mediaInput.timeMap, m, "the viewer's value carries the map on")
    }

    /// The feed draws NO live overlay on a baked clip (prompt 117), so it needs no map there, and
    /// "Share with heart rate" shares it raw. Pinned: a map does not change that. A row that
    /// carries a map without the flag is drawn, and reads through the map.
    func testTheFeedIgnoresABakedClipAndReadsTheMapOtherwise() throws {
        let m = map([part(0, from: 2, to: 6)])
        let media = SessionMedia(sessionID: UUID(), localIdentifier: "A", kind: .video,
                                 offsetSec: 10, durationSec: 4)
        media.bakeTimeMap = m
        media.isBaked = true
        let baked = MediaInput.from(media)
        XCTAssertEqual(baked.timeMap, m)
        XCTAssertEqual(baked.captureClock.captureStartSec, 12)
        XCTAssertNil(ClipHROverlay.make(clip: baked, hrSeries: ramp, maxHR: 190, restHR: 60))
        XCTAssertEqual(ClipSharePlan.offer(for: baked, payload: nil), .raw)

        media.isBaked = false
        var notBaked = MediaInput.from(media)
        notBaked.edit = ClipStudioEdit(hrLeadSec: 0, hrTailSec: 0)
        let payload = try XCTUnwrap(ClipHROverlay.make(clip: notBaked, hrSeries: ramp, maxHR: 190, restHR: 60))
        XCTAssertEqual(payload.values.samples.first?.bpm, 112)
        XCTAssertEqual(payload.values.samples.last?.bpm, 116)
        notBaked.timeMap = nil
        let plain = try XCTUnwrap(ClipHROverlay.make(clip: notBaked, hrSeries: ramp, maxHR: 190, restHR: 60))
        XCTAssertEqual(plain.values.samples.first?.bpm, 110)
    }

    /// The festival set screen lists a tagged row with its flag and its map: the viewer stands
    /// down on a baked clip, and the set reel is told when the first baked frame was filmed.
    @MainActor
    func testTheFestivalSetScreenCarriesTheFlagAndTheMap() {
        let media = SessionMedia(sessionID: UUID(), localIdentifier: "A", kind: .video,
                                 offsetSec: 10, durationSec: 4)
        media.bakeTimeMap = map([part(0, from: 2, to: 6)])
        media.isBaked = true
        let row = FestivalSetDetailView.ClipRow(media, isAuto: true)
        XCTAssertTrue(row.mediaInput.isBaked)
        XCTAssertEqual(row.mediaInput.timeMap, media.bakeTimeMap)
        XCTAssertEqual(row.mediaInput, { var m = MediaInput.from(media); m.aspect = row.aspect; return m }())
        XCTAssertNil(ClipHROverlay.make(clip: row.mediaInput, hrSeries: ramp, maxHR: 190, restHR: 60))
        XCTAssertEqual(row.reelClip.offsetSec, 12)
        XCTAssertEqual(row.reelClip.durationSec, 4)

        let plain = FestivalSetDetailView.ClipRow(mediaID: UUID(), sessionID: UUID(), localIdentifier: "B",
                                                  isVideo: true, offsetSec: 30, durationSec: 5,
                                                  aspect: nil, isAuto: false)
        XCTAssertFalse(plain.mediaInput.isBaked)
        XCTAssertEqual(plain.reelClip.offsetSec, 30)

        // what the screen hands the viewer and the set reel (`openViewer`, `reelSource`)
        let viewer = FestivalSetDetailView.viewerInputs([row, plain])
        XCTAssertEqual(viewer.map(\.isBaked), [true, false])
        XCTAssertEqual(viewer.map(\.timeMap), [media.bakeTimeMap, nil])
        XCTAssertEqual(viewer.map(\.captureClock.captureStartSec), [12, 30])
        let reel = FestivalSetDetailView.reelClips([row, plain], sessionID: media.sessionID)
        XCTAssertEqual(reel.map(\.offsetSec), [12], "the set's own session, from the first filmed frame")
    }

    /// A bake with no video part leaves the row's map as it is, and an identity record is not a
    /// map: it is dropped, so the caller stores what its own rule says.
    func testAMapWithNoPartsDropsAnIdentityRecord() throws {
        let identity = BakedTimeMap.identity(durationSec: 4, isRevertible: false)
        XCTAssertNil(ClipBakePlan.timeMap(parts: [], sourceDurations: [:], transitions: [],
                                          existing: identity))
        XCTAssertNil(ClipBakePlan.timeMap(parts: [], sourceDurations: [:], transitions: [],
                                          existing: nil))
        let trimmed = try XCTUnwrap(map([part(0, from: 2, to: 6)]))
        let kept = ClipBakePlan.timeMap(parts: [], sourceDurations: [:], transitions: [],
                                        existing: trimmed, isRevertible: false)
        XCTAssertEqual(kept?.segments, trimmed.segments)
        XCTAssertEqual(kept?.renditionDurationSec, trimmed.renditionDurationSec)
        XCTAssertEqual(kept?.isRevertible, false)
    }

    // MARK: View model (in-memory store, stand-in baker)

    private final class Availability: StudioMediaAvailabilityChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var cloudOnly: Set<String> = []
        /// These videos are in iCloud only from now on.
        func setInCloud(_ identifiers: Set<String>) {
            lock.withLock { cloudOnly = identifiers }
        }
        func statuses(for localIdentifiers: [String]) async -> [String: StudioAssetStatus] {
            let cloud = lock.withLock { cloudOnly }
            return Dictionary(uniqueKeysWithValues: localIdentifiers.map {
                ($0, cloud.contains($0) ? StudioAssetStatus.inCloud : .available)
            })
        }
        func download(localIdentifier: String,
                      progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {}
    }

    @MainActor
    private final class FakeBaker: ClipBaking {
        var saved: [String] = []
        func saveToOriginal(renderedURL: URL, localIdentifier: String, projectID: UUID) async throws {
            saved.append(localIdentifier)
        }
        func replaceOriginal(renderedURL: URL, oldLocalIdentifier: String) async throws -> String { "NEW" }
    }

    @MainActor
    private final class Lengths {
        var byAsset: [String: Double]
        /// Every asset whose length was read, in order.
        var asked: [String] = []
        init(_ byAsset: [String: Double]) { self.byAsset = byAsset }
    }

    /// The stand-in for Photos' answer about a baked asset. A test can change the answer, count
    /// the questions, and hold a question until it lets it go (the probe runs off the main actor).
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var answer: BakedAssetProbe
        private var held: Bool
        private var count = 0
        private var waiting = 0
        private var active = 0
        private var mostActive = 0
        init(_ answer: BakedAssetProbe, held: Bool = false) {
            self.answer = answer
            self.held = held
        }
        var calls: Int { lock.withLock { count } }
        /// The most questions that were open at the same time.
        var mostAtOnce: Int { lock.withLock { mostActive } }
        func set(_ answer: BakedAssetProbe) { lock.withLock { self.answer = answer } }
        /// Hold the next questions until `release()`.
        func hold() { lock.withLock { held = true } }
        /// Let every held question go; later ones are not held.
        func release() {
            let n: Int = lock.withLock {
                held = false
                defer { waiting = 0 }
                return waiting
            }
            for _ in 0..<n { gate.signal() }
        }
        /// The answer is the one Photos has when it is ASKED, also if the question is held.
        func ask(_ localIdentifier: String) -> BakedAssetProbe {
            let (said, wait): (BakedAssetProbe, Bool) = lock.withLock {
                count += 1
                active += 1
                mostActive = max(mostActive, active)
                if held { waiting += 1 }
                return (answer, held)
            }
            if wait { gate.wait() }
            lock.withLock { active -= 1 }
            return said
        }
    }

    /// Counts the renders.
    @MainActor
    private final class Renders {
        var count = 0
    }

    /// A render a test can hold open.
    @MainActor
    private final class RenderGate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func passed() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private static let stillBaked = BakedAssetProbe(hasEditedRendition: true, currentDuration: nil)
    /// What the app's own probe answers for an asset Photos does not have (every asset in these
    /// tests): nothing is known, so nothing is cleared.
    private static let unknownAsset = BakedAssetProbe(hasEditedRendition: nil, currentDuration: nil)

    /// Wait (without a fixed sleep) until the view model has got somewhere.
    @MainActor
    private func wait(for what: String, file: StaticString = #filePath, line: UInt = #line,
                      until done: () -> Bool) async {
        for _ in 0..<1000 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(done(), what, file: file, line: line)
    }

    private struct SaveRefused: Error {}

    /// A real, very small H.264 video (the stand-in for a bake's render).
    private func shortVideo(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio305-render-\(UUID().uuidString).mp4")
        let side = 32, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        var index = 0
        while index < frames {
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { usleep(1_000); continue }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try XCTUnwrap(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * side)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
            index += 1
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    @MainActor
    private struct Fixture {
        let vm: StudioEditorViewModel
        let project: StudioProject
        let clip: TimelineClip
        let media: SessionMedia
        let lengths: Lengths
        let availability: Availability
        let container: ModelContainer
    }

    /// A finished session with the ramp as its heart rate, and one video "A" of 9 s filmed 10 s
    /// into it. The project's one clip keeps 2…6 of it (`speed` 1 unless given). The stand-in
    /// render is a real 1 s video; the stand-in length reader says what `lengths` holds.
    ///
    /// `scoped`: the session has a second video "B" and the Studio is opened on "A" only ("Edit
    /// this clip"), so a bake keeps the project-wide items and records them on the clip.
    @MainActor
    private func makeFixture(speed: Double = 1, assetLength: Double = 9, trimStart: Double = 2,
                             trimEnd: Double? = 6, scoped: Bool = false) throws -> Fixture {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let session = WorkoutSession(routineName: "Bake", startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                     completedAt: Date(timeIntervalSinceReferenceDate: 800_000_120),
                                     hrSeries: ramp, maxHR: 190, restHR: 60)
        let project = StudioProject(sessionID: session.id, title: "Bake")
        let media = SessionMedia(sessionID: session.id, localIdentifier: "A", kind: .video,
                                 offsetSec: 10, durationSec: assetLength)
        let clip = TimelineClip(sessionMediaID: media.id, localIdentifier: "A", isPhoto: false,
                                order: 0, trimStart: trimStart, trimEnd: trimEnd, speed: speed)
        project.clips = [clip]
        container.mainContext.insert(session)
        container.mainContext.insert(project)
        container.mainContext.insert(media)
        if scoped {
            let other = SessionMedia(sessionID: session.id, localIdentifier: "B", kind: .video,
                                     offsetSec: 40, durationSec: 5)
            container.mainContext.insert(other)
            project.clips = [clip, TimelineClip(sessionMediaID: other.id, localIdentifier: "B",
                                                isPhoto: false, order: 1)]
        }
        try container.mainContext.save()
        let lengths = Lengths(["A": assetLength, "B": 5])
        let availability = Availability()
        let vm = try makeViewModel(project, container, lengths, visible: scoped ? [media.id] : nil,
                                   availability: availability)
        return Fixture(vm: vm, project: project, clip: clip, media: media, lengths: lengths,
                       availability: availability, container: container)
    }

    @MainActor
    private func makeViewModel(_ project: StudioProject, _ container: ModelContainer,
                               _ lengths: Lengths, visible: Set<UUID>? = nil,
                               availability: Availability = Availability()) throws -> StudioEditorViewModel {
        let vm = StudioEditorViewModel(project: project, context: container.mainContext,
                                       visibleClipMediaIDs: visible, availability: availability)
        // No test asks Photos. Until a test says otherwise the answer is the one the app's own
        // probe gives for these made-up assets: Photos does not know them.
        vm.bakedAssetProbe = { _ in Self.unknownAsset }
        vm.sourceDurationLoader = {
            lengths.asked.append($0)
            return lengths.byAsset[$0]
        }
        let rendered = try shortVideo(seconds: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: rendered) }
        vm.renderOverride = {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("studio305-bake-\(UUID().uuidString).mp4")
            try FileManager.default.copyItem(at: rendered, to: url)
            return url
        }
        return vm
    }

    /// The tiles the export hands the overlay tool, built as the export builds them: the view
    /// model's per-clip heart rate placed on the render plan's clips.
    @MainActor
    private func exportedTiles(_ vm: StudioEditorViewModel) -> [PlacedClipHR] {
        let canvas = CGSize(width: 90, height: 160)
        let plan = StudioRenderPlan.make(
            clips: vm.clips, sourceDurations: vm.sourceDurations,
            orientedSizes: Dictionary(uniqueKeysWithValues: vm.clips.map { ($0.id, canvas) }),
            canvas: canvas)
        return StudioComposer.placedHR(clips: plan.clips, clipHRByID: vm.clipHRContent())
    }

    /// Turn the HR tile on with no lead-in and no tail, so the first sample IS the clip's first
    /// frame and the last sample its last.
    @MainActor
    private func addTileWithoutLeadOrTail(_ vm: StudioEditorViewModel) throws {
        vm.toggleHROverlay()
        let id = try XCTUnwrap(vm.clips.first?.id)
        vm.setHRWindowLead(0, clipID: id)
        vm.setHRWindowTail(0, clipID: id)
    }

    /// The user's case. A clip trimmed to 2…6 is saved to the original; afterwards an HR tile is
    /// added in the Studio. The tile reads heart rate from capture offset + 2 s, in the export
    /// and in the preview. The row's offset has not moved. After "Revert to Original" the map is
    /// gone and the tile reads from the original's start again.
    @MainActor
    func testAnHRTileAddedAfterSaveToOriginalReadsFromWhereTheKeptFootageStarted() async throws {
        let f = try makeFixture()
        defer { withExtendedLifetime(f.container) {} }
        await f.vm.onAppear()
        XCTAssertEqual(f.vm.totalDuration, 4)

        // Photos reports 4 s for the baked video (2…6 of the original).
        f.lengths.byAsset["A"] = 4
        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        XCTAssertEqual(baker.saved, ["A"])
        await f.vm.previewBuildsFinished()

        XCTAssertTrue(f.media.isBaked)
        XCTAssertEqual(f.media.offsetSec, 10, "the capture offset does not move")
        XCTAssertEqual(f.media.bakeTimeMap,
                       BakedTimeMap(segments: [segment(0, 2)], renditionDurationSec: 4, isRevertible: true))
        XCTAssertEqual(f.vm.clips.first?.trimStart, 0)          // the trim is in the pixels
        XCTAssertEqual(f.vm.totalDuration, 4)

        try addTileWithoutLeadOrTail(f.vm)

        // the export: one tile over the clip's 4 s, sampled from 12…16 of the session
        let tiles = exportedTiles(f.vm)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles.first?.startSec, 0)
        XCTAssertEqual(tiles.first?.durationSec, 4)
        XCTAssertEqual(tiles.first?.samples.first?.bpm, 112)
        XCTAssertEqual(tiles.first?.samples.last?.bpm, 116)
        XCTAssertNotNil(tiles.first?.tile)

        // the preview tile shows the same seconds
        XCTAssertEqual(f.vm.previewHR.samples.first?.bpm, 112)
        XCTAssertEqual(f.vm.previewHR.samples.last?.bpm, 116)
        let shown = f.vm.previewTile.values
        XCTAssertEqual(shown.samples.first?.bpm, 112)
        XCTAssertEqual(shown.samples.map(\.bpm).max(), 116)
        XCTAssertEqual(f.vm.previewHR.samples, tiles.first?.samples, "preview and export agree")

        // the HR-window sliders: 4 s of footage, and a lead-in that reaches back from second 12
        XCTAssertEqual(f.vm.hrWindowInfo?.footageSec, 4)
        f.vm.setHRWindowLead(15, clipID: try XCTUnwrap(f.vm.clips.first?.id))
        XCTAssertEqual(f.vm.hrWindowInfo?.effectiveLead, 12, "the lead-in stops at the session's start")
        XCTAssertEqual(f.vm.previewHR.samples.first?.bpm, 100)
        f.vm.setHRWindowLead(0, clipID: try XCTUnwrap(f.vm.clips.first?.id))

        // the map is in the store, with the flag
        let stored = try XCTUnwrap(ModelContext(f.container).fetch(FetchDescriptor<SessionMedia>()).first)
        XCTAssertEqual(stored.isBakedRaw, true)
        XCTAssertEqual(stored.bakeTimeMap?.segments, [segment(0, 2)])

        // "Revert to Original" in Photos; the Studio is opened again
        f.lengths.byAsset["A"] = 9
        let reopened = try makeViewModel(f.project, f.container, f.lengths)
        reopened.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: false, currentDuration: 9) }
        await reopened.onAppear()
        _ = await reopened.reconcileBakedFlags()?.value
        await reopened.previewBuildsFinished()

        XCTAssertFalse(f.media.isBaked)
        XCTAssertNil(f.media.bakeTimeMap, "the map goes with the flag")
        XCTAssertNil(f.media.bakeTimeMapData)
        XCTAssertEqual(f.media.durationSec, 9)
        XCTAssertEqual(f.media.offsetSec, 10)
        XCTAssertEqual(reopened.previewHR.samples.first?.bpm, 110, "the original's start again")
        XCTAssertEqual(reopened.previewHR.samples.last?.bpm, 119)
        XCTAssertEqual(exportedTiles(reopened).first?.samples.first?.bpm, 110)
        let afterRevert = try XCTUnwrap(ModelContext(f.container).fetch(FetchDescriptor<SessionMedia>()).first)
        XCTAssertNil(afterRevert.bakeTimeMapData)
        XCTAssertNotEqual(afterRevert.isBakedRaw, true)
    }

    /// A probe that still finds the edited video, or finds no asset, clears nothing.
    @MainActor
    func testTheMapStaysWhileTheBakedVideoIsStillThere() async throws {
        for answer in [true, nil] as [Bool?] {
            let f = try makeFixture()
            defer { withExtendedLifetime(f.container) {} }
            await f.vm.onAppear()
            await f.vm.bake(replaceOriginal: false, service: FakeBaker())
            await f.vm.previewBuildsFinished()
            f.vm.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: answer, currentDuration: 9) }
            _ = await f.vm.reconcileBakedFlags()?.value
            XCTAssertTrue(f.media.isBaked)
            XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 2)])
        }
    }

    /// A baked speed change: 4 s of the recording play in 2 s, and the tile reads all 4.
    @MainActor
    func testABakedSpeedChangeReadsTheWholeFilmedStretch() async throws {
        let f = try makeFixture(speed: 2)
        defer { withExtendedLifetime(f.container) {} }
        await f.vm.onAppear()
        XCTAssertEqual(f.vm.totalDuration, 2)
        f.lengths.byAsset["A"] = 2
        await f.vm.bake(replaceOriginal: false, service: FakeBaker())
        await f.vm.previewBuildsFinished()
        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 2, 2)])
        XCTAssertEqual(f.media.offsetSec, 10)

        try addTileWithoutLeadOrTail(f.vm)
        let tile = try XCTUnwrap(exportedTiles(f.vm).first)
        XCTAssertEqual(tile.durationSec, 2)
        XCTAssertEqual(tile.samples.first?.bpm, 112)
        XCTAssertEqual(tile.samples.last?.bpm, 116)
        XCTAssertEqual(f.vm.previewHR.samples.last?.bpm, 116)
    }

    /// "Replace original": the offset moves and the row gets a not-revertible record, the
    /// identity for a plain trim and a real map for a speed change. The tile reads the same
    /// seconds either way.
    @MainActor
    func testReplaceOriginalMovesTheOffsetAndStoresItsRecord() async throws {
        let plain = try makeFixture()
        defer { withExtendedLifetime(plain.container) {} }
        await plain.vm.onAppear()
        plain.lengths.byAsset["NEW"] = 4
        await plain.vm.bake(replaceOriginal: true, service: FakeBaker())
        await plain.vm.previewBuildsFinished()
        XCTAssertEqual(plain.media.offsetSec, 12)
        XCTAssertEqual(plain.media.bakeTimeMap?.isIdentity, true)
        XCTAssertEqual(plain.media.bakeTimeMap?.isRevertible, false)
        try addTileWithoutLeadOrTail(plain.vm)
        XCTAssertEqual(exportedTiles(plain.vm).first?.samples.first?.bpm, 112)

        let fast = try makeFixture(speed: 2)
        defer { withExtendedLifetime(fast.container) {} }
        await fast.vm.onAppear()
        fast.lengths.byAsset["NEW"] = 2
        await fast.vm.bake(replaceOriginal: true, service: FakeBaker())
        await fast.vm.previewBuildsFinished()
        XCTAssertEqual(fast.media.offsetSec, 12)
        XCTAssertEqual(fast.media.bakeTimeMap,
                       BakedTimeMap(segments: [segment(0, 0, 2)], renditionDurationSec: 2, isRevertible: false))
        try addTileWithoutLeadOrTail(fast.vm)
        let tile = try XCTUnwrap(exportedTiles(fast.vm).first)
        XCTAssertEqual(tile.samples.first?.bpm, 112)
        XCTAssertEqual(tile.samples.last?.bpm, 116)
    }

    /// The bug the review confirmed. A replaced asset has no edited rendition, which is what a
    /// revert looks like. With its record the clip STAYS baked when the Studio asks Photos again:
    /// the flag, the clip's `baked` record (the HR tile is in its pixels), the record itself, the
    /// offset and the length are all as the bake left them, so the feed draws no live overlay,
    /// "Share with heart rate" stays raw and the Studio draws no second tile. Plain trim and 2×.
    @MainActor
    func testAReplacedClipStaysBakedWhenTheStudioAsksPhotosAgain() async throws {
        for speed in [1.0, 2.0] {
            let f = try makeFixture(speed: speed, scoped: true)
            defer { withExtendedLifetime(f.container) {} }
            await f.vm.onAppear()
            f.vm.toggleHROverlay()                      // a project-wide tile, burned by the bake
            f.lengths.byAsset["NEW"] = 4 / speed
            await f.vm.bake(replaceOriginal: true, service: FakeBaker())
            XCTAssertEqual(f.vm.bakeState, .saved(replaced: true))
            await f.vm.previewBuildsFinished()
            XCTAssertTrue(f.media.isBaked)
            XCTAssertEqual(f.vm.clips.first?.baked?.hrTile, true)
            XCTAssertNotNil(f.vm.hrTile, "the other clip still uses the tile")
            XCTAssertNil(f.vm.canvasHRTile)
            let record = try XCTUnwrap(f.media.bakeTimeMap)
            XCTAssertFalse(record.isRevertible)
            XCTAssertEqual(record.isIdentity, speed == 1)
            let length = f.media.durationSec

            // the Studio is opened again; Photos reports no edited rendition for the new asset
            let reopened = try makeViewModel(f.project, f.container, f.lengths, visible: [f.media.id])
            reopened.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: false, currentDuration: 77) }
            await reopened.onAppear()
            _ = await reopened.reconcileBakedFlags()?.value
            await reopened.previewBuildsFinished()

            XCTAssertTrue(f.media.isBaked, "a replaced clip is not a reverted clip")
            XCTAssertEqual(f.media.bakeTimeMap, record)
            XCTAssertEqual(f.media.offsetSec, 12)
            XCTAssertEqual(f.media.durationSec, length, "nothing was reverted: the length stays too")
            XCTAssertEqual(reopened.clips.first?.baked?.hrTile, true, "the clip's baked record stays")
            XCTAssertNil(reopened.canvasHRTile, "no second tile in the Studio")
            XCTAssertTrue(reopened.clipHRContent().isEmpty, "and none in an export")
            let input = MediaInput.from(f.media)
            XCTAssertNil(ClipHROverlay.make(clip: input, hrSeries: ramp, maxHR: 190, restHR: 60))
            XCTAssertEqual(ClipSharePlan.offer(for: input, payload: nil), .raw)
            let stored = try XCTUnwrap(ModelContext(f.container).fetch(
                FetchDescriptor<SessionMedia>()).first { $0.localIdentifier == "NEW" })
            XCTAssertEqual(stored.isBakedRaw, true)
        }
    }

    /// A clip replaced BEFORE prompt 305 has the flag and no record. Nothing tells it from a
    /// reverted "Save to original", so it is still un-flagged at the next check, as before.
    @MainActor
    func testAClipReplacedBeforeTheRecordExistedIsStillReadAsReverted() async throws {
        let f = try makeFixture()
        defer { withExtendedLifetime(f.container) {} }
        f.media.isBaked = true                          // as an older build left it
        try f.container.mainContext.save()
        await f.vm.onAppear()
        f.vm.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: false, currentDuration: 9) }
        _ = await f.vm.reconcileBakedFlags()?.value
        XCTAssertFalse(f.media.isBaked)
        XCTAssertNil(f.media.bakeTimeMapData)
    }

    /// "Save to original" over a replaced 2× clip, then "Revert to Original": the asset plays
    /// the replaced video again, so the row is still baked and has that video's record back.
    @MainActor
    func testARevertOverAReplacedClipRestoresItsRecordInTheStudio() async throws {
        let f = try makeFixture(speed: 2)
        defer { withExtendedLifetime(f.container) {} }
        await f.vm.onAppear()
        f.lengths.byAsset["NEW"] = 2
        await f.vm.bake(replaceOriginal: true, service: FakeBaker())
        await f.vm.previewBuildsFinished()
        let replaced = try XCTUnwrap(f.media.bakeTimeMap)
        XCTAssertEqual(replaced.segments, [segment(0, 0, 2)])

        // trim 0.5 s off the replaced video and save it to the original
        f.vm.acknowledgeBake()
        f.vm.select(try XCTUnwrap(f.vm.clips.first?.id))
        f.vm.trimSelected(startSeconds: 0.5, endSeconds: nil)
        await f.vm.previewBuildsFinished()
        f.lengths.byAsset["NEW"] = 1.5
        await f.vm.bake(replaceOriginal: false, service: FakeBaker())
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        await f.vm.previewBuildsFinished()
        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 1, 2)])
        XCTAssertEqual(f.media.bakeTimeMap?.isRevertible, true)
        XCTAssertEqual(f.media.bakeTimeMap?.revertsTo, replaced.timing)
        XCTAssertEqual(f.media.offsetSec, 12)

        // "Revert to Original" in Photos: the 2 s replaced video is back
        f.lengths.byAsset["NEW"] = 2
        f.vm.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: false, currentDuration: 2) }
        _ = await f.vm.reconcileBakedFlags()?.value
        await f.vm.previewBuildsFinished()
        XCTAssertTrue(f.media.isBaked)
        XCTAssertEqual(f.media.bakeTimeMap, replaced)
        XCTAssertEqual(f.media.durationSec, 2)
        XCTAssertEqual(f.vm.totalDuration, 2, "the clip's length was read again")
        try addTileWithoutLeadOrTail(f.vm)
        let tile = try XCTUnwrap(exportedTiles(f.vm).first)
        XCTAssertEqual(tile.samples.first?.bpm, 112)
        XCTAssertEqual(tile.samples.last?.bpm, 116, "2 s of 2× video read 4 s of heart rate again")
    }

    /// A bake asks Photos again before it trusts the row's map. Bake a 20 s start trim; the user
    /// reverts in Photos WITHOUT reopening the Studio; trim 5 s and tap save. The first tap
    /// STOPS: the trim was set against the baked video, which is gone. It clears the stale map.
    /// The next save stores source start 5, not 25.
    @MainActor
    func testABakeAsksPhotosBeforeItComposesTheRowsMap() async throws {
        let f = try makeFixture(assetLength: 60, trimStart: 20, trimEnd: nil)
        defer { withExtendedLifetime(f.container) {} }
        let baker = FakeBaker()
        await f.vm.onAppear()
        f.lengths.byAsset["A"] = 40
        await f.vm.bake(replaceOriginal: false, service: baker)
        await f.vm.previewBuildsFinished()
        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 20)])
        XCTAssertEqual(f.vm.totalDuration, 40)
        XCTAssertEqual(baker.saved, ["A"])

        // reverted in Photos; the Studio stays open
        f.lengths.byAsset["A"] = 60
        f.vm.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: false, currentDuration: 60) }
        f.vm.acknowledgeBake()
        f.vm.select(try XCTUnwrap(f.vm.clips.first?.id))
        f.vm.trimSelected(startSeconds: 5, endSeconds: nil)
        await f.vm.previewBuildsFinished()
        await f.vm.bake(replaceOriginal: false, service: baker)

        // the first tap stops with the message, and nothing was written to Photos
        XCTAssertEqual(f.vm.bakeState, .failed("This clip was reverted in Photos. Check it and save again."))
        XCTAssertEqual(baker.saved, ["A"], "no second write")
        XCTAssertFalse(f.vm.isRendering)
        XCTAssertFalse(f.vm.state.isChecking)
        XCTAssertTrue(f.vm.canEdit)
        XCTAssertTrue(f.vm.state.canClose)
        XCTAssertFalse(f.media.isBaked)
        XCTAssertNil(f.media.bakeTimeMapData, "the stale map is gone")
        XCTAssertEqual(f.media.durationSec, 60)
        XCTAssertEqual(f.vm.totalDuration, 55, "the reverted video's length was read again")

        // the user looks at it and saves again: no baked row is left, so nothing is asked
        f.vm.acknowledgeBake()
        XCTAssertEqual(f.vm.bakeState, .idle)
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        await f.vm.previewBuildsFinished()
        XCTAssertEqual(baker.saved, ["A", "A"])

        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 5)])
        XCTAssertEqual(f.media.bakeTimeMap?.renditionDurationSec ?? -1, 55, accuracy: 1e-6,
                       "the bake was laid out with the reverted video's length, read again")
        XCTAssertNil(f.media.bakeTimeMap?.revertsTo)
        XCTAssertTrue(f.media.isBaked)
        XCTAssertEqual(f.media.offsetSec, 10)

        // the same second bake with the first still in place composes: 20 + 5
        let g = try makeFixture(assetLength: 60, trimStart: 20, trimEnd: nil)
        defer { withExtendedLifetime(g.container) {} }
        await g.vm.onAppear()
        g.lengths.byAsset["A"] = 40
        await g.vm.bake(replaceOriginal: false, service: FakeBaker())
        await g.vm.previewBuildsFinished()
        g.vm.acknowledgeBake()
        g.vm.select(try XCTUnwrap(g.vm.clips.first?.id))
        g.vm.trimSelected(startSeconds: 5, endSeconds: nil)
        await g.vm.previewBuildsFinished()
        await g.vm.bake(replaceOriginal: false, service: FakeBaker())
        await g.vm.previewBuildsFinished()
        XCTAssertEqual(g.media.bakeTimeMap?.segments, [segment(0, 25)])
    }

    // MARK: The check before a render

    /// A session with one baked video: the fixture's clip, saved to the original once.
    @MainActor
    private func makeBakedFixture() async throws -> Fixture {
        let f = try makeFixture()
        await f.vm.onAppear()
        f.lengths.byAsset["A"] = 4
        await f.vm.bake(replaceOriginal: false, service: FakeBaker())
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        await f.vm.previewBuildsFinished()
        f.vm.acknowledgeBake()
        XCTAssertTrue(f.media.isBaked)
        return f
    }

    /// From the save tap until Photos has answered, the editor is locked: no edit, no close, no
    /// export, no second bake. One bake comes out of it.
    @MainActor
    func testNothingElseStartsWhileABakeAsksPhotos() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(Self.stillBaked, held: true)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        let baker = FakeBaker(), second = FakeBaker()
        let title = f.vm.title

        let bake = Task { await f.vm.bake(replaceOriginal: false, service: baker) }
        await wait(for: "the check has begun") { f.vm.state.isChecking && probe.calls == 1 }
        XCTAssertEqual(f.vm.state.phase, .checking(.bake))
        XCTAssertFalse(f.vm.canEdit)
        XCTAssertFalse(f.vm.state.canClose)
        XCTAssertFalse(f.vm.state.canExport)
        XCTAssertFalse(f.vm.isRendering, "nothing renders yet")
        XCTAssertEqual(f.vm.state.lockReason, "Checking this video in Photos")

        f.vm.startExport()                              // refused
        XCTAssertEqual(f.vm.exportState, .idle)
        XCTAssertEqual(f.vm.state.phase, .checking(.bake))
        await f.vm.bake(replaceOriginal: false, service: second)   // refused, returns at once
        f.vm.rename("During the check")                 // refused
        XCTAssertEqual(f.vm.title, title)
        XCTAssertEqual(probe.calls, 1, "the refused taps asked nothing")

        probe.release()
        await bake.value
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        XCTAssertEqual(baker.saved, ["A"])
        XCTAssertTrue(second.saved.isEmpty, "the second tap baked nothing")
        XCTAssertEqual(f.vm.exportState, .idle, "and no export was queued behind the check")
        XCTAssertFalse(f.vm.isRendering)
        XCTAssertFalse(f.vm.state.isChecking)
    }

    /// An export asks Photos first too. A clip reverted while the app was away is not rendered
    /// through the bake's map: the export stops with a message. The next export has nothing to ask.
    @MainActor
    func testAnExportAsksPhotosFirstAndStopsOnARevert() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        // still baked: the export waits for the answer, then runs
        let probe = Probe(Self.stillBaked, held: true)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        f.vm.startExport()
        XCTAssertEqual(f.vm.state.phase, .checking(.export))
        XCTAssertFalse(f.vm.state.canClose)
        XCTAssertFalse(f.vm.canEdit)
        XCTAssertFalse(f.vm.isRendering)
        f.vm.startExport()                              // a second tap changes nothing
        await f.vm.bake(replaceOriginal: false, service: FakeBaker())
        XCTAssertEqual(f.vm.state.phase, .checking(.export))
        probe.release()
        await wait(for: "the export has ended") { f.vm.exportState.exportedURL != nil && !f.vm.isRendering }
        XCTAssertEqual(probe.calls, 1)
        XCTAssertTrue(f.media.isBaked)
        f.vm.shareSheetDismissed()
        XCTAssertEqual(f.vm.exportState, .idle)

        // reverted in Photos: the export stops
        f.lengths.byAsset["A"] = 9
        probe.set(BakedAssetProbe(hasEditedRendition: false, currentDuration: 9))
        f.vm.startExport()
        XCTAssertEqual(f.vm.state.phase, .checking(.export))
        await wait(for: "the check has ended") { !f.vm.state.isChecking }
        XCTAssertEqual(f.vm.exportState, .failed("This clip was reverted in Photos. Check it and export again."))
        XCTAssertFalse(f.vm.isRendering)
        XCTAssertFalse(f.media.isBaked)
        XCTAssertNil(f.media.bakeTimeMapData)
        XCTAssertEqual(f.vm.totalDuration, 9)

        // nothing baked is left: the next export starts at once
        f.vm.acknowledgeExportFailure()
        f.vm.startExport()
        XCTAssertEqual(f.vm.state.phase, .rendering(.export(progress: 0)))
        await wait(for: "the export has ended") { f.vm.exportState.exportedURL != nil && !f.vm.isRendering }
        XCTAssertEqual(probe.calls, 2)
        f.vm.shareSheetDismissed()
    }

    /// The app comes back from Photos while an export renders: the check changes nothing under
    /// the render, is remembered, and runs when the render ends.
    @MainActor
    func testACheckUnderARenderIsPutOffAndRunsWhenTheRenderEnds() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(Self.stillBaked)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        let gate = RenderGate()
        let render = try XCTUnwrap(f.vm.renderOverride)
        f.vm.renderOverride = {
            await gate.passed()
            return try await render()
        }
        f.vm.startExport()
        await wait(for: "the export renders") {
            if case .rendering(.export) = f.vm.state.phase { return true } else { return false }
        }
        let builds = f.vm.previewBuildCount

        // reverted in Photos; the app is active again
        f.lengths.byAsset["A"] = 9
        probe.set(BakedAssetProbe(hasEditedRendition: false, currentDuration: 9))
        let underRender = await f.vm.reconcileBakedFlags()?.value
        XCTAssertEqual(underRender, .unchanged, "nothing changed")
        XCTAssertTrue(f.vm.reconcileOwed)
        XCTAssertTrue(f.media.isBaked)
        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 2)])
        XCTAssertEqual(f.media.durationSec, 1, "still the rendered length")
        XCTAssertEqual(f.vm.previewBuildCount, builds, "no preview was built under the render")
        XCTAssertTrue(f.vm.isRendering)

        gate.open()
        await wait(for: "the export has ended") { !f.vm.isRendering }
        await f.vm.reconcileFinished()
        XCTAssertFalse(f.vm.reconcileOwed)
        XCTAssertFalse(f.media.isBaked, "the check ran again when the render ended")
        XCTAssertNil(f.media.bakeTimeMapData)
        XCTAssertEqual(f.media.durationSec, 9)
        XCTAssertEqual(f.vm.totalDuration, 9)
        XCTAssertNotNil(f.vm.exportState.exportedURL, "the export's own result is still there")
        XCTAssertEqual(probe.calls, 3, "before the export, under it, after it")
        f.vm.shareSheetDismissed()
    }

    /// The scene phase and the notification both report one return to the app: two calls before
    /// Photos was asked are one check. A call AFTER the question was put gets a check of its
    /// own, queued behind the first; Photos never has two questions open.
    @MainActor
    func testChecksAskedForAtTheSameTimeAreOneCheckAndALaterOneQueues() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(Self.stillBaked, held: true)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        let first = try XCTUnwrap(f.vm.reconcileBakedFlags())
        let second = try XCTUnwrap(f.vm.reconcileBakedFlags())
        XCTAssertEqual(first, second, "the same task")
        await wait(for: "Photos was asked") { probe.calls == 1 }
        let third = try XCTUnwrap(f.vm.reconcileBakedFlags())
        XCTAssertNotEqual(first, third, "the first answer may be older than this call")
        let fourth = try XCTUnwrap(f.vm.reconcileBakedFlags())
        XCTAssertEqual(third, fourth, "the queued check has not asked yet: shared")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.calls, 1, "the queued check waits for the first")
        probe.release()
        let answers = [await first.value, await third.value]
        XCTAssertEqual(answers, [.unchanged, .unchanged])
        await f.vm.reconcileFinished()
        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(probe.mostAtOnce, 1, "one question at a time")
        XCTAssertTrue(f.media.isBaked)
    }

    /// The app was suspended while a check had its question out; Photos had said "still baked".
    /// The user reverts in Photos, comes back and taps save. The bake does not take the old
    /// answer: Photos is asked again, and the bake stops.
    @MainActor
    func testABakeDoesNotTrustACheckThatAskedBeforeTheTap() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(Self.stillBaked, held: true)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        let old = try XCTUnwrap(f.vm.reconcileBakedFlags())
        await wait(for: "the old check has asked") { probe.calls == 1 }

        f.lengths.byAsset["A"] = 9
        probe.set(BakedAssetProbe(hasEditedRendition: false, currentDuration: 9))   // the revert
        let baker = FakeBaker()
        let bake = Task { await f.vm.bake(replaceOriginal: false, service: baker) }
        await wait(for: "the bake waits") { f.vm.state.phase == .checking(.bake) }
        probe.release()
        await bake.value
        let oldAnswer = await old.value
        XCTAssertEqual(oldAnswer, .unchanged)
        XCTAssertEqual(probe.calls, 2, "Photos was asked again for the bake")
        XCTAssertEqual(f.vm.bakeState, .failed("This clip was reverted in Photos. Check it and save again."))
        XCTAssertTrue(baker.saved.isEmpty)
        XCTAssertFalse(f.media.isBaked)
        XCTAssertNil(f.media.bakeTimeMapData)
    }

    /// The session has a baked video that this project does not use, and it was reverted. Its
    /// row is put right; the bake of this project goes on.
    @MainActor
    func testARevertOfAVideoThisProjectDoesNotUseStopsNothing() async throws {
        let reverted = BakedAssetProbe(hasEditedRendition: false, currentDuration: 30)
        for viaBake in [false, true] {
            let f = try makeFixture()
            defer { withExtendedLifetime(f.container) {} }
            let other = SessionMedia(sessionID: f.media.sessionID, localIdentifier: "C", kind: .video,
                                     offsetSec: 50, durationSec: 20)
            other.isBaked = true
            other.bakeTimeMap = map([part(0, from: 10, to: 30)])
            f.container.mainContext.insert(other)
            try f.container.mainContext.save()
            await f.vm.onAppear()
            f.vm.bakedAssetProbe = { $0 == "C" ? reverted : Self.stillBaked }
            let builds = f.vm.previewBuildCount
            let baker = FakeBaker()
            if viaBake {
                f.lengths.byAsset["A"] = 4
                await f.vm.bake(replaceOriginal: false, service: baker)
                XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
                XCTAssertEqual(baker.saved, ["A"])
                XCTAssertTrue(f.media.isBaked)
            } else {
                let outcome = await f.vm.reconcileBakedFlags()?.value
                XCTAssertEqual(outcome, .changedElsewhere)
                XCTAssertEqual(f.vm.previewBuildCount, builds, "this project's preview is not rebuilt")
                f.vm.startExport()
                await wait(for: "the export has ended") { f.vm.exportState.exportedURL != nil && !f.vm.isRendering }
                f.vm.shareSheetDismissed()
            }
            XCTAssertFalse(other.isBaked, "the other row is put right")
            XCTAssertNil(other.bakeTimeMapData)
            XCTAssertEqual(other.durationSec, 30)
        }
    }

    /// The Studio is dismissed from code while a bake waits for Photos. Nothing is baked for a
    /// Studio that is gone, whatever Photos answers.
    @MainActor
    func testAStudioClosedWhileABakeAsksPhotosBakesNothing() async throws {
        for answer in [Self.stillBaked, BakedAssetProbe(hasEditedRendition: false, currentDuration: 9)] {
            let f = try await makeBakedFixture()
            defer { withExtendedLifetime(f.container) {} }
            let probe = Probe(answer, held: true)
            f.vm.bakedAssetProbe = { probe.ask($0) }
            let baker = FakeBaker()
            let bake = Task { await f.vm.bake(replaceOriginal: false, service: baker) }
            await wait(for: "the bake waits") { f.vm.state.phase == .checking(.bake) && probe.calls == 1 }
            f.vm.studioClosed()
            XCTAssertFalse(f.vm.state.isChecking)
            probe.release()
            await bake.value
            XCTAssertTrue(baker.saved.isEmpty, "nothing was written to Photos")
            XCTAssertEqual(f.vm.bakeState, .idle, "and no message for nobody")
            XCTAssertFalse(f.vm.isRendering)
        }
    }

    /// The same for an export: no render, and no failure message.
    @MainActor
    func testAStudioClosedWhileAnExportAsksPhotosExportsNothing() async throws {
        for answer in [Self.stillBaked, BakedAssetProbe(hasEditedRendition: false, currentDuration: 9)] {
            let f = try await makeBakedFixture()
            defer { withExtendedLifetime(f.container) {} }
            let probe = Probe(answer, held: true)
            f.vm.bakedAssetProbe = { probe.ask($0) }
            let renders = Renders()
            let render = try XCTUnwrap(f.vm.renderOverride)
            f.vm.renderOverride = {
                renders.count += 1
                return try await render()
            }
            f.vm.startExport()
            XCTAssertEqual(f.vm.state.phase, .checking(.export))
            await wait(for: "Photos was asked") { probe.calls == 1 }
            f.vm.studioClosed()
            XCTAssertFalse(f.vm.state.isChecking)
            probe.release()
            await f.vm.reconcileFinished()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(renders.count, 0, "nothing was rendered")
            XCTAssertEqual(f.vm.exportState, .idle, "and no message")
            XCTAssertFalse(f.vm.isRendering)
        }
    }

    /// The baked rows cannot be read: nothing says whether a clip was reverted, so neither lane
    /// starts, and each says so in plain words.
    @MainActor
    func testARenderIsRefusedWhenTheBakedRowsCannotBeRead() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let renders = Renders()
        let render = try XCTUnwrap(f.vm.renderOverride)
        f.vm.renderOverride = {
            renders.count += 1
            return try await render()
        }
        f.vm.bakedRowsLoader = { throw SaveRefused() }

        f.vm.startExport()
        XCTAssertEqual(f.vm.exportState, .failed(StudioBakeState.recordsUnreadableMessage))
        XCTAssertFalse(f.vm.isRendering)
        XCTAssertFalse(f.vm.state.isChecking)
        f.vm.acknowledgeExportFailure()

        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(f.vm.bakeState, .failed(StudioBakeState.recordsUnreadableMessage))
        XCTAssertTrue(baker.saved.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(renders.count, 0)
        XCTAssertNil(f.vm.reconcileBakedFlags(), "the open and foreground checks do nothing")
        XCTAssertTrue(f.media.isBaked)
    }

    /// Photos is asked while an export renders and answers after it has ended. The answer is
    /// from the other side of the render's end: it is not applied, and Photos is asked again.
    @MainActor
    func testAnAnswerTakenUnderARenderIsNotAppliedAfterIt() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(Self.stillBaked)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        let gate = RenderGate()
        let render = try XCTUnwrap(f.vm.renderOverride)
        f.vm.renderOverride = {
            await gate.passed()
            return try await render()
        }
        f.vm.startExport()
        await wait(for: "the export renders") {
            if case .rendering(.export) = f.vm.state.phase { return true } else { return false }
        }
        // asked under the render: "no edited video" (as it would be in the middle of a write)
        probe.set(BakedAssetProbe(hasEditedRendition: false, currentDuration: 9))
        probe.hold()
        let stale = try XCTUnwrap(f.vm.reconcileBakedFlags())
        await wait(for: "asked under the render") { probe.calls == 2 }
        probe.set(Self.stillBaked)                      // what Photos says from now on

        gate.open()
        await wait(for: "the export has ended") { !f.vm.isRendering }
        probe.release()
        let answer = await stale.value
        XCTAssertEqual(answer, .unchanged)
        await f.vm.reconcileFinished()
        XCTAssertTrue(f.media.isBaked, "the answer from under the render was not applied")
        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 2)])
        XCTAssertEqual(probe.calls, 3, "Photos was asked again")
        XCTAssertFalse(f.vm.reconcileOwed)
        f.vm.shareSheetDismissed()
    }

    /// A check that lands under a BAKE is put off too, and runs when the bake ends.
    @MainActor
    func testACheckUnderABakeRunsWhenTheBakeEnds() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(Self.stillBaked)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        let gate = RenderGate()
        let render = try XCTUnwrap(f.vm.renderOverride)
        f.vm.renderOverride = {
            await gate.passed()
            return try await render()
        }
        let baker = FakeBaker()
        let bake = Task { await f.vm.bake(replaceOriginal: false, service: baker) }
        await wait(for: "the bake renders") { f.vm.isBaking }
        XCTAssertEqual(probe.calls, 1)

        probe.set(BakedAssetProbe(hasEditedRendition: false, currentDuration: 9))
        let underBake = await f.vm.reconcileBakedFlags()?.value
        XCTAssertEqual(underBake, .unchanged)
        XCTAssertTrue(f.vm.reconcileOwed)
        XCTAssertTrue(f.media.isBaked)
        XCTAssertEqual(probe.calls, 2)

        probe.set(Self.stillBaked)                      // the bake's own video is there afterwards
        gate.open()
        await bake.value
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        await f.vm.reconcileFinished()
        XCTAssertEqual(probe.calls, 3, "the check ran again when the bake ended")
        XCTAssertFalse(f.vm.reconcileOwed)
        XCTAssertTrue(f.media.isBaked)
    }

    /// Photos does not answer. The save is not held for ever: after the wait it goes on as it
    /// would have without the check, and the check is owed.
    @MainActor
    func testACheckThatGetsNoAnswerLetsTheRenderGoOn() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(BakedAssetProbe(hasEditedRendition: false, currentDuration: 9), held: true)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        f.vm.bakedProbeTimeoutSec = 0.05
        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        XCTAssertEqual(baker.saved, ["A"])
        XCTAssertFalse(f.vm.state.isChecking)
        // the owed check ran when the bake ended, and got no answer either
        await f.vm.reconcileFinished()
        XCTAssertEqual(probe.calls, 2)
        XCTAssertTrue(f.vm.reconcileOwed, "still owed; it is not asked in a loop")
        XCTAssertTrue(f.media.isBaked, "an answer that never came changes nothing")

        f.vm.acknowledgeBake()
        f.vm.startExport()
        XCTAssertEqual(f.vm.state.phase, .checking(.export))
        await wait(for: "the export has ended") { f.vm.exportState.exportedURL != nil && !f.vm.isRendering }
        f.vm.shareSheetDismissed()
        await f.vm.reconcileFinished()
        probe.release()                                 // the late answers arrive; nothing happens
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(f.media.isBaked)
    }

    /// A bake stopped by a revert whose original is in iCloud only: the message, then the
    /// "Download clip" panel, and the Studio can be closed.
    @MainActor
    func testABakeStoppedOnARevertedClipInICloudEndsInThePanel() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        f.availability.setInCloud(["A"])
        f.vm.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: false, currentDuration: 9) }
        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(f.vm.bakeState, .failed("This clip was reverted in Photos. Check it and save again."))
        XCTAssertTrue(baker.saved.isEmpty)
        XCTAssertFalse(f.vm.state.isChecking)
        XCTAssertTrue(f.vm.state.canClose)
        f.vm.acknowledgeBake()
        guard case .clipMissing = f.vm.state.phase else {
            return XCTFail("expected the missing-clip panel, got \(f.vm.state.phase)")
        }
        XCTAssertTrue(f.vm.state.canClose)
        XCTAssertTrue(f.vm.canEdit)
        XCTAssertFalse(f.vm.state.canExport)
    }

    /// After "Revert to Original" the video that is current again may be in iCloud only. The
    /// check asks where it is before anything opens it: the "Download clip" panel stands, the
    /// clip's length is not read, and it has its recorded length until it is downloaded.
    @MainActor
    func testARevertedClipThatIsInICloudIsNotOpened() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let clip = try XCTUnwrap(f.vm.clips.first)
        XCTAssertEqual(f.vm.mediaStatus(of: clip), .available)
        XCTAssertEqual(f.vm.totalDuration, 4)
        let asked = f.lengths.asked

        f.availability.setInCloud(["A"])
        f.lengths.byAsset["A"] = 9
        f.vm.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: false, currentDuration: 9) }
        let changed = await f.vm.reconcileBakedFlags()?.value
        XCTAssertEqual(changed, .changedInProject)
        XCTAssertFalse(f.media.isBaked)

        XCTAssertEqual(f.vm.mediaStatus(of: clip), .inCloud)
        guard case .clipMissing = f.vm.state.phase else {
            return XCTFail("expected the missing-clip panel, got \(f.vm.state.phase)")
        }
        XCTAssertEqual(f.lengths.asked, asked, "the clip was not opened to read its length")
        XCTAssertNil(f.vm.sourceDurations[clip.id], "the baked video's length is not kept")
        XCTAssertEqual(f.vm.totalDuration, 9, "the recorded length of the reverted video")
        XCTAssertNil(f.vm.previewPlayer)
        XCTAssertFalse(f.vm.state.canExport)

        // a save tap now does nothing: the clip is not on this phone
        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertTrue(baker.saved.isEmpty)
        XCTAssertEqual(f.vm.bakeState, .idle)
    }

    /// Photos does not know the asset (the answer for an asset that is gone, and for every
    /// asset on a simulator): nothing is cleared, and a bake and an export go ahead.
    @MainActor
    func testAnAssetPhotosDoesNotKnowChangesNothingAndBlocksNothing() async throws {
        let f = try await makeBakedFixture()
        defer { withExtendedLifetime(f.container) {} }
        let probe = Probe(Self.unknownAsset)
        f.vm.bakedAssetProbe = { probe.ask($0) }
        let changed = await f.vm.reconcileBakedFlags()?.value
        XCTAssertEqual(changed, .unchanged)
        XCTAssertTrue(f.media.isBaked)
        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 2)])
        XCTAssertFalse(f.vm.reconcileOwed)

        f.vm.startExport()
        await wait(for: "the export has ended") { f.vm.exportState.exportedURL != nil && !f.vm.isRendering }
        f.vm.shareSheetDismissed()
        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        XCTAssertEqual(baker.saved, ["A"])
        XCTAssertEqual(probe.calls, 3)
        XCTAssertTrue(f.media.isBaked)
    }

    /// The map is written with the flag and the length, before the one save. A save that fails
    /// leaves the three together on the row (Photos already has the baked video), never one
    /// without the others, and the next save that works stores all three.
    @MainActor
    func testAFailingSaveLeavesNoHalfWrittenRow() async throws {
        let f = try makeFixture()
        defer { withExtendedLifetime(f.container) {} }
        await f.vm.onAppear()

        var seen: [(baked: Bool, hasMap: Bool, length: Double?)] = []
        let media = f.media
        f.vm.saver = { _ in
            seen.append((media.isBaked, media.bakeTimeMapData != nil, media.durationSec))
            throw SaveRefused()
        }
        await f.vm.bake(replaceOriginal: false, service: FakeBaker())
        XCTAssertEqual(f.vm.bakeState, .savedProjectNotUpdated(replaced: false))
        await f.vm.previewBuildsFinished()

        XCTAssertFalse(seen.isEmpty)
        for attempt in seen {
            XCTAssertTrue(attempt.baked)
            XCTAssertTrue(attempt.hasMap, "the map is in the same save as the flag")
            XCTAssertEqual(attempt.length ?? -1, 1, accuracy: 0.1)
        }
        // nothing reached the store: no flag, no length, no map
        let stored = try XCTUnwrap(ModelContext(f.container).fetch(FetchDescriptor<SessionMedia>()).first)
        XCTAssertNil(stored.isBakedRaw)
        XCTAssertNil(stored.bakeTimeMapData)
        XCTAssertEqual(stored.durationSec, 9)
        // the row in memory has all three, and the offset where it was
        XCTAssertTrue(f.media.isBaked)
        XCTAssertEqual(f.media.bakeTimeMap?.segments, [segment(0, 2)])
        XCTAssertEqual(f.media.offsetSec, 10)

        // the next save that works stores them together
        f.vm.saver = { try $0.save() }
        f.vm.acknowledgeBake()
        f.vm.toggleHROverlay()
        let later = try XCTUnwrap(ModelContext(f.container).fetch(FetchDescriptor<SessionMedia>()).first)
        XCTAssertEqual(later.isBakedRaw, true)
        XCTAssertEqual(later.bakeTimeMap?.segments, [segment(0, 2)])
        XCTAssertEqual(later.durationSec ?? -1, 1, accuracy: 0.1)
    }
}
