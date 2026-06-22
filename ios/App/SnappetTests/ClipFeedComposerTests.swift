import XCTest
@testable import Snappet

/// Unit tests for the **pure** Clips-feed composition (prompt 82) — no device, no SwiftData, no Photos.
/// Builds synthetic media bundles and asserts grouping (one post per exercise/climb), capture ordering,
/// the attempt/set labels, and the derived header/overlay strings.
final class ClipFeedComposerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func video(_ offset: Double, exercise: UUID? = nil, set: Int? = nil,
                       climb: String? = nil, aspect: Double? = nil) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: 6,
                   exerciseId: exercise, setIndex: set, climbUUID: climb,
                   localIdentifier: "asset-\(offset)", aspect: aspect)
    }

    // MARK: - Grouping: one post per climb / exercise

    func testKilterSessionSplitsIntoOnePostPerClimb() {
        let s = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "Tuesday Boulder", startedAt: start, angle: 40)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [
            video(10, climb: "starfish"),
            video(20, climb: "crux"),
            video(30, climb: "starfish"),
        ])
        let posts = ClipFeedComposer.posts(
            sessions: [bundle],
            climbMeta: ["starfish": .init(name: "Starfish", gradeLabel: "6b/V4", angle: 40),
                        "crux": .init(name: "Blue Crux", gradeLabel: "6c/V5", angle: 40)],
            exerciseName: { _ in "?" })

        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(Set(posts.map(\.title)), ["Starfish", "Blue Crux"])
        let starfish = posts.first { $0.title == "Starfish" }!
        XCTAssertEqual(starfish.clipCount, 2)                       // two clips collapse into one post
        XCTAssertEqual(starfish.discipline, .climbing)
        XCTAssertEqual(starfish.moduleID, "kilter")
        XCTAssertEqual(starfish.overlayDetail, "6b/V4 · 40°")
        XCTAssertEqual(starfish.subtitle, "Tuesday Boulder · 40°")
        XCTAssertEqual(starfish.climbUUID, "starfish")
    }

    // MARK: - Ordering: clips by offset, posts newest-capture first

    func testClipsOrderedByOffsetWithAttemptLabels() {
        let s = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "Session", startedAt: start, angle: 40)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [
            video(90, climb: "c"), video(10, climb: "c"), video(50, climb: "c"),
        ])
        let posts = ClipFeedComposer.posts(
            sessions: [bundle],
            climbMeta: ["c": .init(name: "C", gradeLabel: "6a", angle: 40)],
            exerciseName: { _ in "?" })

        let clips = posts[0].clips
        XCTAssertEqual(clips.map { $0.media.offsetSec }, [10, 50, 90])     // sorted by offset
        XCTAssertEqual(clips.map { $0.attemptLabel }, ["Attempt 1", "Attempt 2", "Attempt 3"])
        // captureAt = session start + earliest clip offset.
        XCTAssertEqual(posts[0].captureAt, start.addingTimeInterval(10))
    }

    func testPostsSortedNewestCaptureFirstAcrossSessions() {
        let older = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Leg Day",
                                        startedAt: start, angle: nil)
        let newer = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Push Day",
                                        startedAt: start.addingTimeInterval(3600), angle: nil)
        let ex = UUID()
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: older, clips: [video(5, exercise: ex, set: 0)]),
                       .init(meta: newer, clips: [video(5, exercise: ex, set: 0)])],
            climbMeta: [:],
            exerciseName: { _ in "Back Squat" })

        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.subtitle, "Push Day")       // newer session first
        XCTAssertEqual(posts.last?.subtitle, "Leg Day")
    }

    // MARK: - Gym set labels + exercise name resolution

    func testGymExerciseUsesSetLabelAndResolvedName() {
        let ex = UUID()
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Leg Day", startedAt: start, angle: nil)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: s, clips: [video(10, exercise: ex, set: 2)])],
            climbMeta: [:],
            exerciseName: { _ in "Back Squat" })

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].title, "Back Squat")
        XCTAssertEqual(posts[0].discipline, .strength)
        XCTAssertEqual(posts[0].moduleID, "workout-log")
        XCTAssertEqual(posts[0].overlayDetail, "")               // no climb grade for gym
        XCTAssertEqual(posts[0].clips.first?.attemptLabel, "Set 3")   // setIndex 2 → "Set 3"
    }

    // MARK: - Untagged ("general") clips still surface, under the session

    func testUntaggedClipsBecomeASessionPost() {
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Leg Day", startedAt: start, angle: nil)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: s, clips: [video(10), video(20)])],
            climbMeta: [:],
            exerciseName: { _ in "?" })

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].title, "Leg Day")                // "general" resolves to the session title
        XCTAssertEqual(posts[0].discipline, .general)
        XCTAssertEqual(posts[0].clips.map { $0.attemptLabel }, ["Clip 1", "Clip 2"])
    }

    // A clip with NO exercise/climb tag but a stray `setIndex` (the two are independent optionals on
    // SessionMedia) lands in the "general" bucket — its label must stay "Clip N", not a misleading "Set N".
    func testStraySetIndexOnUntaggedClipStaysClipLabel() {
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Leg Day", startedAt: start, angle: nil)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: s, clips: [video(10, set: 2), video(20)])],
            climbMeta: [:],
            exerciseName: { _ in "?" })

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].title, "Leg Day")               // untagged → "general" → session title
        XCTAssertEqual(posts[0].discipline, .general)
        XCTAssertEqual(posts[0].clips.map { $0.attemptLabel }, ["Clip 1", "Clip 2"])   // not "Set 3"
    }

    func testEmptySessionsProduceNoPosts() {
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Empty", startedAt: start, angle: nil)
        XCTAssertTrue(ClipFeedComposer.posts(sessions: [.init(meta: s, clips: [])],
                                             climbMeta: [:], exerciseName: { _ in "?" }).isEmpty)
    }

    // MARK: - Adaptive tile aspect (prompt 92)

    func testPostAspectKeepsNineBySixteenPortrait() {
        // A standard 9:16 phone-portrait clip (0.5625) is within range → used AS-IS (no 4:5 floor), so the
        // tile matches the video and shows no side bars.
        XCTAssertEqual(ClipFeedComposer.postAspect([video(0, climb: "c", aspect: 9.0 / 16.0)]),
                       9.0 / 16.0, accuracy: 0.0001)
    }

    func testPostAspectClampsExtremePortraitToMin() {
        // Only an EXTREME-tall clip (2.5:1, 0.4) clamps up to the minAspect (0.5) tallest-tile bound.
        XCTAssertEqual(ClipFeedComposer.postAspect([video(0, climb: "c", aspect: 0.4)]),
                       ClipFeedComposer.minAspect, accuracy: 0.0001)
    }

    func testPostAspectClampsLandscapeTo191() {
        // A 21:9 ultrawide (2.33) clamps DOWN to the 1.91 widest-tile bound.
        XCTAssertEqual(ClipFeedComposer.postAspect([video(0, climb: "c", aspect: 21.0 / 9.0)]),
                       ClipFeedComposer.maxAspect, accuracy: 0.0001)
    }

    func testPostAspectPassesThroughWithinRange() {
        // A 1:1 square (1.0) is inside [0.8, 1.91] → used as-is.
        XCTAssertEqual(ClipFeedComposer.postAspect([video(0, climb: "c", aspect: 1.0)]), 1.0, accuracy: 0.0001)
    }

    func testPostAspectDefaultsWhenUnknown() {
        // No clip has a resolved aspect yet → the 4:5 default (until backfilled).
        XCTAssertEqual(ClipFeedComposer.postAspect([video(0, climb: "c", aspect: nil)]),
                       ClipFeedComposer.defaultAspect, accuracy: 0.0001)
    }

    func testPostAspectUsesFirstResolvedClip() {
        // The carousel shares ONE height → the first clip WITH a known aspect wins (the 2nd here, since
        // the first is still nil), clamped to range.
        let clips = [video(0, climb: "c", aspect: nil), video(10, climb: "c", aspect: 1.2)]
        XCTAssertEqual(ClipFeedComposer.postAspect(clips), 1.2, accuracy: 0.0001)
    }

    func testComposedPostCarriesResolvedAspect() {
        // End-to-end through posts(): a 9:16 clip's true aspect is carried through un-clamped (within range)
        // so the tile matches the video.
        let s = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "S", startedAt: start, angle: 40)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [video(10, climb: "c", aspect: 9.0 / 16.0)])
        let posts = ClipFeedComposer.posts(
            sessions: [bundle],
            climbMeta: ["c": .init(name: "C", gradeLabel: "6a", angle: 40)], exerciseName: { _ in "?" })
        XCTAssertEqual(posts.first?.aspect ?? 0, 9.0 / 16.0, accuracy: 0.0001)
    }
}
