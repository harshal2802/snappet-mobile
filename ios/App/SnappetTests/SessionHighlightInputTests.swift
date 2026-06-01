import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the **pure** B4 bridge mapping (`SessionHighlightInput`) — no device, no Photos,
/// no AVFoundation: `hrSeries → [HRSample]` (1:1), `SessionMedia/Clip → MediaItem` (offset/kind/
/// duration, default duration when nil, photos vs videos), routine activity mapping, and that the
/// user's selected clip ids become `pinnedIds`. The engine + planner themselves are already tested
/// in `HighlightEngineTests`; the rendered reel is device-pending (decisions.md 2026-06-01, B4).
final class SessionHighlightInputTests: XCTestCase {

    private func clip(_ id: String, video: Bool, offset: Double, duration: Double?)
        -> SessionHighlightInput.Clip {
        .init(localIdentifier: id, isVideo: video, offsetSec: offset, durationSec: duration)
    }

    // MARK: - HR mapping (1:1)

    func testHRSeriesMapsOneToOne() {
        let series = [HRPoint(t: 0, bpm: 80), HRPoint(t: 5, bpm: 120), HRPoint(t: 10, bpm: 150)]
        let samples = SessionHighlightInput.hrSamples(from: series)
        XCTAssertEqual(samples.count, series.count)
        for (s, p) in zip(samples, series) {
            XCTAssertEqual(s.t, p.t)
            XCTAssertEqual(s.bpm, p.bpm)
        }
    }

    func testEmptyHRSeriesMapsToEmpty() {
        XCTAssertTrue(SessionHighlightInput.hrSamples(from: []).isEmpty)
    }

    // MARK: - Media mapping (kind / offset / duration)

    func testVideoMapsWithDurationAndOffset() {
        let item = SessionHighlightInput.mediaItem(from: clip("vid-1", video: true, offset: 42, duration: 8))
        XCTAssertEqual(item?.id, "vid-1")
        XCTAssertEqual(item?.kind, .video)
        XCTAssertEqual(item?.startOffset, 42)
        XCTAssertEqual(item?.duration, 8)
    }

    func testPhotoMapsToPhotoWithZeroDuration() {
        let item = SessionHighlightInput.mediaItem(from: clip("pic-1", video: false, offset: 10, duration: nil))
        XCTAssertEqual(item?.kind, .photo)
        XCTAssertEqual(item?.duration, 0)
        XCTAssertEqual(item?.startOffset, 10)
    }

    func testVideoWithNilDurationUsesDefault() {
        let item = SessionHighlightInput.mediaItem(from: clip("vid-2", video: true, offset: 0, duration: nil))
        XCTAssertEqual(item?.kind, .video)
        XCTAssertEqual(item?.duration, SessionHighlightInput.defaultVideoDuration)
    }

    func testVideoWithNilDurationAndNoDefaultIsSkipped() {
        let item = SessionHighlightInput.mediaItem(
            from: clip("vid-3", video: true, offset: 0, duration: nil), defaultDuration: nil)
        XCTAssertNil(item, "a video with no resolvable duration is dropped (windowless)")
    }

    func testNegativeOffsetClampedToZero() {
        let item = SessionHighlightInput.mediaItem(from: clip("vid-4", video: true, offset: -5, duration: 4))
        XCTAssertEqual(item?.startOffset, 0)
    }

    func testMediaItemsDropsUndurationedVideosOnly() {
        let clips = [
            clip("a", video: true, offset: 0, duration: 5),
            clip("b", video: true, offset: 10, duration: nil),   // → default (kept)
            clip("c", video: false, offset: 20, duration: nil),  // photo (kept, 0 dur)
        ]
        // With no default, the undurationed video is dropped but the photo stays.
        let items = SessionHighlightInput.mediaItems(from: clips, defaultDuration: nil)
        XCTAssertEqual(items.map(\.id), ["a", "c"])
        // With a default, all three map.
        let withDefault = SessionHighlightInput.mediaItems(from: clips)
        XCTAssertEqual(withDefault.count, 3)
    }

    // MARK: - Activity mapping

    func testSportClimbingMapsToClimbing() {
        XCTAssertEqual(SessionHighlightInput.activity(sport: .climbing, category: nil), .climbing)
    }

    func testSportCalisthenicsMapsToStrength() {
        XCTAssertEqual(SessionHighlightInput.activity(sport: .calisthenics, category: .cardio), .strength)
    }

