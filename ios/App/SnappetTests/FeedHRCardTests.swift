import XCTest
@testable import Snappet

/// F2: the e1/e2/e3 HR card recipes — eligibility gating + payload correctness (pure, no device).
final class FeedHRCardTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func gaussianHR(peakAt: Double, span: Double = 300) -> [HRPoint] {
        stride(from: 0.0, through: span, by: 1).map { t in
            HRPoint(t: t, bpm: 100 + 75 * exp(-pow(t - peakAt, 2) / (2 * 30 * 30)))
        }
    }

    private func send(_ uuid: String, _ grade: String, _ diff: Double, startOffset: Double, dur: Double, session: UUID) -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: grade, difficulty: diff,
                       status: .sent, attempts: 1, startedAt: t0.addingTimeInterval(startOffset),
                       endedAt: t0.addingTimeInterval(startOffset + dur),
                       loggedAt: t0.addingTimeInterval(startOffset + dur), angle: 40, sessionId: session)
    }

    func testE1ComposesWithHR() {
        let s = KilterSessionInput(id: UUID(), startedAt: t0, endedAt: t0.addingTimeInterval(300), angle: 40,
                                   hrSeries: gaussianHR(peakAt: 150), maxHR: 190, restHR: 60)
        let e1 = FeedHRCards.cards(sessions: [s], logs: []).first { $0.kind == .e1Effort }
        XCTAssertNotNil(e1)
        if case .effort(let p)? = e1?.payload {
            XCTAssertFalse(p.zones.isEmpty)
            XCTAssertGreaterThan(p.maxBpm, p.avgBpm)
            XCTAssertGreaterThan(p.trimp, 0)
        } else { XCTFail("expected an effort payload") }
    }

    func testE1GatedWhenNoHR() {
        let s = KilterSessionInput(id: UUID(), startedAt: t0, endedAt: t0.addingTimeInterval(300), angle: 40)
        XCTAssertTrue(FeedHRCards.cards(sessions: [s], logs: []).isEmpty, "no HR → no e1/e2 (no empty chart)")
    }

    func testE2PicksHardestEffortSend() {
        let id = UUID()
        let logs = [send("A", "V5", 16, startOffset: 10, dur: 30, session: id),
                    send("B", "V6", 19, startOffset: 100, dur: 40, session: id)]
        let s = KilterSessionInput(id: id, startedAt: t0, endedAt: t0.addingTimeInterval(300), angle: 40,
                                   hrSeries: gaussianHR(peakAt: 120), maxHR: 190, restHR: 60)
        let e2 = FeedHRCards.cards(sessions: [s], logs: logs).first { $0.kind == .e2HardestEffort }
        XCTAssertNotNil(e2)
        if case .hardestEffort(let p)? = e2?.payload {
            XCTAssertEqual(p.grade, "V6", "the send aligned to the HR peak is the V6")
            XCTAssertGreaterThan(p.peakBpm, 140)
        } else { XCTFail("expected a hardestEffort payload") }
    }

    func testE3NeedsThreeHRSessions() {
        func hrSession() -> KilterSessionInput {
            KilterSessionInput(id: UUID(), startedAt: t0, endedAt: t0.addingTimeInterval(300), angle: 40,
                               hrSeries: gaussianHR(peakAt: 150), maxHR: 190)
        }
        XCTAssertTrue(FeedHRCards.trend(sessions: [hrSession(), hrSession()]).isEmpty)
        let three = FeedHRCards.trend(sessions: [hrSession(), hrSession(), hrSession()])
        XCTAssertEqual(three.count, 1)
        if case .hrTrend(let p)? = three.first?.payload { XCTAssertEqual(p.points.count, 3) } else { XCTFail() }
    }
}
