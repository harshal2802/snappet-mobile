import XCTest
@testable import Snappet

/// Kilter board climbs in Yours (Library redesign L4c, prompt 188).
final class LibraryKilterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func log(_ status: KilterAscentStatus, uuid: String = "c1", name: String = "Spicy Pringle", angle: Int = 40,
                     grade: String = "6c/V5", attempts: Int = 1, daysAgo: Double,
                     session: UUID? = UUID()) -> LibraryCatalog.KilterInput {
        .init(uuid: uuid, name: name, angle: angle, gradeLabel: grade, status: status, attempts: attempts,
              date: now.addingTimeInterval(-daysAgo * 86_400), sessionId: session)
    }

    func testOneRowPerBoardClimbWithItsBestOutcomeAndAttempts() throws {
        let rows = LibraryCatalog.kilterRows([
            log(.attempt, attempts: 5, daysAgo: 20), log(.project, attempts: 4, daysAgo: 9),
            log(.sent, attempts: 3, daysAgo: 2), log(.flash, uuid: "c2", name: "Other", grade: "6a/V3", daysAgo: 1),
        ], now: now)
        XCTAssertEqual(rows.count, 2)
        let r = try XCTUnwrap(rows.first { $0.title == "Spicy Pringle" })
        XCTAssertTrue(LibraryCatalog.isKilter(r.key))
        XCTAssertEqual(r.climb?.grade, "V5")
        XCTAssertEqual(r.climb?.status, .sent)
        XCTAssertEqual(r.climb?.attempts, 12)
        XCTAssertEqual(r.climb?.angle, 40)
        XCTAssertEqual(r.sessions, 3)
        XCTAssertEqual(r.days, 3)
        XCTAssertEqual(r.discipline, .climb)
    }

    func testTheLatestAngleAndGradeWin() throws {
        let r = try XCTUnwrap(LibraryCatalog.kilterRows([
            log(.attempt, angle: 30, grade: "6b/V4", daysAgo: 10), log(.attempt, angle: 45, grade: "7a/V6", daysAgo: 1),
        ], now: now).first)
        XCTAssertEqual(r.climb?.angle, 45)
        XCTAssertEqual(r.climb?.grade, "V6")
    }

    func testAdHocLogsCountBySessionDay() throws {
        let r = try XCTUnwrap(LibraryCatalog.kilterRows([
            log(.attempt, daysAgo: 3, session: nil), log(.attempt, daysAgo: 3, session: nil),
            log(.sent, daysAgo: 1, session: nil),
        ], now: now).first)
        XCTAssertEqual(r.sessions, 2, "two ad-hoc logs on one day are one session")
    }

    func testBoardClimbsSortByGradeWithGymClimbs() {
        let board = LibraryCatalog.kilterRows([log(.sent, daysAgo: 1)], now: now)[0]   // V5
        XCTAssertEqual(board.bestValue, GradeScale.vScale.difficulty(for: "V5"))
        XCTAssertEqual(LibraryCatalog.kilterVGrade("6b+/V4"), "V4")
        XCTAssertEqual(LibraryCatalog.kilterVGrade("V7"), "V7")
        XCTAssertEqual(LibraryCatalog.kilterVGrade("7a"), "7a")
    }

    func testBoardClimbsAreNotLaunchableOrOfferedByPickers() {
        let rows = LibraryCatalog.kilterRows([log(.sent, daysAgo: 1)], now: now)
        XCTAssertFalse(ActivityLauncher.canLaunch(rows[0].key))
        XCTAssertTrue(LibraryPick.rows(rows, hidden: [], query: "", discipline: nil).isEmpty)
    }

    func testProjectsAndSentFiltersSeeBoardClimbs() {
        let rows = LibraryCatalog.kilterRows([log(.project, daysAgo: 1), log(.sent, uuid: "c2", daysAgo: 1)], now: now)
        XCTAssertEqual(LibraryCatalog.filter(rows, query: "", discipline: .climb, climbFilter: .projects).count, 1)
        XCTAssertEqual(LibraryCatalog.filter(rows, query: "", discipline: .climb, climbFilter: .sent).count, 1)
    }

    // MARK: - Every clip of a board climb

    private func clip(_ session: UUID, climb: String? = "c1", offset: Double = 100, reel: Bool = false) -> ActivityMediaInput {
        ActivityMediaInput(id: UUID(), sessionID: session, assignedExerciseID: nil, assignedSetIndex: nil,
                           kindRaw: "video", offsetSec: offset, durationSec: 10, localIdentifier: UUID().uuidString,
                           isReel: reel, assignedClimbUUID: climb)
    }

    func testClipsOfABoardClimbGroupByBoardSessionNewestFirstWithHowItWent() throws {
        let old = UUID(), new = UUID()
        let sessions = [
            KilterClipIndex.SessionInput(id: old, startedAt: now.addingTimeInterval(-9 * 86_400), title: nil,
                                         hrSeries: [HRPoint(t: 100, bpm: 150), HRPoint(t: 110, bpm: 160)]),
            KilterClipIndex.SessionInput(id: new, startedAt: now.addingTimeInterval(-86_400), title: "Tuesday board",
                                         hrSeries: []),
        ]
        let media = [clip(old), clip(new, offset: 300), clip(new, offset: 50),
                     clip(new, climb: "other"), clip(new, reel: true), clip(UUID())]   // other climb · reel · unknown session
        let logs = [log(.attempt, attempts: 4, daysAgo: 9, session: old), log(.sent, daysAgo: 1, session: new),
                    log(.project, daysAgo: 1, session: new)]
        let groups = KilterClipIndex.groups(climbUUID: "c1", media: media, sessions: sessions, logs: logs)
        XCTAssertEqual(groups.map(\.sessionID), [new, old])
        XCTAssertEqual(groups[0].title, "Tuesday board · 40°")
        XCTAssertEqual(groups[1].title, "Kilter session · 40°")
        XCTAssertEqual(groups[0].clips.count, 2)
        XCTAssertEqual(groups[0].clips.map(\.media.offsetSec), [50, 300], "in filming order")
        XCTAssertEqual(groups[0].clips[0].setSummary, "V5 · Sent", "the session's best outcome on the climb")
        XCTAssertEqual(groups[1].clips[0].setSummary, "V5 · Attempt")
        XCTAssertNotNil(groups[1].clips[0].avgBPM, "the board session's heart rate")
    }
}