    func testGeneralSportFallsThroughToCategory() {
        XCTAssertEqual(SessionHighlightInput.activity(sport: .general, category: .cardio), .running)
        XCTAssertEqual(SessionHighlightInput.activity(sport: .general, category: .strength), .strength)
    }

    func testNoSportNoCategoryDefaultsToStrength() {
        XCTAssertEqual(SessionHighlightInput.activity(sport: nil, category: nil), .strength)
    }

    func testCategoryStretchingAndPlyometricsMapToOther() {
        XCTAssertEqual(SessionHighlightInput.activity(sport: nil, category: .stretching), .other)
        XCTAssertEqual(SessionHighlightInput.activity(sport: nil, category: .plyometrics), .other)
    }

    // MARK: - Selection → pinnedIds

    func testSelectedClipIdsBecomePinnedIds() {
        let selected = [
            clip("vid-1", video: true, offset: 0, duration: 5),
            clip("vid-2", video: true, offset: 30, duration: 5),
        ]
        let pinned = SessionHighlightInput.pinnedIds(forSelected: selected)
        XCTAssertEqual(pinned, ["vid-1", "vid-2"])
    }

    func testEmptySelectionPinsNothing() {
        XCTAssertTrue(SessionHighlightInput.pinnedIds(forSelected: []).isEmpty)
    }

    // MARK: - End-to-end assembly (bridge → Workout, no engine change)

    func testMakeWorkoutAssemblesEngineInput() {
        let series = [HRPoint(t: 0, bpm: 90), HRPoint(t: 60, bpm: 140)]
        let clips = [
            clip("vid-1", video: true, offset: 5, duration: 10),
            clip("pic-1", video: false, offset: 30, duration: nil),
        ]
        let wk = SessionHighlightInput.makeWorkout(
            hrSeries: series, clips: clips, duration: 120, sport: .climbing, category: nil)
        XCTAssertEqual(wk.activity, .climbing)
        XCTAssertEqual(wk.duration, 120)
        XCTAssertEqual(wk.hr.count, 2)
        XCTAssertEqual(wk.media.map(\.id), ["vid-1", "pic-1"])
        XCTAssertEqual(wk.media.first?.kind, .video)
        XCTAssertEqual(wk.media.last?.kind, .photo)
    }

    /// The bridge output feeds the EXISTING engine selector + planner unchanged: a selected clip's
    /// highlights end up pinned (budget-exempt) in the resulting `ReelPlan`. This exercises the
    /// reuse contract (the engine math itself is covered in HighlightEngineTests).
    func testPinnedSelectionSurvivesPlannerBudget() {
        // A surge over a filmed clip → at least one highlight on it.
        var series: [HRPoint] = []
        for t in stride(from: 0.0, through: 120.0, by: 1.0) {
            let bump = exp(-pow(t - 40, 2) / (2 * 64))   // Gaussian surge at t=40s
            series.append(HRPoint(t: t, bpm: 90 + 70 * bump))
        }
        // A long clip (20–60 s) with the surge comfortably in its middle, so the padded clip
        // window has positive width regardless of the activity preset's lead/trail.
        let clips = [clip("vid-1", video: true, offset: 20, duration: 40)]
        let wk = SessionHighlightInput.makeWorkout(
            hrSeries: series, clips: clips, duration: 120, sport: nil, category: .cardio)
        let highlights = HRHighlightSelector().select(workout: wk, config: .preset(for: wk.activity))
        XCTAssertFalse(highlights.isEmpty)

        let pinnedClipIds = SessionHighlightInput.pinnedIds(forSelected: clips)
        let pinnedHighlightIds = Set(highlights.filter { pinnedClipIds.contains($0.mediaItemId) }.map(\.id))
        XCTAssertFalse(pinnedHighlightIds.isEmpty, "selected clip expands to its highlight ids")

        let plan = ReelPlanner(targetDuration: 30).plan(
            highlights: highlights, media: wk.media, pinnedIds: pinnedHighlightIds)
        // The pinned (selected-clip) highlights survive into the reel as budget-exempt segments:
        // every segment in the plan comes from the one selected clip, and at least one pinned
        // highlight is present (the planner drops only any zero-duration pins, which the engine
        // wouldn't emit for a surge inside a filmed window).
        let segmentIds = Set(plan.segments.map(\.id))
        XCTAssertFalse(plan.segments.isEmpty)
        XCTAssertTrue(plan.segments.allSatisfy { $0.mediaItemId == "vid-1" })
        XCTAssertFalse(pinnedHighlightIds.isDisjoint(with: segmentIds),
                       "at least one pinned (selected-clip) highlight is kept in the reel")
    }
}
