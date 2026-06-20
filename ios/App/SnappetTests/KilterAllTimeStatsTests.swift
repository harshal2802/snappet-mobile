import XCTest
@testable import Snappet

/// Unit tests for the **pure** all-time Kilter aggregator — no SwiftData, no device. Synthetic
/// `KilterClimbLog` / `KilterSessionSummary` values feed `KilterAllTimeStats.make`, the keystone the
/// dashboard (P3) and history roll-ups / cards (P4) consume.
final class KilterAllTimeStatsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .iso8601)        // Monday-first, stable ISO weeks
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Build a date from y/m/d (UTC midnight) for readable fixtures.
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// A log builder with sensible defaults — only override what the case cares about.
    private func log(_ uuid: String, grade: String = "6a/V3", diff: Double = 15,
                     status: KilterAscentStatus = .sent, attempts: Int = 1,
                     angle: Int = 40, session: UUID? = nil, at date: Date) -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: grade, difficulty: diff,
                       status: status, attempts: attempts, startedAt: nil, endedAt: nil,
                       loggedAt: date, angle: angle, sessionId: session)
    }

    // MARK: - Empty

    func testEmptyHistoryIsZeroed() {
        let s = KilterAllTimeStats.make(logs: [], now: date(2026, 6, 19), calendar: cal)
        XCTAssertEqual(s, .empty)
        XCTAssertEqual(s.totalSends, 0)
        XCTAssertEqual(s.sendRate, 0)
        XCTAssertEqual(s.flashRate, 0)
        XCTAssertNil(s.attemptsToSend)
        XCTAssertNil(s.maxGradeDifficulty)
        XCTAssertNil(s.climbingLevelDifficulty)
        XCTAssertTrue(s.maxGradeProgression.isEmpty)
        XCTAssertTrue(s.sendsPerWeek.isEmpty)
        XCTAssertTrue(s.angleDistribution.isEmpty)
        XCTAssertTrue(s.pyramid.isEmpty)
        XCTAssertTrue(s.monthRollups.isEmpty)
        XCTAssertTrue(s.weekRollups.isEmpty)
    }

    // MARK: - Single session

    func testSingleSessionCountsAndCeiling() {
        let d = date(2026, 6, 10)
        let logs = [
            log("A", grade: "6a/V3", diff: 15, status: .flash, at: d),
            log("B", grade: "6b/V4", diff: 18, status: .sent, attempts: 3, at: d),
            log("C", grade: "6c/V5", diff: 20, status: .project, attempts: 4, at: d),
            log("D", grade: "6a/V3", diff: 15, status: .attempt, attempts: 2, at: d),
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 12), calendar: cal)
        XCTAssertEqual(s.totalClimbsLogged, 4)
        XCTAssertEqual(s.totalSends, 2)                 // A flash + B sent
        XCTAssertEqual(s.distinctClimbs, 4)
        XCTAssertEqual(s.totalAttempts, 1 + 3 + 4 + 2)  // 10
        XCTAssertEqual(s.maxGradeDifficulty, 18)        // hardest SEND is B (6b), not the C project
        XCTAssertEqual(s.maxGradeLabel, "6b/V4")
    }

    // MARK: - Multi-session

    func testMultiSessionDistinctClimbsAndTotals() {
        let s1 = UUID(); let s2 = UUID()
        let logs = [
            log("A", status: .sent, session: s1, at: date(2026, 5, 1)),
            log("A", status: .sent, session: s2, at: date(2026, 6, 1)),  // same climb, later session
            log("B", grade: "6b/V4", diff: 18, status: .flash, session: s2, at: date(2026, 6, 1)),
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 5), calendar: cal)
        XCTAssertEqual(s.totalClimbsLogged, 3)
        XCTAssertEqual(s.distinctClimbs, 2)             // A and B
        XCTAssertEqual(s.totalSends, 3)
    }

    // MARK: - Send & flash rate

    func testSendRate() {
        let d = date(2026, 6, 1)
        let logs = [
            log("A", status: .sent, at: d),
            log("B", status: .flash, at: d),
            log("C", status: .attempt, at: d),
            log("D", status: .project, at: d),
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: d, calendar: cal)
        XCTAssertEqual(s.sendRate, 0.5, accuracy: 0.0001)   // 2 sends / 4 logged
    }

    func testFlashRate() {
        let d = date(2026, 6, 1)
        let logs = [
            log("A", status: .flash, at: d),
            log("B", status: .flash, at: d),
            log("C", status: .sent, at: d),
            log("D", status: .attempt, at: d),     // not a send → doesn't affect flashRate denominator
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: d, calendar: cal)
        // 2 flashes / 3 sends
        XCTAssertEqual(s.flashRate, 2.0 / 3.0, accuracy: 0.0001)
    }

    // MARK: - Attempts-to-send

    func testAttemptsToSendAveragesOverSendsOnly() {
        let d = date(2026, 6, 1)
        let logs = [
            log("A", status: .sent, attempts: 2, at: d),
            log("B", status: .flash, attempts: 1, at: d),
            log("C", status: .sent, attempts: 6, at: d),
            log("D", status: .attempt, attempts: 99, at: d),   // excluded: not sent
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: d, calendar: cal)
        XCTAssertEqual(try XCTUnwrap(s.attemptsToSend), (2 + 1 + 6) / 3.0, accuracy: 0.0001)
    }

    // MARK: - Max-grade progression (chronological)

    func testMaxGradeProgressionPerMonthChronological() {
        let logs = [
            log("A", grade: "6a/V3", diff: 15, status: .sent, at: date(2026, 4, 5)),
            log("B", grade: "6b/V4", diff: 18, status: .sent, at: date(2026, 4, 20)),  // April best 18
            log("C", grade: "6a/V3", diff: 15, status: .sent, at: date(2026, 5, 2)),
            log("D", grade: "7a/V6", diff: 22, status: .sent, at: date(2026, 5, 28)),  // May best 22
            log("E", grade: "6c/V5", diff: 20, status: .project, at: date(2026, 6, 1)), // not a send
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 2), calendar: cal)
        XCTAssertEqual(s.maxGradeProgression.map(\.periodLabel), ["2026-04", "2026-05"])
        XCTAssertEqual(s.maxGradeProgression.map(\.difficulty), [18, 22])
        XCTAssertEqual(s.maxGradeProgression.map(\.gradeLabel), ["6b/V4", "7a/V6"])
    }

    // MARK: - Weekly volume buckets

    func testWeeklyVolumeBucketsZeroFilledAndOrdered() {
        let now = date(2026, 6, 17)                      // a Wednesday
        // Sends: 2 this week, 1 two weeks ago, none in between.
        let logs = [
            log("A", status: .sent, at: date(2026, 6, 16)),  // this week
            log("B", status: .flash, at: date(2026, 6, 17)), // this week
            log("C", status: .sent, at: date(2026, 6, 3)),   // two weeks back
            log("D", status: .attempt, at: date(2026, 6, 17)), // not a send
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: now, calendar: cal, weeklyVolumeWindow: 4)
        XCTAssertEqual(s.sendsPerWeek.count, 4)
        // Oldest→newest, zero-filled in the middle, this week last.
        XCTAssertEqual(s.sendsPerWeek.map(\.sends), [0, 1, 0, 2])
        // Strictly increasing window starts (chronological).
        let starts = s.sendsPerWeek.map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    // MARK: - Angle distribution

    func testAngleDistributionSendsAndAttempts() {
        let d = date(2026, 6, 1)
        let logs = [
            log("A", status: .sent, attempts: 1, angle: 40, at: d),
            log("B", status: .attempt, attempts: 3, angle: 40, at: d),
            log("C", status: .flash, attempts: 1, angle: 25, at: d),
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: d, calendar: cal)
        XCTAssertEqual(s.angleDistribution.map(\.angle), [25, 40])      // ascending
        let a25 = s.angleDistribution.first { $0.angle == 25 }!
        let a40 = s.angleDistribution.first { $0.angle == 40 }!
        XCTAssertEqual(a25.sends, 1); XCTAssertEqual(a25.attempts, 1)
        XCTAssertEqual(a40.sends, 1)                                    // only A is a send at 40
        XCTAssertEqual(a40.attempts, 1 + 3)                            // A's 1 + B's 3
    }

    // MARK: - Roll-ups

    func testMonthRollupsFromExplicitSessions() {
        let s1 = UUID(); let s2 = UUID()
        let sessions = [
            KilterSessionSummary(id: s1, startedAt: date(2026, 5, 2), endedAt: nil, angle: 40),
            KilterSessionSummary(id: s2, startedAt: date(2026, 6, 2), endedAt: nil, angle: 40),
        ]
        let logs = [
            log("A", grade: "6a/V3", diff: 15, status: .sent, session: s1, at: date(2026, 5, 2)),
            log("B", grade: "6b/V4", diff: 18, status: .flash, session: s2, at: date(2026, 6, 2)),
            log("C", grade: "6c/V5", diff: 20, status: .attempt, session: s2, at: date(2026, 6, 3)),
        ]
        let s = KilterAllTimeStats.make(logs: logs, sessions: sessions, now: date(2026, 6, 5), calendar: cal)
        XCTAssertEqual(s.monthRollups.map(\.periodLabel), ["2026-05", "2026-06"])
        let may = s.monthRollups[0]; let jun = s.monthRollups[1]
        XCTAssertEqual(may.sessions, 1); XCTAssertEqual(may.sends, 1)
        XCTAssertEqual(may.hardestGradeLabel, "6a/V3")
        XCTAssertEqual(jun.sessions, 1); XCTAssertEqual(jun.sends, 1)   // only B is a send in June
        XCTAssertEqual(jun.hardestGradeLabel, "6b/V4")                  // attempt C doesn't count
    }

    func testRollupsFallBackToDistinctSessionIdWhenNoSessionList() {
        let s1 = UUID(); let s2 = UUID()
        let logs = [
            log("A", status: .sent, session: s1, at: date(2026, 6, 2)),
            log("B", status: .sent, session: s1, at: date(2026, 6, 2)),  // same session
            log("C", status: .sent, session: s2, at: date(2026, 6, 3)),  // different session, same month
            log("D", status: .sent, session: nil, at: date(2026, 6, 4)), // ad-hoc → no session count
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 5), calendar: cal)
        XCTAssertEqual(s.monthRollups.count, 1)
        XCTAssertEqual(s.monthRollups[0].sessions, 2)   // distinct s1, s2 (ad-hoc D excluded)
        XCTAssertEqual(s.monthRollups[0].sends, 4)
    }

    func testWeekRollupsSplitByISOWeek() {
        let logs = [
            log("A", status: .sent, session: UUID(), at: date(2026, 6, 1)),   // week 23
            log("B", status: .sent, session: UUID(), at: date(2026, 6, 10)),  // week 24
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 12), calendar: cal)
        XCTAssertEqual(s.weekRollups.count, 2)
        XCTAssertEqual(s.weekRollups.map(\.sends), [1, 1])
    }

    // MARK: - Segmented pyramid

    func testSegmentedPyramidPerGrade() {
        let d = date(2026, 6, 1)
        let logs = [
            log("A", grade: "6a/V3", diff: 15, status: .flash, at: d),
            log("B", grade: "6a/V3", diff: 15, status: .sent, at: d),
            log("C", grade: "6a/V3", diff: 15, status: .attempt, at: d),
            log("D", grade: "6c/V5", diff: 20, status: .sent, at: d),
            log("E", grade: "6c/V5", diff: 20, status: .project, at: d),
            // A grade with ONLY a project/attempt (no send) must NOT appear — the pyramid is send-volume.
            log("F", grade: "7a/V6", diff: 22, status: .project, at: d),
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: d, calendar: cal)
        XCTAssertEqual(s.pyramid.map(\.gradeLabel), ["6a/V3", "6c/V5"])     // easiest→hardest, 7a dropped

        let easy = s.pyramid[0]
        XCTAssertEqual(easy.sends, 2)          // flash A + sent B (the existing pyramid total)
        XCTAssertEqual(easy.flashes, 1)        // SUBSET: just A
        XCTAssertEqual(easy.attemptsOnly, 1)   // C
        XCTAssertEqual(easy.projects, 0)

        let hard = s.pyramid[1]
        XCTAssertEqual(hard.sends, 1)          // D
        XCTAssertEqual(hard.flashes, 0)
        XCTAssertEqual(hard.projects, 1)       // E
    }

    // MARK: - Climbing level (recency window)

    func testClimbingLevelSeededFromRecentSends() {
        // Old hard PR, then a stretch of consistent V4 sends — the level should track the recent V4s,
        // not the lone old V8.
        var logs: [KilterClimbLog] = [
            log("PR", grade: "8a/V11", diff: 30, status: .sent, at: date(2025, 1, 1)),
        ]
        for i in 0..<6 {
            logs.append(log("r\(i)", grade: "6b/V4", diff: 18, status: .sent, at: date(2026, 6, 1 + i)))
        }
        let s = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 10), calendar: cal,
                                        climbingLevelWindow: 4)
        XCTAssertEqual(s.maxGradeDifficulty, 30)        // all-time ceiling still the old PR
        XCTAssertEqual(s.climbingLevelDifficulty, 18)   // recency window → the V4s
        XCTAssertEqual(s.climbingLevelLabel, "6b/V4")
    }

    // MARK: - Fix A: pyramid representative difficulty must come from a SEND

    /// When a grade's non-send logs carry a DIFFERENT difficulty than its sends, the pyramid's
    /// easiest→hardest sort key must come from a send — so the row sorts by its real send difficulty,
    /// not a stray project/attempt value. Here the "6b/V4" grade's project/attempt are seeded earlier
    /// (chronologically first) with a misleading difficulty; the send is what should fix the sort key.
    func testPyramidRepresentativeDifficultyComesFromSend() {
        let d = date(2026, 6, 1)
        let logs = [
            // 6b/V4: a project + attempt logged FIRST with a bogus-high difficulty (50), then the real
            // send at 18. The send's 18 must be the row's sort key, so 6b sorts below the 7a send (22).
            log("p", grade: "6b/V4", diff: 50, status: .project, at: d),
            log("a", grade: "6b/V4", diff: 50, status: .attempt, at: d),
            log("s", grade: "6b/V4", diff: 18, status: .sent, at: d),
            // 7a/V6: a clean send at 22.
            log("h", grade: "7a/V6", diff: 22, status: .sent, at: d),
            // 6a/V3: a clean send at 15 (the easiest).
            log("e", grade: "6a/V3", diff: 15, status: .sent, at: d),
        ]
        let s = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 2), calendar: cal)
        // Easiest→hardest by SEND difficulty: 6a(15) < 6b(18) < 7a(22). If 6b had kept the project's
        // 50 it would sort last — this asserts it doesn't.
        XCTAssertEqual(s.pyramid.map(\.gradeLabel), ["6a/V3", "6b/V4", "7a/V6"])
        let sixB = s.pyramid.first { $0.gradeLabel == "6b/V4" }!
        XCTAssertEqual(sixB.difficulty, 18)        // from the send, not the project's 50
        XCTAssertEqual(sixB.sends, 1)              // segment counts unchanged
        XCTAssertEqual(sixB.projects, 1)
        XCTAssertEqual(sixB.attemptsOnly, 1)
    }

    // MARK: - Fix B: climbingLevel determinism

    /// Many sends sharing one IDENTICAL `loggedAt` (backfilled / midnight-stamped) must yield the same
    /// climbing level on every run — no ordering ambiguity from the recency `suffix` window — and the
    /// label must correspond to the working bucket.
    func testClimbingLevelDeterministicWithIdenticalTimestamps() {
        let d = date(2026, 6, 1)                    // one instant shared by every send
        // A spread of grades all at the same timestamp; the V4 bucket (18) is sent the most → working.
        var logs: [KilterClimbLog] = []
        for i in 0..<5 { logs.append(log("v4_\(i)", grade: "6b/V4", diff: 18, status: .sent, at: d)) }
        for i in 0..<3 { logs.append(log("v3_\(i)", grade: "6a/V3", diff: 15, status: .sent, at: d)) }
        logs.append(log("v6", grade: "7a/V6", diff: 22, status: .sent, at: d))
        // Distinct climb UUIDs but a single timestamp: the suffix(N) window depends on the tie-break.
        let s1 = KilterAllTimeStats.make(logs: logs, now: date(2026, 6, 2), calendar: cal,
                                         climbingLevelWindow: 6)
        // Shuffle the input and re-run: a deterministic make must produce identical results.
        let s2 = KilterAllTimeStats.make(logs: logs.shuffled(), now: date(2026, 6, 2), calendar: cal,
                                         climbingLevelWindow: 6)
        XCTAssertEqual(s1.climbingLevelDifficulty, s2.climbingLevelDifficulty)
        XCTAssertEqual(s1.climbingLevelLabel, s2.climbingLevelLabel)
        // The label corresponds to the working bucket: difficulty rounds into the level.
        let lvl = try! XCTUnwrap(s1.climbingLevelDifficulty)
        let pickedDiff = try! XCTUnwrap(logs.first { $0.gradeLabel == s1.climbingLevelLabel }).difficulty
        XCTAssertEqual(pickedDiff.rounded(), lvl.rounded(),
                       "label \(s1.climbingLevelLabel ?? "nil") must sit in the working bucket \(lvl)")
    }

    // MARK: - Fix C: weekly bucketing across the year boundary

    /// Under `Calendar.current` the weekly window must always emit exactly `weeklyVolumeWindow` buckets,
    /// and a send in a week that straddles the new-year boundary must land in (and be counted by) the
    /// correct most-recent bucket — the old `yearForWeekOfYear` string key dropped it.
    func testWeeklyVolumeYearBoundaryWithCurrentCalendar() {
        let current = Calendar.current
        // "now" is the first few days of a new year; the current week likely began in late December.
        let now = current.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12))!
        // A send earlier in this SAME (boundary-straddling) week — its week-start matches the newest
        // bucket's start, so it must be counted there.
        guard let thisWeekStart = current.dateInterval(of: .weekOfYear, for: now)?.start else {
            return XCTFail("no week interval")
        }
        // 12:00 on the very first day of the current week — squarely inside it, possibly in the prior year.
        let inBoundaryWeek = current.date(byAdding: .hour, value: 12, to: thisWeekStart)!
        let logs = [
            log("boundary", grade: "6b/V4", diff: 18, status: .sent, at: inBoundaryWeek),
        ]
        let weeks = 8
        let s = KilterAllTimeStats.make(logs: logs, now: now, calendar: current,
                                        weeklyVolumeWindow: weeks)
        XCTAssertEqual(s.sendsPerWeek.count, weeks)                 // exactly the window size
        XCTAssertEqual(s.sendsPerWeek.last?.sends, 1)              // counted in the most-recent bucket
        XCTAssertEqual(s.sendsPerWeek.dropLast().map(\.sends), Array(repeating: 0, count: weeks - 1))
        let starts = s.sendsPerWeek.map(\.start)
        XCTAssertEqual(starts, starts.sorted())                    // oldest→newest
    }
}
