import XCTest
@testable import Snappet

/// Unit tests for the **pure** Recap FeedComposer keystone — no SwiftData, no device.
/// Includes the cross-platform GOLDEN CORPUS that FA0 (Kotlin) replays verbatim.
final class FeedComposerTests: XCTestCase {

    // Deterministic UTC calendar so streak/window math is machine-independent.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }

    private func climb(_ uuid: String, _ grade: String, _ diff: Double, _ status: KilterAscentStatus,
                       _ at: Date, _ session: UUID?) -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: grade, difficulty: diff,
                       status: status, attempts: status.isSend ? 1 : 3,
                       startedAt: at, endedAt: at.addingTimeInterval(60),
                       loggedAt: at.addingTimeInterval(60), angle: 40, sessionId: session)
    }

    private func summary(_ id: UUID, _ start: Date, _ end: Date?) -> KilterSessionSummary {
        KilterSessionSummary(id: id, startedAt: start, endedAt: end, angle: 40)
    }

    private func allTime(_ logs: [KilterClimbLog], _ sessions: [KilterSessionSummary], now: Date) -> KilterAllTimeStats {
        KilterAllTimeStats.make(logs: logs, sessions: sessions, now: now, calendar: cal)
    }

    // MARK: - Golden corpus (shared with FA0)

    /// A fixed corpus → an exact ordered list of FeedCardKinds + salience tiers.
    func testGoldenCorpus() {
        let now = d(2026, 6, 20, 18)
        let u1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let u2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let u3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        let s1 = KilterSessionInput(id: u1, startedAt: d(2026,6,20,10), endedAt: d(2026,6,20,11), angle: 40, title: "Today")
        let s2 = KilterSessionInput(id: u2, startedAt: d(2026,6,19,10), endedAt: d(2026,6,19,11), angle: 40)
        let s3 = KilterSessionInput(id: u3, startedAt: d(2026,6,18,10), endedAt: d(2026,6,18,11), angle: 40)

        let logs: [KilterClimbLog] = [
            // S3 (06-18): establishing V6 PR, then V5
            climb("F", "V6", 19, .sent, d(2026,6,18,10,20), u3),
            climb("G", "V5", 16, .sent, d(2026,6,18,10,40), u3),
            // S2 (06-19): no new PR
            climb("D", "V6", 19, .sent, d(2026,6,19,10,20), u2),
            climb("E", "V5", 16, .sent, d(2026,6,19,10,40), u2),
            // S1 (06-20): V6, V5, then V7 PR  → 3 climbs (most-climbs record)
            climb("A", "V6", 19, .sent, d(2026,6,20,10,10), u1),
            climb("B", "V5", 16, .sent, d(2026,6,20,10,30), u1),
            climb("C", "V7", 22, .sent, d(2026,6,20,10,50), u1),
        ]
        let summaries = [summary(u1, s1.startedAt, s1.endedAt), summary(u2, s2.startedAt, s2.endedAt), summary(u3, s3.startedAt, s3.endedAt)]

        let cards = FeedComposer.compose(
            window: .allTime, kilterSessions: [s1, s2, s3], kilterLogs: logs,
            allTimeStats: allTime(logs, summaries, now: now), now: now, calendar: cal)

        XCTAssertEqual(cards.map(\.kind), [
            .b1GradePR,      // today's V7 (highest, fresh)
            .b3MostClimbs,   // today's 3-climb record
            .b5Streak,       // 3-day streak (06-18/19/20)
            .b1GradePR,      // the establishing V6 PR (2 days old, still high salience)
            .a1Session,      // today
            .a1Session,      // yesterday
            .a1Session,      // 06-18
        ], "golden ordered kinds")

        XCTAssertEqual(cards.map(\.salience), [1.0, 0.9, 0.8, 1.0, 0.45, 0.45, 0.45], "golden salience tiers")

        // contentId is the cross-platform reaction/dedup key: concrete-source cards carry a UUIDv5
        // identity; genuine aggregates are empty. (Guards H1/H2 — reactions silently no-op without it.)
        for c in cards where c.kind == .b1GradePR { XCTAssertFalse(c.contentId.isEmpty, "a PR card must carry a contentId") }
        XCTAssertEqual(cards.first { $0.kind == .a1Session }?.contentId,
                       FeedContentIdentity.kilterSession(id: u1.uuidString), "session card contentId")
        XCTAssertEqual(cards.first { $0.kind == .b5Streak }?.contentId, "", "aggregate cards carry no contentId")

        // exactly two PRs (the establishing V6 + the V7), no pyramid/volume (only 6 sends, one week)
        XCTAssertEqual(cards.filter { $0.kind == .b1GradePR }.count, 2)
        XCTAssertFalse(cards.contains { $0.kind == .c1Pyramid || $0.kind == .d1WeeklyVolume })

        // today's session card is flagged a PR session
        let today = cards.first { $0.kind == .a1Session }
        if case .climbSession(let p)? = today?.payload {
            XCTAssertTrue(p.isPRSession)
            XCTAssertEqual(p.totalClimbs, 3)
            XCTAssertEqual(p.sends, 3)
            XCTAssertEqual(p.hardestSendGrade, "V7")
        } else { XCTFail("expected a climbSession payload on top a1") }
    }

    // MARK: - Graceful empties

    func testEmptyCorpusYieldsNoCards() {
        XCTAssertTrue(FeedComposer.compose(now: d(2026,6,20)).isEmpty)
    }

    func testSingleAttemptSessionYieldsOnlySessionCard() {
        let now = d(2026,6,20,18)
        let u = UUID()
        let s = KilterSessionInput(id: u, startedAt: d(2026,6,20,10), endedAt: d(2026,6,20,11), angle: 40)
        let logs = [climb("X", "V4", 13, .attempt, d(2026,6,20,10,10), u)]   // no send → no PR
        let cards = FeedComposer.compose(kilterSessions: [s], kilterLogs: logs,
                                         allTimeStats: allTime(logs, [summary(u, s.startedAt, s.endedAt)], now: now),
                                         now: now, calendar: cal)
        XCTAssertEqual(cards.map(\.kind), [.a1Session])
    }

    // MARK: - PR detection

    func testGradePRFiresOnlyForNewMax() {
        let now = d(2026,6,20,18)
        let u = UUID()
        let s = KilterSessionInput(id: u, startedAt: d(2026,6,20,9), endedAt: d(2026,6,20,12), angle: 40)
        let logs = [
            climb("a", "V4", 13, .sent, d(2026,6,20,9,10), u),   // PR (establishing)
            climb("b", "V6", 19, .sent, d(2026,6,20,9,40), u),   // PR (19 > 13)
            climb("c", "V3", 10, .sent, d(2026,6,20,10,10), u),  // NOT a PR
            climb("d", "V6", 19, .sent, d(2026,6,20,10,40), u),  // NOT a PR (not strictly greater)
        ]
        let prs = FeedComposer.compose(kilterSessions: [s], kilterLogs: logs,
                                       allTimeStats: allTime(logs, [summary(u, s.startedAt, s.endedAt)], now: now),
                                       now: now, calendar: cal)
            .filter { $0.kind == .b1GradePR }
        XCTAssertEqual(prs.count, 2)
        // the headline PR carries the V6 jump
        if case .gradePR(let p)? = prs.first(where: { if case .gradePR(let pp) = $0.payload { return pp.newGrade == "V6" } else { return false } })?.payload {
            XCTAssertEqual(p.previousGrade, "V4")
        } else { XCTFail("expected V6 PR with previousGrade V4") }
    }

    // MARK: - Streak boundary

    func testStreakNeedsThreeDays() {
        let now = d(2026,6,20,18)
        func sessions(_ days: [Int]) -> ([KilterSessionInput], [KilterClimbLog], [KilterSessionSummary]) {
            var ss: [KilterSessionInput] = []; var ls: [KilterClimbLog] = []; var sm: [KilterSessionSummary] = []
            for day in days {
                let u = UUID()
                let s = KilterSessionInput(id: u, startedAt: d(2026,6,day,10), endedAt: d(2026,6,day,11), angle: 40)
                ss.append(s); ls.append(climb("c\(day)", "V4", 13, .sent, d(2026,6,day,10,10), u))
                sm.append(summary(u, s.startedAt, s.endedAt))
            }
            return (ss, ls, sm)
        }
        let (s2, l2, m2) = sessions([19, 20])           // only 2 consecutive days
        XCTAssertFalse(FeedComposer.compose(kilterSessions: s2, kilterLogs: l2, allTimeStats: allTime(l2, m2, now: now), now: now, calendar: cal)
            .contains { $0.kind == .b5Streak })

        let (s3, l3, m3) = sessions([18, 19, 20])        // 3 consecutive days
        let streak = FeedComposer.compose(kilterSessions: s3, kilterLogs: l3, allTimeStats: allTime(l3, m3, now: now), now: now, calendar: cal)
            .first { $0.kind == .b5Streak }
        XCTAssertNotNil(streak)
        if case .streak(let p)? = streak?.payload { XCTAssertEqual(p.days, 3) } else { XCTFail() }
    }

    // MARK: - Pyramid threshold

    func testPyramidNeeds15SendsAcross3Grades() {
        let now = d(2026,6,20,18)
        let u = UUID()
        let s = KilterSessionInput(id: u, startedAt: d(2026,6,1,9), endedAt: d(2026,6,1,18), angle: 40)
        func sends(_ count: Int) -> [KilterClimbLog] {
            (0..<count).map { i in
                let grade = ["V3", "V4", "V5"][i % 3]; let diff = [10.0, 13, 16][i % 3]
                return climb("p\(i)", grade, diff, .sent, d(2026,6,1,9, (i % 50)), u)
            }
        }
        let l14 = sends(14)
        XCTAssertFalse(FeedComposer.compose(kilterSessions: [s], kilterLogs: l14, allTimeStats: allTime(l14, [summary(u, s.startedAt, s.endedAt)], now: now), now: now, calendar: cal)
            .contains { $0.kind == .c1Pyramid })

        let l15 = sends(15)
        XCTAssertTrue(FeedComposer.compose(kilterSessions: [s], kilterLogs: l15, allTimeStats: allTime(l15, [summary(u, s.startedAt, s.endedAt)], now: now), now: now, calendar: cal)
            .contains { $0.kind == .c1Pyramid })
    }

    // MARK: - Recency bound

    func testOldPRNeverOutranksFreshSession() {
        let now = d(2026,6,20,18)
        let uOld = UUID(); let uNew = UUID()
        // an old (60-day) high-grade PR session
        let old = KilterSessionInput(id: uOld, startedAt: d(2026,4,21,10), endedAt: d(2026,4,21,11), angle: 40)
        // a fresh routine session today, nothing special, lower grade (no new PR)
        let new = KilterSessionInput(id: uNew, startedAt: d(2026,6,20,10), endedAt: d(2026,6,20,11), angle: 40)
        let logs = [
            climb("old", "V8", 25, .sent, d(2026,4,21,10,10), uOld),   // establishing PR, 60 days ago
            climb("new", "V4", 13, .sent, d(2026,6,20,10,10), uNew),   // today, not a PR (lower)
        ]
        let cards = FeedComposer.compose(
            kilterSessions: [old, new], kilterLogs: logs,
            allTimeStats: allTime(logs, [summary(uOld, old.startedAt, old.endedAt), summary(uNew, new.startedAt, new.endedAt)], now: now),
            now: now, calendar: cal)
        // The recency bound: the fresh session ranks ABOVE the stale 60-day PR (which has decayed).
        // (Trend cards anchored to "today" may legitimately rank above a routine session — that's fine;
        //  the property under test is old-PR-vs-fresh-session, not absolute position.)
        let prIdx = cards.firstIndex { $0.kind == .b1GradePR }!
        let freshIdx = cards.firstIndex { $0.kind == .a1Session }!
        XCTAssertLessThan(freshIdx, prIdx, "fresh session must rank above the 60-day-old PR")
        // the fresh session card itself is not a PR session
        if case .climbSession(let p)? = cards.first(where: { $0.kind == .a1Session })?.payload { XCTAssertFalse(p.isPRSession) }
    }

    // MARK: - Lens filters

    func testLensFilters() {
        let now = d(2026,6,20,18)
        let u = UUID()
        let s = KilterSessionInput(id: u, startedAt: d(2026,6,20,10), endedAt: d(2026,6,20,11), angle: 40)
        let logs = [climb("c", "V6", 19, .sent, d(2026,6,20,10,10), u)]
        let cards = FeedComposer.compose(kilterSessions: [s], kilterLogs: logs,
                                         allTimeStats: allTime(logs, [summary(u, s.startedAt, s.endedAt)], now: now),
                                         now: now, calendar: cal)
        XCTAssertTrue(FeedComposer.filter(cards, lens: .sessionsOnly).allSatisfy { $0.kind == .a1Session })
        XCTAssertTrue(FeedComposer.filter(cards, lens: .category(.milestone)).allSatisfy { $0.category == .milestone })
        XCTAssertEqual(FeedComposer.filter(cards, lens: .all).count, cards.count)
    }
}
