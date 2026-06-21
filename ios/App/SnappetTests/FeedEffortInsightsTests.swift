import XCTest
@testable import Snappet

/// F6 (iOS, HR/RR-gated): e4 EffortEfficiency · e5 HRVRecovery · restNudge.
/// Eligibility gating + correctness, all pure (no device). HR fixtures are controlled `[HRPoint]`.
final class FeedEffortInsightsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let now = Date(timeIntervalSince1970: 2_000_000)

    // MARK: fixtures

    /// A flat HR series at `bpm` over `span` seconds (1 Hz). `peakBpm == bpm` deterministically.
    private func flatHR(_ bpm: Double, span: Double = 300, rr: [Double]? = nil) -> [HRPoint] {
        stride(from: 0.0, through: span, by: 1).map { HRPoint(t: $0, bpm: bpm, rrIntervalsMs: rr) }
    }

    /// One send at `grade` inside a session, window [10, 70] from the session start.
    private func send(_ grade: String, _ diff: Double, session: UUID, sessionStart: Date) -> KilterClimbLog {
        KilterClimbLog(climbUUID: "c-\(grade)-\(session.uuidString)", climbName: grade,
                       gradeLabel: grade, difficulty: diff, status: .sent, attempts: 1,
                       startedAt: sessionStart.addingTimeInterval(10),
                       endedAt: sessionStart.addingTimeInterval(70),
                       loggedAt: sessionStart.addingTimeInterval(70), angle: 40, sessionId: session)
    }

    private func kilterSession(start: Date, hr: [HRPoint], maxHR: Double? = 190, restHR: Double? = 60) -> KilterSessionInput {
        KilterSessionInput(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(300),
                           angle: 40, hrSeries: hr, maxHR: maxHR, restHR: restHR)
    }

    /// Build N sessions on consecutive days, each with one send at `grade` and a flat HR per `bpms[i]`.
    private func sessionsAtGrade(_ grade: String, _ diff: Double, bpms: [Double])
    -> (sessions: [KilterSessionInput], logs: [KilterClimbLog]) {
        var sessions: [KilterSessionInput] = []
        var logs: [KilterClimbLog] = []
        for (i, bpm) in bpms.enumerated() {
            let start = cal.date(byAdding: .day, value: i, to: t0)!
            var s = kilterSession(start: start, hr: flatHR(bpm))
            s.id = UUID()
            sessions.append(s)
            logs.append(send(grade, diff, session: s.id, sessionStart: start))
        }
        return (sessions, logs)
    }

    // MARK: e4 — EffortEfficiency

    func testE4FiresOnDownwardHRTrend() {
        // Same grade across 3 sessions; peak BPM falls 170 → 160 → 150 (a real efficiency gain).
        let (sessions, logs) = sessionsAtGrade("V5", 16, bpms: [170, 160, 150])
        let cards = FeedEffortInsights.cards(kilterSessions: sessions, logs: logs, now: now, calendar: cal, anchor: now)
        let e4 = cards.first { $0.kind == .e4EffortEfficiency }
        XCTAssertNotNil(e4, "downward HR trend across >= 3 sessions should fire e4")
        if case .effortEfficiency(let p)? = e4?.payload {
            XCTAssertEqual(p.gradeBand, "V5")
            XCTAssertLessThan(p.newAvgBpm, p.oldAvgBpm, "newAvg must be below oldAvg")
            XCTAssertEqual(p.oldAvgBpm, 170)
            XCTAssertEqual(p.newAvgBpm, 150)
        } else { XCTFail("expected an effortEfficiency payload") }
        XCTAssertEqual(e4?.contentId, "", "aggregate card → empty contentId")
    }

    func testE4DoesNotFireOnRisingHR() {
        // HR rises across sessions → no efficiency gain → no card.
        let (sessions, logs) = sessionsAtGrade("V5", 16, bpms: [150, 160, 170])
        let cards = FeedEffortInsights.cards(kilterSessions: sessions, logs: logs, now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .e4EffortEfficiency }, "rising HR is not an efficiency gain")
    }

    func testE4DoesNotFireWithTooFewSessions() {
        // Only 2 HR-carrying sessions at the grade → below the >= 3 threshold.
        let (sessions, logs) = sessionsAtGrade("V5", 16, bpms: [170, 150])
        let cards = FeedEffortInsights.cards(kilterSessions: sessions, logs: logs, now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .e4EffortEfficiency }, "< 3 sessions for a grade → no e4")
    }

    func testE4DegradesWithoutHR() {
        // Same logs, but the sessions carry NO HR → nothing to trend.
        var (sessions, logs) = sessionsAtGrade("V5", 16, bpms: [170, 160, 150])
        sessions = sessions.map { var s = $0; s.hrSeries = []; return s }
        let cards = FeedEffortInsights.cards(kilterSessions: sessions, logs: logs, now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .e4EffortEfficiency }, "no HR → no e4")
    }

    // MARK: e5 — HRVRecovery

    func testE5FiresWithRRPresent() {
        // A session whose HR samples carry RR intervals → on-device RMSSD resolves.
        let rr: [Double] = [800, 820, 790, 810, 805, 830]
        let s = kilterSession(start: t0, hr: flatHR(140, rr: rr))
        let cards = FeedEffortInsights.cards(kilterSessions: [s], logs: [], now: now, calendar: cal, anchor: now)
        let e5 = cards.first { $0.kind == .e5HRVRecovery }
        XCTAssertNotNil(e5, "RR present → e5 fires")
        if case .hrvRecovery(let p)? = e5?.payload {
            XCTAssertGreaterThan(p.rmssd, 0)
            XCTAssertEqual(p.note, "Higher RMSSD = better recovered.")
        } else { XCTFail("expected an hrvRecovery payload") }
        XCTAssertEqual(e5?.contentId, "")
    }

    func testE5DegradesWithoutRR() {
        // HR present but no RR intervals → no HRV signal → no card.
        let s = kilterSession(start: t0, hr: flatHR(140, rr: nil))
        let cards = FeedEffortInsights.cards(kilterSessions: [s], logs: [], now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .e5HRVRecovery }, "no RR → no e5")
    }

    func testE5DegradesWithoutHR() {
        let s = kilterSession(start: t0, hr: [])
        let cards = FeedEffortInsights.cards(kilterSessions: [s], logs: [], now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .e5HRVRecovery }, "no HR → no e5")
    }

    // MARK: restNudge

    /// N consecutive daily sessions, each peaking at a threshold+ BPM (Z4 ≈ 0.80×190 = 152+).
    private func hardSessions(days: Int, startDay: Int = 0) -> [KilterSessionInput] {
        (0..<days).map { i in
            let start = cal.date(byAdding: .day, value: startDay + i, to: t0)!
            return kilterSession(start: start, hr: flatHR(175))   // 175/190 ≈ 0.92 → Z5
        }
    }

    func testRestNudgeFiresOnFourConsecutiveHardDays() {
        let cards = FeedEffortInsights.cards(kilterSessions: hardSessions(days: 4), logs: [], now: now, calendar: cal, anchor: now)
        let rest = cards.first { $0.kind == .restNudge }
        XCTAssertNotNil(rest, "4 consecutive hard days → a protective rest nudge")
        if case .restNudge(let p)? = rest?.payload {
            XCTAssertEqual(p.hardDays, 4)
            XCTAssertTrue(p.note.contains("rest"), "note is protective, never shame")
            XCTAssertFalse(p.note.lowercased().contains("lazy"))
        } else { XCTFail("expected a restNudge payload") }
        XCTAssertEqual(rest?.contentId, "")
    }

    func testRestNudgeDoesNotFireOnThreeHardDays() {
        let cards = FeedEffortInsights.cards(kilterSessions: hardSessions(days: 3), logs: [], now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .restNudge }, "3 hard days is below the >= 4 threshold")
    }

    func testRestNudgeBreaksOnAGap() {
        // 2 hard days, a gap, then 2 more hard days → longest run is 2, not 4.
        var sessions = hardSessions(days: 2, startDay: 0)
        sessions += hardSessions(days: 2, startDay: 3)   // skip day index 2
        let cards = FeedEffortInsights.cards(kilterSessions: sessions, logs: [], now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .restNudge }, "a rest day breaks the consecutive-hard run")
    }

    func testRestNudgeIgnoresEasyDays() {
        // 4 consecutive days but well below threshold (110/190 ≈ 0.58 → Z1) → not "hard".
        let sessions = (0..<4).map { i -> KilterSessionInput in
            let start = cal.date(byAdding: .day, value: i, to: t0)!
            return kilterSession(start: start, hr: flatHR(110))
        }
        let cards = FeedEffortInsights.cards(kilterSessions: sessions, logs: [], now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .restNudge }, "easy days are never counted as hard")
    }

    func testRestNudgeDegradesWithoutHR() {
        let sessions = (0..<4).map { i -> KilterSessionInput in
            let start = cal.date(byAdding: .day, value: i, to: t0)!
            return kilterSession(start: start, hr: [])
        }
        let cards = FeedEffortInsights.cards(kilterSessions: sessions, logs: [], now: now, calendar: cal, anchor: now)
        XCTAssertNil(cards.first { $0.kind == .restNudge }, "no HR → no hard-day evidence → no rest nudge")
    }

    // MARK: anchor recency bound

    func testAnchorNeverInFuture() {
        let future = now.addingTimeInterval(10_000)
        let cards = FeedEffortInsights.cards(kilterSessions: hardSessions(days: 4), logs: [],
                                             now: now, calendar: cal, anchor: future)
        for c in cards { XCTAssertLessThanOrEqual(c.anchorDate, now, "anchorDate is clamped to now") }
    }
}
