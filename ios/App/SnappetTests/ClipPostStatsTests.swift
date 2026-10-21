import XCTest
@testable import Snappet

/// Instagram-style Clips posts (prompt 196): the stats line + PR, set chips, captions + #tags, search, counts.
final class ClipPostStatsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func bench(_ sets: [(Int, Double)]) -> SessionExercise {
        SessionExercise(exerciseId: "bench", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                        sets: sets.map { SetLog(actualReps: $0.0, actualWeight: $0.1, weightUnit: .kg, completedAt: start) },
                        kindRaw: SetKind.repsWeight.rawValue)
    }
    private let key = ActivityKey(exerciseId: "bench", nameKey: "")

    func testTheStatsLineAndSetDetails() throws {
        let st = try XCTUnwrap(ClipPostStats.make(bench([(8, 75), (8, 75), (7, 75), (6, 72.5)]), title: "Bench Press",
                                                  key: key, priorBestKg: nil, unit: .kg))
        XCTAssertEqual(st.line, "4 × 8 @ 75 kg")
        XCTAssertFalse(st.isPR, "no earlier session → not a PR")
        XCTAssertEqual(st.setDetail[3], "72.5 kg × 6")
        XCTAssertEqual(ClipPostStats.display(st), "4 × 8 @ 75 kg")
    }

    func testAPRBeatsEveryEarlierSession() throws {
        let earlier = ClipPostStats.bestKg(bench([(8, 70)]))!
        let pr = try XCTUnwrap(ClipPostStats.make(bench([(8, 75)]), title: "Bench", key: key, priorBestKg: earlier, unit: .kg))
        XCTAssertTrue(pr.isPR)
        XCTAssertEqual(ClipPostStats.display(pr), "1 × 8 @ 75 kg · ▲ PR")
        let same = try XCTUnwrap(ClipPostStats.make(bench([(8, 70)]), title: "Bench", key: key, priorBestKg: earlier, unit: .kg))
        XCTAssertFalse(same.isPR, "matching isn't beating")
    }

    func testCaptionsRoundTripAndTags() throws {
        let c = ClipCaption(text: "Last rep was a grind 💪 #pushday #PR,", showStats: true, showSets: false, showHR: true)
        XCTAssertEqual(ClipCaption.decode(c.encoded()), c)
        XCTAssertEqual(c.tags, ["pushday", "pr"])
        XCTAssertTrue(ClipCaption().isDefault)
        XCTAssertFalse(c.isDefault)
        XCTAssertEqual(ClipCaption.contentID(postID: "ex@s"), "clippost:ex@s")
    }

    private func post(stats: ClipFeedPostStats?, title: String = "Bench Press", session: String = "Push Day") -> ClipFeedPost {
        ClipFeedPost(id: "p", sessionID: UUID(), kind: .gym, moduleID: "workout-log", discipline: .strength,
                     title: title, subtitle: session, overlayDetail: "", climbUUID: nil, exerciseID: nil,
                     captureAt: start, sessionStartedAt: start, sessionEndedAt: nil, isFromAppleWatch: false,
                     clips: [], sessionTitle: session, stats: stats, aspect: 0.56)
    }

    func testSuggestedTagsFromWhatYouLogged() {
        let pr = ClipFeedPostStats(line: "1 × 8 @ 75 kg", isPR: true, activityKey: key, activityTitle: "Bench Press")
        XCTAssertEqual(ClipCaption.suggestions(post: post(stats: pr), text: ""), ["PR", "pushday", "benchpress"])
        XCTAssertEqual(ClipCaption.suggestions(post: post(stats: pr), text: "felt good #pushday"), ["PR", "benchpress"],
                       "a tag already written isn't offered again")
    }

    func testCaptionsAreSearchable() {
        let p = post(stats: nil)
        let search = ClipSearch(query: "grind")
        XCTAssertFalse(search.matches(p))
        XCTAssertTrue(search.matches(p, caption: "Last rep was a grind"))
        XCTAssertTrue(ClipSearch(query: "pushday").matches(p, caption: "#pushday"))
    }

    func testStatsReachThePostAndCountPerActivity() {
        let ex = UUID()
        let meta = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Push Day", startedAt: start, angle: nil)
        let stats = ClipFeedPostStats(line: "1 × 8 @ 75 kg", activityKey: key, activityTitle: "Bench Press")
        func clip(_ o: Double, set: Int) -> MediaInput {
            MediaInput(id: UUID(), kind: "video", offsetSec: o, durationSec: 6, exerciseId: ex, setIndex: set,
                       climbUUID: nil, localIdentifier: "a\(o)", aspect: nil)
        }
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: meta, clips: [clip(5, set: 0), clip(60, set: 1)],
                             exerciseStats: [ex.uuidString: stats])],
            climbMeta: [:], exerciseName: { _ in "Bench Press" })
        XCTAssertEqual(posts.first?.stats, stats, "threaded through the dedupe and onto the post")
        XCTAssertEqual(ClipFeedComposer.activityClipCounts(posts)[key], 2)
    }
}
