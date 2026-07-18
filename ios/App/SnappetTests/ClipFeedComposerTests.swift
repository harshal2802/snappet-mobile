import XCTest
@testable import Snappet

/// Unit tests for the **pure** Clips-feed composition (prompt 82) — no device, no SwiftData, no Photos.
/// Builds synthetic media bundles and asserts grouping (one post per exercise/climb), capture ordering,
/// the attempt/set labels, and the derived header/overlay strings.
final class ClipFeedComposerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func video(_ offset: Double, exercise: UUID? = nil, set: Int? = nil,
                       climb: String? = nil, aspect: Double? = nil, asset: String? = nil) -> MediaInput {
        // `asset` forces a specific PHAsset localIdentifier (the dedup key); defaults to per-offset so
        // existing tests keep distinct assets. The row `id` is always fresh → two rows can share an asset.
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: 6,
                   exerciseId: exercise, setIndex: set, climbUUID: climb,
                   localIdentifier: asset ?? "asset-\(offset)", aspect: aspect)
    }

    /// How many times a given PHAsset `localIdentifier` appears across ALL posts' clips (must be ≤ 1 after
    /// dedup — one physical video shows once across the whole feed).
    private func occurrences(of asset: String, in posts: [ClipFeedPost]) -> Int {
        posts.flatMap(\.clips).filter { $0.media.localIdentifier == asset }.count
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

    func testAppleWatchFlagPropagatesToPosts() {
        let watch = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Run",
                                        startedAt: start, isFromAppleWatch: true)
        let gym = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Push Day", startedAt: start)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: watch, clips: [video(10)]),
                       .init(meta: gym, clips: [video(20)])],
            climbMeta: [:], exerciseName: { _ in "Session clips" })
        XCTAssertEqual(posts.filter(\.isFromAppleWatch).count, 1)
        XCTAssertTrue(posts.first { $0.sessionID == watch.id }!.isFromAppleWatch)
        XCTAssertFalse(posts.first { $0.sessionID == gym.id }!.isFromAppleWatch)
    }

    // MARK: - Ordering: clips by offset, posts newest-SESSION first

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

    func testPostsSortedNewestSessionFirstAcrossSessions() {
        let older = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Leg Day",
                                        startedAt: start, angle: nil)
        let newer = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Push Day",
                                        startedAt: start.addingTimeInterval(3600), angle: nil)
        let ex = UUID()
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: older, clips: [video(5, exercise: ex, set: 0, asset: "a")]),
                       .init(meta: newer, clips: [video(5, exercise: ex, set: 0, asset: "b")])],
            climbMeta: [:],
            exerciseName: { _ in "Back Squat" })

        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.subtitle, "Push Day")       // newer SESSION first
        XCTAssertEqual(posts.last?.subtitle, "Leg Day")
    }

    // The sort key is the SESSION's start/end, NOT the clip capture offset (R5). A session that STARTED
    // later sorts first even if its first clip's capture time is EARLIER than another session's.
    func testPostsSortedBySessionStartNotCaptureOffset() {
        // earlyStart session began at `start` but its clip was filmed 8000s in → captureAt = start+8000.
        let earlyStart = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Early Start", startedAt: start, angle: nil)
        // lateStart session began at start+7200 with a clip 5s in → captureAt = start+7205 (EARLIER capture).
        let lateStart = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Late Start",
                                            startedAt: start.addingTimeInterval(7200), angle: nil)
        let ex = UUID()
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: earlyStart, clips: [video(8000, exercise: ex, set: 0, asset: "x")]),
                       .init(meta: lateStart, clips: [video(5, exercise: ex, set: 0, asset: "y")])],
            climbMeta: [:], exerciseName: { _ in "Squat" })

        // Old captureAt sort would put Early Start first (start+8000 > start+7205). Session-start sort flips it.
        XCTAssertEqual(posts.map(\.subtitle), ["Late Start", "Early Start"])
        XCTAssertGreaterThan(posts[1].captureAt, posts[0].captureAt)   // proves capture order is NOT the key
    }

    // Sessions sharing a startedAt are tie-broken by session END time (later end first), then capture.
    func testPostsTieBrokenBySessionEnd() {
        let s = start.addingTimeInterval(100)
        let endsSooner = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Ends Sooner",
                                             startedAt: s, endedAt: s.addingTimeInterval(200), angle: nil)
        let endsLater = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Ends Later",
                                            startedAt: s, endedAt: s.addingTimeInterval(900), angle: nil)
        let ex = UUID()
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: endsSooner, clips: [video(5, exercise: ex, set: 0, asset: "p")]),
                       .init(meta: endsLater, clips: [video(5, exercise: ex, set: 0, asset: "q")])],
            climbMeta: [:], exerciseName: { _ in "Squat" })

        XCTAssertEqual(posts.map(\.subtitle), ["Ends Later", "Ends Sooner"])   // later end wins the tie
    }

    // MARK: - Duplicate-asset collapse (R2/R4): one physical video shows once across the whole feed

    // The SAME asset tagged to a climb AND sitting in General within one session collapses to ONE clip,
    // under the assigned (climb) bucket — an assigned clip beats a General one.
    func testDuplicateAssetWithinSessionAppearsOnce() {
        let s = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "Boulder", startedAt: start, angle: 40)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: s, clips: [
                video(10, climb: "c", asset: "dup"),   // assigned to climb c
                video(10, asset: "dup"),               // same asset, General
            ])],
            climbMeta: ["c": .init(name: "Crux", gradeLabel: "6c", angle: 40)],
            exerciseName: { _ in "?" })

        XCTAssertEqual(occurrences(of: "dup", in: posts), 1)         // shows ONCE, not twice
        XCTAssertEqual(posts.count, 1)                               // no leftover General post
        XCTAssertEqual(posts.first?.title, "Crux")                  // survived under its climb (assigned wins)
        XCTAssertEqual(posts.first?.clipCount, 1)
    }

    // The same asset assigned to TWO different sets (a buggy/legacy duplicate row, or what a non-exclusive
    // reassign would leave) shows ONCE — proving R3's "removed from the previous set" holds at the feed.
    func testDuplicateAssetAcrossTwoSetsAppearsOnce() {
        let exA = UUID(), exB = UUID()
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Leg Day", startedAt: start, angle: nil)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: s, clips: [
                video(10, exercise: exA, set: 0, asset: "moved"),
                video(10, exercise: exB, set: 1, asset: "moved"),
            ])],
            climbMeta: [:], exerciseName: { id in id == exA ? "Squat" : "Lunge" })

        XCTAssertEqual(occurrences(of: "moved", in: posts), 1)      // exactly one set keeps it
        XCTAssertEqual(posts.flatMap(\.clips).count, 1)            // only one clip total
    }

    // The same asset discovered into two adjacent sessions (the ±90s pad overlap) shows ONCE — under the
    // MORE-RECENT session (later startedAt wins the tie when both are equally assigned).
    func testDuplicateAssetAcrossSessionsAppearsOnce() {
        let older = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "Older", startedAt: start, angle: 40)
        let newer = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "Newer",
                                        startedAt: start.addingTimeInterval(3600), angle: 40)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: older, clips: [video(10, climb: "a", asset: "shared"),
                                                  video(20, climb: "a", asset: "olderOnly")]),
                       .init(meta: newer, clips: [video(5, climb: "b", asset: "shared")])],
            climbMeta: ["a": .init(name: "A", gradeLabel: "6a", angle: 40),
                        "b": .init(name: "B", gradeLabel: "6b", angle: 40)],
            exerciseName: { _ in "?" })

        XCTAssertEqual(occurrences(of: "shared", in: posts), 1)     // not double-posted across sessions
        // The survivor lives in the NEWER session's post (climb B); the older session keeps only its own clip.
        let sharedPost = posts.first { $0.clips.contains { $0.media.localIdentifier == "shared" } }
        XCTAssertEqual(sharedPost?.sessionID, newer.id)
        XCTAssertEqual(occurrences(of: "olderOnly", in: posts), 1)  // the older session's unique clip survives
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
        // tile matches the video and fills full-height with no bars/crop.
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
        // End-to-end through posts(): a 9:16 clip's true aspect is carried through un-clamped (within range).
        let s = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "S", startedAt: start, angle: 40)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [video(10, climb: "c", aspect: 9.0 / 16.0)])
        let posts = ClipFeedComposer.posts(
            sessions: [bundle],
            climbMeta: ["c": .init(name: "C", gradeLabel: "6a", angle: 40)], exerciseName: { _ in "?" })
        XCTAssertEqual(posts.first?.aspect ?? 0, 9.0 / 16.0, accuracy: 0.0001)
    }

    // MARK: - Posted highlight reels (highlights P2)

    private func reel(_ offset: Double, title: String) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: 30,
                   exerciseId: nil, setIndex: nil, climbUUID: nil,
                   localIdentifier: "reel-\(offset)", reelTitle: title)
    }

    func testReelClipBecomesItsOwnPost() throws {
        let ex = UUID()
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Push Day", startedAt: start)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [
            video(10, exercise: ex, set: 0),
            reel(0, title: "Push Day — Highlights"),
        ])
        let posts = ClipFeedComposer.posts(sessions: [bundle], climbMeta: [:],
                                           exerciseName: { _ in "Bench" })

        XCTAssertEqual(posts.count, 2, "the reel never joins the exercise carousel")
        let reelPost = try XCTUnwrap(posts.first(where: \.isReel))
        XCTAssertEqual(reelPost.title, "Push Day — Highlights")
        XCTAssertEqual(reelPost.subtitle, "Push Day")
        XCTAssertEqual(reelPost.clipCount, 1)
        XCTAssertNil(reelPost.clips.first?.attemptLabel, "a reel isn't 'Set N' / 'Attempt N'")
        XCTAssertEqual(reelPost.moduleID, "workout-log")
        let regular = try XCTUnwrap(posts.first(where: { !$0.isReel }))
        XCTAssertEqual(regular.clipCount, 1)
        XCTAssertFalse(regular.clips.contains(where: \.media.isReel))
    }

    func testReelOnlySessionStillPosts() {
        // The regular grouping path skips a session whose remaining clips are empty — the reel
        // post must still come out.
        let s = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "Board night", startedAt: start, angle: 40)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [reel(0, title: "Board night — Highlights")])
        let posts = ClipFeedComposer.posts(sessions: [bundle], climbMeta: [:], exerciseName: { _ in "?" })
        XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(posts[0].isReel)
        XCTAssertEqual(posts[0].discipline, .climbing)
        XCTAssertEqual(posts[0].moduleID, "kilter")
    }

    // MARK: - Festival posts (festival prompt 03)

    private func festMeta(setKey: UUID?, artist: String?, stage: String?) -> ClipFeedFestivalMeta {
        ClipFeedFestivalMeta(setKey: setKey?.uuidString, artist: artist, stage: stage,
                             festivalName: "Glastonbury 2026", dayLabel: "Saturday")
    }

    func testTaggedClipsBecomeAnArtistStagePostAndLeaveTheGymGrouping() throws {
        let ex = UUID(), setID = UUID()
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Glastonbury 2026", startedAt: start)
        let tagged1 = video(10, exercise: ex)      // recorded from the live sheet (entity-assigned)
        let tagged2 = video(200)                   // Camera-app discovery (general bucket)
        let untagged = video(400)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [tagged1, tagged2, untagged])
        let posts = ClipFeedComposer.posts(
            sessions: [bundle], climbMeta: [:], exerciseName: { _ in "Fred again.. · Pyramid Stage" },
            festivalMeta: [tagged1.id: festMeta(setKey: setID, artist: "Fred again..", stage: "Pyramid Stage"),
                           tagged2.id: festMeta(setKey: setID, artist: "Fred again..", stage: "Pyramid Stage")])

        XCTAssertEqual(posts.count, 2, "one festival post + one leftover session post")
        let fest = try XCTUnwrap(posts.first { $0.discipline == .festival })
        XCTAssertEqual(fest.title, "Fred again.. · Pyramid Stage",
                       "titled artist · stage — existing search matches the artist free")
        XCTAssertEqual(fest.subtitle, "Glastonbury 2026 · Saturday")
        XCTAssertEqual(fest.clipCount, 2, "one set = one post, whatever bucket each clip sat in")
        XCTAssertEqual(fest.clips.map(\.attemptLabel), ["Clip 1", "Clip 2"])
        XCTAssertEqual(fest.moduleID, "workout-log", "Go to session opens the dance session")
        XCTAssertFalse(fest.isReel)
        let leftover = try XCTUnwrap(posts.first { $0.discipline != .festival })
        XCTAssertEqual(leftover.clipCount, 1, "tagged clips left the exercise grouping")
        XCTAssertEqual(leftover.clips.first?.media.id, untagged.id)
    }

    func testTwoSetsMakeTwoFestivalPosts() {
        let setA = UUID(), setB = UUID()
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Glastonbury 2026", startedAt: start)
        let a = video(10), b = video(20)
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: s, clips: [a, b])], climbMeta: [:], exerciseName: { _ in "?" },
            festivalMeta: [a.id: festMeta(setKey: setA, artist: "Little Simz", stage: "Pyramid Stage"),
                           b.id: festMeta(setKey: setB, artist: "Overmono", stage: "West Holts")])
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(Set(posts.map(\.title)), ["Little Simz · Pyramid Stage", "Overmono · West Holts"])
        XCTAssertTrue(posts.allSatisfy { $0.discipline == .festival })
        for post in posts {
            XCTAssertNil(post.clips.first?.attemptLabel, "single-clip posts carry no Clip N label")
        }
    }

    func testFestivalSessionReelReadsFestival() throws {
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Glastonbury 2026", startedAt: start)
        let r = reel(0, title: "Fred again.. · Pyramid Stage")
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: s, clips: [r])], climbMeta: [:], exerciseName: { _ in "?" },
            festivalMeta: [r.id: festMeta(setKey: nil, artist: nil, stage: nil)])
        let post = try XCTUnwrap(posts.first)
        XCTAssertTrue(post.isReel, "still a reel post — ✦ REEL badge, raw playback")
        XCTAssertEqual(post.discipline, .festival, "…but festival-flavored")
        XCTAssertEqual(post.subtitle, "Glastonbury 2026 · Saturday")
        XCTAssertEqual(post.title, "Fred again.. · Pyramid Stage")
    }

    func testFestivalMetaAbsentLeavesTheFeedUntouched() {
        // The zero-festival case must compose byte-identically to the pre-prompt-03 feed.
        let ex = UUID()
        let s = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Push Day", startedAt: start)
        let bundle = ClipFeedComposer.SessionBundle(meta: s, clips: [video(10, exercise: ex, set: 0)])
        let with = ClipFeedComposer.posts(sessions: [bundle], climbMeta: [:],
                                          exerciseName: { _ in "Bench" }, festivalMeta: [:])
        let without = ClipFeedComposer.posts(sessions: [bundle], climbMeta: [:],
                                             exerciseName: { _ in "Bench" })
        XCTAssertEqual(with, without)
    }
}
