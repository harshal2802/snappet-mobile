import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the pure Weekly Highlight Reel logic (highlights P4): the cross-session
/// timeline stitch, the feed-hero offer gate, and the `ReelSource.week` wiring. No device,
/// no SwiftData, no simulator.
final class WeeklyHighlightsTests: XCTestCase {
    private let monday = Date(timeIntervalSince1970: 1_751_842_800)   // within some week

    private func session(_ id: UUID = UUID(), title: String = "Push Day",
                         startedAt: Date, duration: Double = 3600,
                         hr: [(Double, Double)] = [(0, 100), (60, 150)],
                         maxHR: Double? = nil, restHR: Double? = nil,
                         clips: [SessionHighlightInput.Clip],
                         isClimbing: Bool = false) -> WeeklyHighlights.SessionInput {
        WeeklyHighlights.SessionInput(
            id: id, title: title, startedAt: startedAt, duration: duration,
            hrSeries: hr.map { HRPoint(t: $0.0, bpm: $0.1) },
            maxHR: maxHR, restHR: restHR, clips: clips, isClimbing: isClimbing)
    }

    private func videoClip(_ offset: Double, id: String = UUID().uuidString,
                           duration: Double = 8) -> SessionHighlightInput.Clip {
        .init(localIdentifier: id, isVideo: true, offsetSec: offset, durationSec: duration)
    }

    // MARK: - Stitch: one synthetic timeline, no overlap

