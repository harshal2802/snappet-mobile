import XCTest
@testable import Snappet

/// Sessions · Activities · Exercises (prompt 197).
final class ClipFeedLevelsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let benchKey = ActivityKey(exerciseId: "bench", nameKey: "")

    private func item(_ offset: Double, label: String?, kind: String = "video") -> ClipFeedItem {
        ClipFeedItem(media: MediaInput(id: UUID(), kind: kind, offsetSec: offset, durationSec: 5, exerciseId: nil,
                                       setIndex: nil, climbUUID: nil, localIdentifier: "a\(offset)-\(UUID())", aspect: nil),
                     attemptLabel: label)
    }

    private func post(_ title: String, session: UUID, start: Date, clips: [ClipFeedItem], stats: ClipFeedPostStats? = nil,
                      climb: String? = nil, result: ClipFeedClimbResult? = nil, reel: Bool = false) -> ClipFeedPost {
        ClipFeedPost(id: "\(title)@\(session)", sessionID: session, kind: .gym, moduleID: "workout-log",
                     discipline: .strength, title: title, subtitle: "Push Day", overlayDetail: "", climbUUID: climb,
                     exerciseID: stats == nil ? nil : UUID(), captureAt: start, sessionStartedAt: start,
                     sessionEndedAt: start.addingTimeInterval(52 * 60), isFromAppleWatch: false, isReel: reel,
                     clips: clips, climbResult: result, sessionTitle: "Push Day", sessionActivity: .strength, stats: stats,
                     aspect: 0.56)
    }

    private func stats(_ line: String, sets: Int, pr: Bool = false, key: ActivityKey? = nil, best: Double? = nil) -> ClipFeedPostStats {
        ClipFeedPostStats(line: line, isPR: pr, setDetail: Dictionary(uniqueKeysWithValues: (0..<sets).map { ($0, "s") }),
                          activityKey: key, activityTitle: "Bench Press", bestKg: best)
    }

    func testASessionBecomesOnePostWithEveryClipInOrder() throws {
        let s = UUID()
        let bench = post("Bench Press", session: s, start: t0, clips: [item(100, label: "Set 1"), item(400, label: "Set 3")],
                         stats: stats("3 × 8 @ 75 kg", sets: 3, pr: true))
        let fly = post("Cable Fly", session: s, start: t0, clips: [item(250, label: "Set 2")], stats: stats("2 × 12", sets: 2))
        let merged = ClipFeedLevels.sessions([bench, fly])
        XCTAssertEqual(merged.count, 1)
        let p = try XCTUnwrap(merged.first)
        XCTAssertEqual(p.id, "session@\(s.uuidString)", "its own id — its own caption")
        XCTAssertEqual(p.level, .sessions)
        XCTAssertEqual(p.title, "Push Day")
        XCTAssertEqual(p.clips.map(\.attemptLabel), ["Bench Press · Set 1", "Cable Fly · Set 2", "Bench Press · Set 3"])
        XCTAssertEqual(p.activityChips, [.init(title: "Bench Press", firstPage: 0, count: 2),
                                         .init(title: "Cable Fly", firstPage: 1, count: 1)])
        XCTAssertEqual(p.stats?.line, "5 sets · 2 exercises")
        XCTAssertEqual(ClipPostStats.prText(p.stats!), "▲ PR")
        XCTAssertTrue(p.subtitle.contains("52 min"), p.subtitle)
    }

    func testSessionsKeepFeedOrderAndReels() {
        let a = UUID(), b = UUID()
        let newer = post("Bench Press", session: a, start: t0.addingTimeInterval(86_400), clips: [item(1, label: "Set 1")],
                         stats: stats("1 × 8", sets: 1))
        let reel = post("Highlights", session: a, start: t0.addingTimeInterval(86_400), clips: [item(2, label: nil)], reel: true)
        let older = post("Squat", session: b, start: t0, clips: [item(1, label: "Set 1")], stats: stats("1 × 5", sets: 1))
        let out = ClipFeedLevels.sessions([newer, reel, older])
        XCTAssertEqual(out.map(\.isReel), [false, true, false])
        XCTAssertEqual(out.map(\.sessionID), [a, a, b])
    }

    func testAlbumsFoldSessionsOfAnActivity() throws {
        let first = post("Bench Press", session: UUID(), start: t0, clips: [item(1, label: "Set 1")],
                         stats: stats("1 × 8 @ 60 kg", sets: 1, key: benchKey, best: 76))
        let latest = post("Bench Press", session: UUID(), start: t0.addingTimeInterval(63 * 86_400),
                          clips: [item(1, label: "Set 1"), item(9, label: "Set 2")],
                          stats: stats("2 × 8 @ 75 kg", sets: 2, key: benchKey, best: 95))
        let untagged = post("Session clips", session: UUID(), start: t0, clips: [item(1, label: nil)])
        let albums = ClipFeedLevels.albums([latest, untagged, first])
        XCTAssertEqual(albums.count, 1, "only activities with an identity")
        let album = try XCTUnwrap(albums.first)
        XCTAssertEqual(album.posts.map(\.sessionStartedAt), [t0, t0.addingTimeInterval(63 * 86_400)], "oldest → newest")
        XCTAssertEqual(album.clipCount, 3)
        XCTAssertEqual(album.sessionCount, 2)
        XCTAssertEqual(ClipFeedLevels.gain(album, unit: .kg), "est. 1RM +19 kg in 9 weeks")
    }

    func testAClimbAlbumShowsHowItWent() throws {
        let uuid = "c1"
        let project = post("Spicy Pringle", session: UUID(), start: t0, clips: [item(1, label: "Attempt 1")], climb: uuid,
                           result: ClipFeedClimbResult(status: .project, attempts: 5))
        let sent = post("Spicy Pringle", session: UUID(), start: t0.addingTimeInterval(5 * 86_400), clips: [item(1, label: "Attempt 1")],
                        climb: uuid, result: ClipFeedClimbResult(status: .sent, attempts: 3))
        let album = try XCTUnwrap(ClipFeedLevels.albums([sent, project]).first)
        XCTAssertEqual(album.key, ActivityKey(exerciseId: LibraryCatalog.kilterExerciseId, nameKey: uuid))
        XCTAssertEqual(ClipFeedLevels.gain(album, unit: .kg), "Project → Sent")
    }

    func testPRCounts() {
        let two = ClipFeedPostStats(line: "x", activityKey: nil, activityTitle: "", prCount: 2)
        XCTAssertEqual(ClipPostStats.prText(two), "▲ 2 PRs")
        XCTAssertNil(ClipPostStats.prText(ClipFeedPostStats(line: "x", activityKey: nil, activityTitle: "")))
    }
}
