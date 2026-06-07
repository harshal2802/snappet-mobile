import XCTest
@testable import Snappet

/// Unit tests for the **pure** Kilter session statistics — no SwiftData, no device. Synthetic
/// `KilterClimbLog`s feed `KilterSessionStats.make`, which the summary view renders verbatim.
final class KilterSessionStatsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    /// A: sent (6a/V3) 0–60s, B: 3 attempts (6b/V4) 120–180s, C: flash (6c/V5) 200–260s; session 0–300s.
    private func sampleLogs() -> [KilterClimbLog] {
        [
            KilterClimbLog(climbUUID: "A", climbName: "Alpha", gradeLabel: "6a/V3", difficulty: 15,
                           status: .sent, attempts: 1,
                           startedAt: t0, endedAt: t0.addingTimeInterval(60), loggedAt: t0.addingTimeInterval(60)),
            KilterClimbLog(climbUUID: "B", climbName: "Bravo", gradeLabel: "6b/V4", difficulty: 18,
                           status: .attempt, attempts: 3,
                           startedAt: t0.addingTimeInterval(120), endedAt: t0.addingTimeInterval(180),
                           loggedAt: t0.addingTimeInterval(180)),
            KilterClimbLog(climbUUID: "C", climbName: "Charlie", gradeLabel: "6c/V5", difficulty: 20,
                           status: .flash, attempts: 1,
                           startedAt: t0.addingTimeInterval(200), endedAt: t0.addingTimeInterval(260),
                           loggedAt: t0.addingTimeInterval(260)),
        ]
    }

    func testCounts() {
        let s = KilterSessionStats.make(from: sampleLogs(), start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(s.totalClimbs, 3)
        XCTAssertEqual(s.sends, 2)        // A sent + C flash
        XCTAssertEqual(s.projects, 0)
        XCTAssertEqual(s.attemptsOnly, 1) // B (still in attempt state)
        XCTAssertEqual(s.totalAttempts, 5) // A:1 + B:3 + C:1
        XCTAssertEqual(s.totalDuration, 300)
    }

    /// A climb worked across several attempts then sent collapses to ONE entry (status sent,
    /// attempts = total tries) — it must count once as a climb/send, with the tries in totalAttempts.
    func testWorkedThenSentClimbCountsOnce() {
        let log = KilterClimbLog(climbUUID: "A", climbName: "Alpha", gradeLabel: "6c/V5", difficulty: 20,
                                 status: .sent, attempts: 4,
                                 startedAt: t0, endedAt: t0.addingTimeInterval(180),
                                 loggedAt: t0.addingTimeInterval(180))
        let s = KilterSessionStats.make(from: [log], start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(s.totalClimbs, 1)
        XCTAssertEqual(s.sends, 1)
        XCTAssertEqual(s.attemptsOnly, 0)   // it WAS sent, so it isn't "left as an attempt"
        XCTAssertEqual(s.totalAttempts, 4)  // but it took 4 tries
        XCTAssertEqual(s.timeline.first?.attempts, 4)
        XCTAssertEqual(s.hardestSendGrade, "6c/V5")
    }

    func testHardestSend() {
        let s = KilterSessionStats.make(from: sampleLogs(), start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(s.hardestSendDifficulty, 20)
        XCTAssertEqual(s.hardestSendGrade, "6c/V5")
    }

    func testSendsPerHour() {
        let s = KilterSessionStats.make(from: sampleLogs(), start: t0, end: t0.addingTimeInterval(300))
        // 2 sends over 300s = 2 / (300/3600) = 24 sends/hr.
        XCTAssertEqual(s.sendsPerHour, 24, accuracy: 0.001)
    }

    func testPyramidOrderedEasiestToHardest() {
        let s = KilterSessionStats.make(from: sampleLogs(), start: t0, end: t0.addingTimeInterval(300))
        // Only sends count toward the pyramid: 6a/V3 (diff 15) then 6c/V5 (diff 20).
        XCTAssertEqual(s.pyramid.map(\.gradeLabel), ["6a/V3", "6c/V5"])
        XCTAssertEqual(s.pyramid.map(\.sends), [1, 1])
    }

    func testTimelineRestAndTime() {
        let s = KilterSessionStats.make(from: sampleLogs(), start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(s.timeline.count, 3)
        XCTAssertNil(s.timeline[0].restBefore)                 // first climb
        XCTAssertEqual(s.timeline[1].restBefore, 60)           // B.start(120) − A.end(60)
        XCTAssertEqual(s.timeline[2].restBefore, 20)           // C.start(200) − B.end(180)
        XCTAssertEqual(s.timeline.map { $0.timeOnClimb }, [60, 60, 60])
        XCTAssertEqual(s.timeline[1].attempts, 3)
    }

    func testMedianTimeOnClimb() {
        let s = KilterSessionStats.make(from: sampleLogs(), start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(s.medianTimeOnClimb, 60)
    }

    func testEmptySessionIsZeroed() {
        let s = KilterSessionStats.make(from: [], start: t0, end: t0.addingTimeInterval(120))
        XCTAssertEqual(s.totalClimbs, 0)
        XCTAssertEqual(s.sends, 0)
        XCTAssertNil(s.hardestSendDifficulty)
        XCTAssertEqual(s.sendsPerHour, 0)
        XCTAssertTrue(s.pyramid.isEmpty)
        XCTAssertTrue(s.timeline.isEmpty)
        XCTAssertNil(s.medianTimeOnClimb)
    }

    func testTimeOnClimbNilWithoutStart() {
        // A log with no startedAt (an ad-hoc log) contributes no time-on-climb.
        let log = KilterClimbLog(climbUUID: "X", climbName: "X", gradeLabel: "6a/V3", difficulty: 15,
                                 status: .sent, attempts: 1, startedAt: nil, endedAt: nil, loggedAt: t0)
        let s = KilterSessionStats.make(from: [log], start: t0, end: t0.addingTimeInterval(60))
        XCTAssertNil(s.timeline[0].timeOnClimb)
        XCTAssertNil(s.medianTimeOnClimb)
    }
}
