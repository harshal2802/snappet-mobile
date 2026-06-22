import XCTest
@testable import Snappet

/// F6: eligibility for the cross-session insight cards (pure) + degrade-by-absence.
final class F6InsightCardEligibilityTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }()
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day, hour: 12))! }
    private func send(_ uuid: String, _ grade: String, _ diff: Double, angle: Int = 40, _ date: Date) -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: grade, difficulty: diff,
                       status: .sent, attempts: 1, startedAt: date, endedAt: date, loggedAt: date, angle: angle, sessionId: UUID())
    }
    private func insights(_ logs: [KilterClimbLog], now: Date) -> [FeedCard] {
        let all = KilterAllTimeStats.make(logs: logs, sessions: [], now: now, calendar: cal)
        return FeedInsightCards.cards(allTime: all, logs: logs, now: now, calendar: cal, anchor: now)
    }

    func testEmptyYieldsNoInsightCards() {
        XCTAssertTrue(FeedInsightCards.cards(allTime: .empty, logs: [], now: d(2026, 6, 20), calendar: cal, anchor: d(2026, 6, 20)).isEmpty)
    }

    func testPyramidHealthFlagsTopHeavyGrade() {
        // V3:1, V4:3, V5:1 → V3 narrower than V4 above it → consolidate V3.
        let now = d(2026, 6, 20)
        var logs = [send("a", "V3", 10, now)]
        logs += (0..<3).map { send("b\($0)", "V4", 13, d(2026, 6, 18)) }
        logs.append(send("c", "V5", 16, d(2026, 6, 17)))
        let c2 = insights(logs, now: now).first { $0.kind == .c2PyramidHealth }
        XCTAssertNotNil(c2)
        if case .pyramidHealth(let p)? = c2?.payload { XCTAssertEqual(p.consolidateGrade, "V3") } else { XCTFail() }
    }

    func testAngleDistributionNeedsTwoAngles() {
        let now = d(2026, 6, 20)
        let oneAngle = [send("a", "V4", 13, angle: 40, now), send("b", "V5", 16, angle: 40, now)]
        XCTAssertNil(insights(oneAngle, now: now).first { $0.kind == .c5AngleDist })
        let twoAngles = oneAngle + [send("c", "V4", 13, angle: 45, now)]
        XCTAssertNotNil(insights(twoAngles, now: now).first { $0.kind == .c5AngleDist })
    }

    func testConsistencyNeeds14ActiveDays() {
        let now = d(2026, 6, 28)
        func days(_ n: Int) -> [KilterClimbLog] { (0..<n).map { send("d\($0)", "V4", 13, d(2026, 6, 28 - $0)) } }
        XCTAssertNil(insights(days(13), now: now).first { $0.kind == .consistencyMap })
        let c = insights(days(14), now: now).first { $0.kind == .consistencyMap }
        XCTAssertNotNil(c)
        if case .consistency(let p)? = c?.payload { XCTAssertEqual(p.activeDays, 14) } else { XCTFail() }
    }

    func testOnThisDaySurfacesPriorYearSend() {
        let now = d(2026, 6, 20)
        let logs = [send("today", "V6", 19, now), send("memory", "V4", 13, d(2025, 6, 20))]
        let card = insights(logs, now: now).first { $0.kind == .onThisDay }
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.anchorDate, now, "memory anchors to now (recency)")
        if case .onThisDay(let p)? = card?.payload { XCTAssertEqual(p.yearsAgo, 1); XCTAssertEqual(p.grade, "V4") } else { XCTFail() }
        // No prior-year send on this date → no card.
        XCTAssertNil(insights([send("t", "V6", 19, now)], now: now).first { $0.kind == .onThisDay })
    }

    func testRichCorpusTriggersTrendCards() {
        // 21 sends across 3 months → climbing level (>=20), progression (>=3 months), period-vs-last.
        let now = d(2026, 6, 20)
        var logs: [KilterClimbLog] = []
        for (mi, month) in [4, 5, 6].enumerated() {
            for i in 0..<7 { logs.append(send("g\(mi)-\(i)", ["V3", "V4", "V5"][i % 3], [10.0, 13, 16][i % 3], d(2026, month, 1 + i))) }
        }
        let kinds = Set(insights(logs, now: now).map(\.kind))
        XCTAssertTrue(kinds.contains(.c4ClimbingLevel), "21 sends → climbing level")
        XCTAssertTrue(kinds.contains(.c3Progression), ">=3 months → progression")
        XCTAssertTrue(kinds.contains(.d2PeriodVsLast), ">=2 months → period vs last")
    }
}
