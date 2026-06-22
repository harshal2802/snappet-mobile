import XCTest
@testable import Snappet

/// Pure tests for the F6 follow-on project/grade milestone recipes (b2 firstAtGrade, g1 projectSent).
/// All fixtures are deterministic `KilterClimbLog`s — no SwiftData, no device.
final class FeedProjectCardsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000) // far future anchor

    private func log(_ uuid: String, _ name: String, _ grade: String, _ diff: Double,
                     _ status: KilterAscentStatus, _ at: Date, session: UUID? = nil) -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: name, gradeLabel: grade, difficulty: diff,
                       status: status, attempts: 1, startedAt: nil, endedAt: nil, loggedAt: at,
                       angle: 40, sessionId: session)
    }

    private func cards(_ logs: [KilterClimbLog]) -> [FeedCard] {
        FeedProjectCards.cards(logs: logs, now: now, calendar: cal, anchor: now)
    }

    // MARK: b2 — first at grade (backfill only)

    func testB2_FiresOncePerBackfilledGradeBand() {
        // First send V5 (the PR / all-time max — NOT a b2). Then backfill V3 and V4 (both easier).
        let logs = [
            log("c-v5", "Hard One", "V5", 5.0, .sent, date(2026, 1, 1)),
            log("c-v3", "Easy One", "V3", 3.0, .sent, date(2026, 1, 2)),
            log("c-v4", "Mid One", "V4", 4.0, .flash, date(2026, 1, 3)),
        ]
        let b2 = cards(logs).filter { $0.kind == .b2FirstAtGrade }
        // V5 skipped (it's the all-time max at its time → b1). V3 and V4 each fire once.
        XCTAssertEqual(b2.count, 2)
        let grades = b2.compactMap { c -> String? in
            if case .firstAtGrade(let p) = c.payload { return p.grade }; return nil
        }
        XCTAssertEqual(Set(grades), ["V3", "V4"])
        // Each is a milestone, salience 0.60, with the per-climb contentId.
        for c in b2 {
            XCTAssertEqual(c.category, .milestone)
            XCTAssertEqual(c.salience, 0.60, accuracy: 1e-9)
        }
        let v3 = b2.first { if case .firstAtGrade(let p) = $0.payload { return p.grade == "V3" }; return false }!
        XCTAssertEqual(v3.contentId, FeedContentIdentity.climb(uuid: "c-v3"))
        XCTAssertEqual(v3.anchorDate, date(2026, 1, 2))
    }

    func testB2_FiresOnlyOncePerGradeEvenWithRepeatSends() {
        // V5 PR first. Then two V3 sends — only the first V3 should fire b2.
        let logs = [
            log("c-v5", "Hard", "V5", 5.0, .sent, date(2026, 1, 1)),
            log("c-v3a", "Easy A", "V3", 3.0, .sent, date(2026, 1, 2)),
            log("c-v3b", "Easy B", "V3", 3.0, .sent, date(2026, 1, 5)),
        ]
        let b2 = cards(logs).filter { $0.kind == .b2FirstAtGrade }
        XCTAssertEqual(b2.count, 1)
        XCTAssertEqual(b2.first?.contentId, FeedContentIdentity.climb(uuid: "c-v3a"))
    }

    func testB2_DoesNotFireWhenEveryGradeIsAPR() {
        // Strictly ascending sends — every grade is the all-time max at its time → all b1, no b2.
        let logs = [
            log("c-v3", "A", "V3", 3.0, .sent, date(2026, 1, 1)),
            log("c-v4", "B", "V4", 4.0, .sent, date(2026, 1, 2)),
            log("c-v5", "C", "V5", 5.0, .flash, date(2026, 1, 3)),
        ]
        XCTAssertTrue(cards(logs).filter { $0.kind == .b2FirstAtGrade }.isEmpty)
    }

    func testB2_EmptyAndAttemptsOnlyProduceNothing() {
        XCTAssertTrue(cards([]).filter { $0.kind == .b2FirstAtGrade }.isEmpty)
        let attempts = [
            log("c-v3", "A", "V3", 3.0, .attempt, date(2026, 1, 1)),
            log("c-v4", "B", "V4", 4.0, .project, date(2026, 1, 2)),
        ]
        XCTAssertTrue(cards(attempts).filter { $0.kind == .b2FirstAtGrade }.isEmpty)
    }

    // MARK: g1 — project → sent

    func testG1_FiresOnProjectThenSendWithSessionCount() {
        let s1 = UUID(), s2 = UUID()
        // Worked as a project in two distinct sessions, then sent in a third.
        let logs = [
            log("proj-1", "Nemesis", "V6", 6.0, .project, date(2026, 2, 1), session: s1),
            log("proj-1", "Nemesis", "V6", 6.0, .project, date(2026, 2, 8), session: s2),
            log("proj-1", "Nemesis", "V6", 6.0, .sent,    date(2026, 2, 15)),
        ]
        let g1 = cards(logs).filter { $0.kind == .g1ProjectSent }
        XCTAssertEqual(g1.count, 1)
        let card = g1[0]
        guard case .projectSent(let p) = card.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(p.grade, "V6")
        XCTAssertEqual(p.climbName, "Nemesis")
        XCTAssertEqual(p.sessions, 2)
        XCTAssertEqual(card.category, .milestone)
        XCTAssertEqual(card.salience, 0.85, accuracy: 1e-9)
        XCTAssertEqual(card.contentId, FeedContentIdentity.climb(uuid: "proj-1"))
        XCTAssertEqual(card.anchorDate, date(2026, 2, 15))
    }

    func testG1_DoesNotFireWithoutAnEarlierProject() {
        // A plain send with no prior project log — not a project-sent story.
        let logs = [log("flash-1", "Quickie", "V4", 4.0, .flash, date(2026, 2, 1))]
        XCTAssertTrue(cards(logs).filter { $0.kind == .g1ProjectSent }.isEmpty)
    }

    func testG1_DoesNotFireWhenProjectIsAfterTheSend() {
        // Sent first, then logged as a project later (e.g. re-working it) — no project→send transition.
        let logs = [
            log("c-1", "X", "V5", 5.0, .sent,    date(2026, 2, 1)),
            log("c-1", "X", "V5", 5.0, .project, date(2026, 2, 8)),
        ]
        XCTAssertTrue(cards(logs).filter { $0.kind == .g1ProjectSent }.isEmpty)
    }

    func testG1_EmptyProducesNothing() {
        XCTAssertTrue(cards([]).filter { $0.kind == .g1ProjectSent }.isEmpty)
    }

    func testRecencyAnchorNeverInFuture() {
        // A send logged "after now" must be clamped so a card never out-floats the clock.
        let future = now.addingTimeInterval(86_400)
        let logs = [
            log("c-v5", "Hard", "V5", 5.0, .sent, date(2026, 1, 1)),
            log("c-v3", "Easy", "V3", 3.0, .sent, future),
        ]
        let b2 = cards(logs).filter { $0.kind == .b2FirstAtGrade }
        XCTAssertEqual(b2.count, 1)
        XCTAssertLessThanOrEqual(b2[0].anchorDate, now)
    }
}