    func testStitchShiftsLaterSessionsPastEarlierOnes() throws {
        let a = session(startedAt: monday, duration: 1000, clips: [videoClip(100, id: "a")])
        let b = session(startedAt: monday.addingTimeInterval(86_400), duration: 500,
                        clips: [videoClip(50, id: "b")])
        let stitched = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: [b, a]),
                                     "input order must not matter — the stitch sorts by start")

        let mediaA = try XCTUnwrap(stitched.workout.media.first { $0.id == "a" })
        let mediaB = try XCTUnwrap(stitched.workout.media.first { $0.id == "b" })
        XCTAssertEqual(mediaA.startOffset, 100, "the first session keeps its own offsets")
        XCTAssertGreaterThan(mediaB.startOffset, mediaA.endOffset,
                             "session B's clips must land after ALL of session A's span")
        XCTAssertGreaterThanOrEqual(mediaB.startOffset, 1000 + 50,
                                    "B shifts by at least A's duration")
        // HR samples shift with their session too — B's t=0 sample can't collide with A's.
        XCTAssertEqual(stitched.workout.hr.filter { $0.t == 0 }.count, 1)
    }

    func testStitchSpanCoversClipsPastTheRecordedDuration() throws {
        // A clip that ends AFTER the session's recorded duration must still not overlap session B.
        let a = session(startedAt: monday, duration: 100, clips: [videoClip(200, id: "late", duration: 30)])
        let b = session(startedAt: monday.addingTimeInterval(3600), clips: [videoClip(0, id: "b")])
        let stitched = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: [a, b]))
        let late = try XCTUnwrap(stitched.workout.media.first { $0.id == "late" })
        let mediaB = try XCTUnwrap(stitched.workout.media.first { $0.id == "b" })
        XCTAssertGreaterThan(mediaB.startOffset, late.endOffset)
    }

    func testStitchAggregatesProfileAndActivity() throws {
        let gym = session(startedAt: monday, maxHR: 185, restHR: 62, clips: [videoClip(10)])
        let climb = session(startedAt: monday.addingTimeInterval(7200), maxHR: 192, restHR: 58,
                            clips: [videoClip(10)], isClimbing: true)
        let mixed = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: [gym, climb]))
        XCTAssertEqual(mixed.workout.maxBpm, 192, "max of the sessions' maxes")
        XCTAssertEqual(mixed.workout.restBpm, 58, "min of the sessions' rests")
        XCTAssertEqual(mixed.workout.activity, .other, "mixed disciplines → .other preset")

        let allClimb = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(
            sessions: [climb, session(startedAt: monday, clips: [videoClip(5)], isClimbing: true)]))
        XCTAssertEqual(allClimb.workout.activity, .climbing)

        let allGym = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: [gym]))
        XCTAssertEqual(allGym.workout.activity, .strength)
    }

    func testStitchIsNilWithoutAnyUsableMedia() {
        XCTAssertNil(WeeklyHighlights.stitchedWorkout(sessions: []))
        let noMedia = session(startedAt: monday, clips: [])
        XCTAssertNil(WeeklyHighlights.stitchedWorkout(sessions: [noMedia]))
    }

    func testStitchedBoostWindowsShiftWithTheirSession() throws {
        var a = session(startedAt: monday, duration: 1000, clips: [videoClip(10, id: "a")])
        a.boostWindows = [100...160]
        var b = session(startedAt: monday.addingTimeInterval(86_400), clips: [videoClip(10, id: "b")])
        b.boostWindows = [30...60]
        let stitched = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: [a, b]))
        XCTAssertEqual(stitched.boostWindows.count, 2)
        XCTAssertEqual(stitched.boostWindows[0], 100...160, "session A's window is unshifted")
        XCTAssertGreaterThan(stitched.boostWindows[1].lowerBound, 1000,
                             "session B's window shifts past A's span")
    }

    // MARK: - Feed-hero offer

    private func post(sessionID: UUID = UUID(), startedAt: Date, kinds: [String],
                      isReel: Bool = false) -> ClipFeedPost {
        ClipFeedPost(
            id: UUID().uuidString, sessionID: sessionID, kind: .gym, moduleID: "workout-log",
            discipline: .strength, title: "T", subtitle: "S", overlayDetail: "",
            climbUUID: nil, exerciseID: nil, captureAt: startedAt,
            sessionStartedAt: startedAt, sessionEndedAt: nil, isFromAppleWatch: false,
            isReel: isReel,
            clips: kinds.map { kind in
                ClipFeedItem(media: MediaInput(id: UUID(), kind: kind, offsetSec: 0,
                                               durationSec: kind == "video" ? 5 : nil,
                                               exerciseId: nil, setIndex: nil, climbUUID: nil,
                                               localIdentifier: UUID().uuidString,
                                               reelTitle: isReel ? "R" : nil),
                             attemptLabel: nil)
            },
            aspect: 1)
    }

    func testOfferNeedsTwoVideoClipsInsideTheWeek() {
        let week = WeeklyHighlights.week(containing: monday)
        let inWeek = post(startedAt: week.start.addingTimeInterval(3600), kinds: ["video"])
        XCTAssertNil(WeeklyHighlights.offer(posts: [inWeek], week: week), "one video isn't a montage")

        let second = post(startedAt: week.start.addingTimeInterval(7200), kinds: ["video", "photo"])
        let offer = WeeklyHighlights.offer(posts: [inWeek, second], week: week)
        XCTAssertEqual(offer?.videoClipCount, 2, "photos don't count toward the gate")
        XCTAssertEqual(offer?.sessionCount, 2)
    }

    func testOfferIgnoresPostsOutsideTheWeekAndReels() {
        let week = WeeklyHighlights.week(containing: monday)
        let lastWeek = post(startedAt: week.start.addingTimeInterval(-3600),
                            kinds: ["video", "video"])
        let reel = post(startedAt: week.start.addingTimeInterval(3600),
                        kinds: ["video", "video"], isReel: true)
        XCTAssertNil(WeeklyHighlights.offer(posts: [lastWeek, reel], week: week),
                     "old sessions and posted reels never feed the weekly cut")
    }

    func testOfferSubtitleCountsSessionsOnce() {
        let week = WeeklyHighlights.week(containing: monday)
        let sid = UUID()
        let p1 = post(sessionID: sid, startedAt: week.start.addingTimeInterval(100), kinds: ["video"])
        let p2 = post(sessionID: sid, startedAt: week.start.addingTimeInterval(100), kinds: ["video"])
        let offer = WeeklyHighlights.offer(posts: [p1, p2], week: week)
        XCTAssertEqual(offer?.sessionCount, 1, "two posts of one session are one session")
        XCTAssertEqual(offer?.subtitle, "2 clips from 1 session this week")
    }

    // MARK: - ReelSource.week wiring

    func testWeekSourceIsTrimmedAndPostsUnderTheLatestSession() throws {
        let older = session(startedAt: monday, clips: [videoClip(10)])
        let latest = session(startedAt: monday.addingTimeInterval(86_400), clips: [videoClip(20)])
        let source = try XCTUnwrap(ReelSource.week(sessions: [latest, older], now: monday))
        XCTAssertTrue(source.trimToHighlights, "a week condenses to moments — never full-length")
        XCTAssertEqual(source.postSessionID, latest.id)
        XCTAssertEqual(source.postTitle, "Your Week — Highlights")
    }

    func testWeekSourceIsNilWithNothingToCut() {
        XCTAssertNil(ReelSource.week(sessions: [], now: monday))
    }
}
