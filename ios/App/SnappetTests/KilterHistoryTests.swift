import XCTest
import SwiftData
@testable import Snappet

/// Locks the Kilter Improvement **P4** session-history contract: the pure `KilterHistoryModel`
/// (bucketing / scope / faceted filtering + stale recovery / adaptive-card facts / search) and
/// `KilterConsistency` (heatmap + calendar day buckets) behave deterministically, AND the additive
/// `KilterSession.title`/`notes`/`layoutId` fields round-trip through `SnappetBackup` — including a
/// **pre-change blob** (no such keys) decoding cleanly (the lightweight-migration twin). No device.
final class KilterHistoryTests: XCTestCase {

    // A fixed clock + a UTC calendar so month/week bucketing is stable across CI time zones.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday — stable ISO-ish week
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_718_000_000) // 2024-06-10T07:33:20Z

    // MARK: - Builders

    private func session(_ id: UUID = UUID(), daysAgo: Int, angle: Int = 40, source: String = "ble",
                         layoutId: Int? = 1, title: String? = nil, active: Bool = false,
                         hasHR: Bool = false) -> KilterHistoryModel.SessionItem {
        let start = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return KilterHistoryModel.SessionItem(
            id: id, startedAt: start, endedAt: active ? nil : start.addingTimeInterval(3600),
            angle: angle, source: source, layoutId: layoutId, title: title, hasHR: hasHR)
    }

    private func log(session sid: UUID?, grade: String, diff: Double,
                     status: KilterAscentStatus, daysAgo: Int, angle: Int = 40,
                     name: String = "Climb", attempts: Int = 1) -> KilterClimbLog {
        let at = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return KilterClimbLog(climbUUID: UUID().uuidString, climbName: name, gradeLabel: grade,
                              difficulty: diff, status: status, attempts: attempts,
                              startedAt: nil, endedAt: nil, loggedAt: at, angle: angle, sessionId: sid)
    }

    /// A log whose `loggedAt` is set to an EXACT instant (for the post-midnight bucketing case), decoupled
    /// from a `daysAgo` shorthand.
    private func log(session sid: UUID?, grade: String, diff: Double, status: KilterAscentStatus,
                     loggedAt: Date, name: String = "Climb") -> KilterClimbLog {
        KilterClimbLog(climbUUID: UUID().uuidString, climbName: name, gradeLabel: grade,
                       difficulty: diff, status: status, attempts: 1,
                       startedAt: nil, endedAt: nil, loggedAt: loggedAt, angle: 40, sessionId: sid)
    }

    // MARK: - Bucketing (month / week / all)

    func testMonthBucketingGroupsByCalendarMonth() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let sessions = [session(a, daysAgo: 2), session(b, daysAgo: 5),    // this month (June)
                        session(c, daysAgo: 45)]                            // ~April/May
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 2),
                    log(session: b, grade: "6b/V4", diff: 20, status: .flash, daysAgo: 5),
                    log(session: c, grade: "5+/V2", diff: 16, status: .sent, daysAgo: 45)]
        let model = KilterHistoryModel.build(sessions: sessions, logs: logs, scope: .all,
                                             filters: .init(), now: now, calendar: cal)
        // .all → single group; switch to month for the per-month split.
        XCTAssertEqual(model.groups.count, 1)
        let byMonth = KilterHistoryModel.group(sessions, logsBySession: logsBySession(logs),
                                               scope: .month, calendar: cal)
        XCTAssertEqual(byMonth.count, 2, "two distinct calendar months")
        XCTAssertEqual(byMonth.first?.rows.count, 2, "newest month (June) has 2 sessions")
    }

    func testWeekBucketingSplitsByISOWeek() {
        let a = UUID(); let b = UUID()
        let sessions = [session(a, daysAgo: 1), session(b, daysAgo: 10)]
        let byWeek = KilterHistoryModel.group(sessions, logsBySession: [:], scope: .week, calendar: cal)
        XCTAssertEqual(byWeek.count, 2, "sessions 9 days apart land in different weeks")
    }

    func testScopeWindowingKeepsOnlyInWindow() {
        // `daysAgo: 0` is guaranteed inside the current week/month regardless of weekday alignment.
        let recent = session(UUID(), daysAgo: 0)
        let old = session(UUID(), daysAgo: 40)
        let week = KilterHistoryModel.inScope([recent, old], scope: .week, now: now, calendar: cal)
        XCTAssertEqual(week.map(\.id), [recent.id], "week scope drops the 40-day-old session")
        let month = KilterHistoryModel.inScope([recent, old], scope: .month, now: now, calendar: cal)
        XCTAssertEqual(month.map(\.id), [recent.id], "month scope drops the 40-day-old session")
        let all = KilterHistoryModel.inScope([recent, old], scope: .all, now: now, calendar: cal)
        XCTAssertEqual(Set(all.map(\.id)), [recent.id, old.id])
    }

    func testActiveSessionAlwaysInScope() {
        let live = session(UUID(), daysAgo: 99, active: true)   // started long ago, still open
        let week = KilterHistoryModel.inScope([live], scope: .week, now: now, calendar: cal)
        XCTAssertEqual(week.map(\.id), [live.id], "an open session stays visible regardless of scope")
    }

    // MARK: - Roll-up headers

    func testRollupSummaryCountsSessionsSendsAndHardest() {
        let a = UUID(); let b = UUID()
        let sessions = [session(a, daysAgo: 1), session(b, daysAgo: 2)]
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1),
                    log(session: a, grade: "7a/V6", diff: 24, status: .flash, daysAgo: 1),
                    log(session: b, grade: "5+/V2", diff: 16, status: .project, daysAgo: 2)]
        let summary = KilterHistoryModel.rollupSummary(sessions, logsBySession: logsBySession(logs))
        XCTAssertEqual(summary, "2 sessions · 2 sent · hardest 7a/V6")
    }

    func testRollupSummaryDropsHardestWhenNothingSent() {
        let a = UUID()
        let sessions = [session(a, daysAgo: 1)]
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .project, daysAgo: 1)]
        XCTAssertEqual(KilterHistoryModel.rollupSummary(sessions, logsBySession: logsBySession(logs)),
                       "1 session · 0 sent")
    }

    // MARK: - Faceted filtering

    func testEachFacetFilter() {
        let a = UUID(); let b = UUID()
        let sessions = [session(a, daysAgo: 1, angle: 40, source: "ble", layoutId: 1),
                        session(b, daysAgo: 2, angle: 25, source: "manual", layoutId: 2)]
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1, angle: 40),
                    log(session: b, grade: "5+/V2", diff: 16, status: .project, daysAgo: 2, angle: 25)]
        let names: (Int) -> String? = { $0 == 1 ? "Original" : "Homewall" }

        func build(_ f: KilterHistoryModel.Filters) -> [UUID] {
            KilterHistoryModel.build(sessions: sessions, logs: logs, scope: .all, filters: f,
                                     now: now, calendar: cal, layoutName: names)
                .groups.flatMap { $0.rows.map(\.session.id) }
        }
        XCTAssertEqual(build(filters(.angle, "40°")), [a])
        XCTAssertEqual(build(filters(.source, "Manual")), [b])
        XCTAssertEqual(build(filters(.board, "Homewall")), [b])
        XCTAssertEqual(build(filters(.grade, "6a/V3")), [a])
        XCTAssertEqual(build(filters(.status, "project")), [b])
    }

    func testCombinedFacetsAreANDed() {
        let a = UUID(); let b = UUID()
        let sessions = [session(a, daysAgo: 1, angle: 40, source: "ble"),
                        session(b, daysAgo: 2, angle: 40, source: "manual")]
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1),
                    log(session: b, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 2)]
        var f = KilterHistoryModel.Filters()
        f.selections = [.angle: "40°", .source: "BLE"]
        let ids = KilterHistoryModel.build(sessions: sessions, logs: logs, scope: .all, filters: f,
                                           now: now, calendar: cal).groups.flatMap { $0.rows.map(\.session.id) }
        XCTAssertEqual(ids, [a], "angle AND source narrows to exactly the BLE 40° session")
    }

    func testStaleFilterRecoveryFlag() {
        let a = UUID()
        let sessions = [session(a, daysAgo: 1, angle: 40)]
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1)]
        let model = KilterHistoryModel.build(sessions: sessions, logs: logs, scope: .all,
                                             filters: filters(.angle, "70°"), now: now, calendar: cal)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.isStaleFilter, "a filter that matches nothing offers recovery")
        // No filter at all on an empty history is NOT stale (genuinely empty).
        let empty = KilterHistoryModel.build(sessions: [], logs: [], scope: .all,
                                             filters: .init(), now: now, calendar: cal)
        XCTAssertFalse(empty.isStaleFilter)
    }

    func testFacetValuesComeFromFullSetNotFiltered() {
        let a = UUID(); let b = UUID()
        let sessions = [session(a, daysAgo: 1, angle: 40), session(b, daysAgo: 2, angle: 25)]
        let logs: [KilterClimbLog] = []
        // Even with a filter selected, both angle chips remain offered.
        let model = KilterHistoryModel.build(sessions: sessions, logs: logs, scope: .all,
                                             filters: filters(.angle, "40°"), now: now, calendar: cal)
        XCTAssertEqual(model.facetValues[.angle], ["25°", "40°"])
    }

    func testSearchMatchesTitleBoardAndClimbName() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let sessions = [session(a, daysAgo: 1, layoutId: 1, title: "Comp prep"),
                        session(b, daysAgo: 2, layoutId: 2),
                        session(c, daysAgo: 3, layoutId: 1)]
        let logs = [log(session: c, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 3, name: "Moonwalk")]
        let names: (Int) -> String? = { $0 == 1 ? "Original" : "Homewall" }
        func search(_ q: String) -> Set<UUID> {
            var f = KilterHistoryModel.Filters(); f.search = q
            return Set(KilterHistoryModel.build(sessions: sessions, logs: logs, scope: .all, filters: f,
                                                now: now, calendar: cal, layoutName: names)
                .groups.flatMap { $0.rows.map(\.session.id) })
        }
        XCTAssertEqual(search("comp"), [a], "matches the title")
        XCTAssertEqual(search("homewall"), [b], "matches the board name")
        XCTAssertEqual(search("moon"), [c], "matches a climb name")
    }

    // MARK: - Adaptive card facts (one badge max)

    func testDefaultFactsAreSendsHardestDuration() {
        let s = session(UUID(), daysAgo: 1)
        let logs = [log(session: s.id, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1),
                    log(session: s.id, grade: "6b/V4", diff: 20, status: .sent, daysAgo: 1)]
        let card = KilterHistoryModel.card(for: s, logs: logs, priorHardestDifficulty: 25) // no PR
        XCTAssertEqual(card.facts.map(\.kind), [.sends, .hardest, .duration])
        XCTAssertEqual(card.facts[0].value, "2")
        XCTAssertEqual(card.facts[1].value, "6b/V4")
        XCTAssertNil(card.badge, "nothing notable when there's no PR / flash / project")
    }

    func testPRBadgeWhenSessionBeatsPriorHardest() {
        let s = session(UUID(), daysAgo: 1)
        let logs = [log(session: s.id, grade: "7a/V6", diff: 24, status: .sent, daysAgo: 1)]
        let card = KilterHistoryModel.card(for: s, logs: logs, priorHardestDifficulty: 20)
        XCTAssertEqual(card.badge?.kind, .prBadge)
        XCTAssertEqual(card.badge?.value, "7a/V6")
    }

    func testFirstEverSendIsAPR() {
        let s = session(UUID(), daysAgo: 1)
        let logs = [log(session: s.id, grade: "5+/V2", diff: 16, status: .sent, daysAgo: 1)]
        let card = KilterHistoryModel.card(for: s, logs: logs, priorHardestDifficulty: nil)
        XCTAssertEqual(card.badge?.kind, .prBadge)
    }

    func testFlashRateBadgeWhenMajorityFlashed() {
        let s = session(UUID(), daysAgo: 1)
        // 2 of 2 sends are flashes (100%), no PR (prior is harder).
        let logs = [log(session: s.id, grade: "6a/V3", diff: 18, status: .flash, daysAgo: 1),
                    log(session: s.id, grade: "6a/V3", diff: 18, status: .flash, daysAgo: 1)]
        let card = KilterHistoryModel.card(for: s, logs: logs, priorHardestDifficulty: 30)
        XCTAssertEqual(card.badge?.kind, .flashRate)
        XCTAssertEqual(card.badge?.value, "100%")
    }

    func testProjectsBadgeWhenNothingHotterApplies() {
        let s = session(UUID(), daysAgo: 1)
        let logs = [log(session: s.id, grade: "6a/V3", diff: 18, status: .project, daysAgo: 1),
                    log(session: s.id, grade: "6b/V4", diff: 20, status: .project, daysAgo: 1)]
        let card = KilterHistoryModel.card(for: s, logs: logs, priorHardestDifficulty: 30)
        XCTAssertEqual(card.badge?.kind, .projects)
        XCTAssertEqual(card.badge?.value, "2")
    }

    func testBadgePriorityPRBeatsFlashBeatsProjects() {
        let s = session(UUID(), daysAgo: 1)
        // Has a flash AND a project AND a new PR — PR must win the single slot.
        let logs = [log(session: s.id, grade: "7a/V6", diff: 24, status: .flash, daysAgo: 1),
                    log(session: s.id, grade: "6a/V3", diff: 18, status: .project, daysAgo: 1)]
        let card = KilterHistoryModel.card(for: s, logs: logs, priorHardestDifficulty: 20)
        XCTAssertEqual(card.badge?.kind, .prBadge)
    }

    func testProvenanceAndLiveFlags() {
        let ble = KilterHistoryModel.card(for: session(UUID(), daysAgo: 1, source: "ble"), logs: [])
        XCTAssertEqual(ble.provenance.value, "BLE")
        XCTAssertFalse(ble.isLive)
        let live = KilterHistoryModel.card(for: session(UUID(), daysAgo: 1, source: "manual", active: true),
                                           logs: [])
        XCTAssertEqual(live.provenance.value, "Manual")
        XCTAssertTrue(live.isLive)
    }

    func testPriorHardestBySessionIsChronologicalAndGlobal() {
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let sessions = [session(s1, daysAgo: 30), session(s2, daysAgo: 20), session(s3, daysAgo: 10)]
        let logs = [log(session: s1, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 30),
                    log(session: s2, grade: "6c/V5", diff: 22, status: .sent, daysAgo: 20),
                    log(session: s3, grade: "6b/V4", diff: 20, status: .sent, daysAgo: 10)]
        let prior = KilterHistoryModel.priorHardestBySession(sessions, logsBySession: logsBySession(logs))
        XCTAssertNil(prior[s1], "first session has no prior")
        XCTAssertEqual(prior[s2], 18, "prior to s2 is s1's 18")
        XCTAssertEqual(prior[s3], 22, "prior to s3 is the running max 22 (from s2), not s1")
    }

    // MARK: - Consistency surfaces

    func testHeatmapBucketsSendsByDayAndScalesIntensity() {
        let a = UUID(); let b = UUID()
        let sessions = [session(a, daysAgo: 1), session(b, daysAgo: 3)]
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1),
                    log(session: a, grade: "6b/V4", diff: 20, status: .sent, daysAgo: 1),
                    log(session: b, grade: "5+/V2", diff: 16, status: .sent, daysAgo: 3)]
        let days = KilterConsistency.heatmap(sessions: sessions, logs: logs, now: now,
                                             weeks: 8, calendar: cal)
        let active = days.filter { !$0.isEmpty }
        XCTAssertEqual(active.count, 2)
        let busiest = active.max { $0.sends < $1.sends }
        XCTAssertEqual(busiest?.sends, 2)
        XCTAssertEqual(busiest?.intensity, 1.0, "the busiest day reaches full intensity")
    }

    func testMonthDaysCoverWholeMonthAndDotActiveDays() {
        let a = UUID()
        let sessions = [session(a, daysAgo: 1)]
        let logs = [log(session: a, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1)]
        let days = KilterConsistency.monthDays(sessions: sessions, logs: logs, month: now, calendar: cal)
        XCTAssertEqual(days.count, 30, "June has 30 days")
        XCTAssertEqual(days.filter { !$0.isEmpty }.count, 1)
    }

    // MARK: - FD: active session never renders a stale period header

    func testActiveSessionBucketsIntoCurrentPeriodNotStale() {
        // An open session started 40 days ago must group into THIS month/week, not a stale one.
        let live = session(UUID(), daysAgo: 40, active: true)
        let recent = session(UUID(), daysAgo: 1)        // genuinely this period
        let sessions = [live, recent]

        let month = KilterHistoryModel.build(sessions: sessions, logs: [], scope: .month,
                                             filters: .init(), now: now, calendar: cal)
        XCTAssertEqual(month.groups.count, 1, "the live session shares the current month group, not a stale one")
        XCTAssertEqual(Set(month.groups[0].rows.map(\.session.id)), [live.id, recent.id])
        // The group key is the CURRENT month, not the live session's 40-day-old start.
        XCTAssertEqual(month.groups[0].id, KilterHistoryModel.monthKey(now, calendar: cal))

        let week = KilterHistoryModel.build(sessions: sessions, logs: [], scope: .week,
                                            filters: .init(), now: now, calendar: cal)
        XCTAssertEqual(week.groups.count, 1, "the live session shares the current week group")
        XCTAssertEqual(week.groups[0].id, KilterHistoryModel.weekKey(now, calendar: cal))
    }

    func testInactiveSessionStillBucketsByItsOwnStart() {
        // Regression: a CLOSED old session must still split into its own (older) period.
        let a = session(UUID(), daysAgo: 1)
        let b = session(UUID(), daysAgo: 45)
        let byMonth = KilterHistoryModel.group([a, b], logsBySession: [:], scope: .month,
                                               now: now, calendar: cal)
        XCTAssertEqual(byMonth.count, 2, "two closed sessions in different months stay split")
    }

    // MARK: - FE: consistency window-normalize + bucket-by-log-day + ad-hoc logs

    func testHeatmapNormalizesOverWindowNotAllLogs() {
        // A busy day OUTSIDE the 8-week window must not crush the in-window day's intensity.
        let inWin = UUID(); let outWin = UUID()
        let sessions = [session(inWin, daysAgo: 1), session(outWin, daysAgo: 300)]
        let logs = [log(session: inWin, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1),
                    // 5 sends far outside the window — would crush in-window intensity if counted globally.
                    log(session: outWin, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 300),
                    log(session: outWin, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 300),
                    log(session: outWin, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 300),
                    log(session: outWin, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 300),
                    log(session: outWin, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 300)]
        let days = KilterConsistency.heatmap(sessions: sessions, logs: logs, now: now,
                                             weeks: 8, calendar: cal)
        let busiest = days.filter { !$0.isEmpty }.max { $0.sends < $1.sends }
        XCTAssertEqual(busiest?.sends, 1)
        XCTAssertEqual(busiest?.intensity, 1.0, "the in-window busiest day reaches full — not scaled by the out-of-window day")
    }

    func testSendsBucketByLogDayIncludingPostMidnight() {
        // A session that STARTED late on day-1 but whose send was logged just after midnight on day-2:
        // the send must land on day-2's cell, not the session's start day.
        let sid = UUID()
        let startDay = cal.date(byAdding: .day, value: -2, to: now)!          // a session start
        let justBeforeMidnight = cal.startOfDay(for: startDay).addingTimeInterval(23 * 3600 + 59 * 60)
        let afterMidnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: startDay))!
            .addingTimeInterval(30 * 60)   // 00:30 the next day
        let s = KilterHistoryModel.SessionItem(
            id: sid, startedAt: justBeforeMidnight, endedAt: afterMidnight,
            angle: 40, source: "ble", layoutId: 1, title: nil, hasHR: false)
        let sendLog = log(session: sid, grade: "6a/V3", diff: 18, status: .sent, loggedAt: afterMidnight)

        let month = KilterConsistency.monthDays(sessions: [s], logs: [sendLog], month: now, calendar: cal)
        let startKey = cal.startOfDay(for: justBeforeMidnight)
        let sendKey = cal.startOfDay(for: afterMidnight)
        XCTAssertNotEqual(startKey, sendKey, "the send crossed midnight")
        XCTAssertEqual(month.first { $0.date == startKey }?.sessions, 1, "the session counts on its start day")
        XCTAssertEqual(month.first { $0.date == startKey }?.sends, 0, "no send on the start day")
        XCTAssertEqual(month.first { $0.date == sendKey }?.sends, 1, "the send lands on the day it was logged")
    }

    func testAdHocSessionlessSendsAreCounted() {
        // A log with sessionId == nil (ad-hoc ascent) must still raise the day's send count.
        let adHoc = log(session: nil, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1)
        let days = KilterConsistency.monthDays(sessions: [], logs: [adHoc], month: now, calendar: cal)
        let key = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now)!)
        let cell = days.first { $0.date == key }
        XCTAssertEqual(cell?.sends, 1, "an ad-hoc send is counted even with no session")
        XCTAssertEqual(cell?.sessions, 0, "but it adds no session")
        XCTAssertFalse(cell?.isEmpty ?? true, "a send-only ad-hoc day still reads as active")
    }

    // MARK: - FF: deterministic tie-breaks

    func testGradeFacetOrderTieBreaksByLabel() {
        // Two grade labels at the SAME representative difficulty must order by the label, deterministically.
        let a = UUID()
        let sessions = [session(a, daysAgo: 1)]
        let logs = [log(session: a, grade: "6a/V3", diff: 20, status: .sent, daysAgo: 1, name: "x"),
                    log(session: a, grade: "6a+/V3", diff: 20, status: .sent, daysAgo: 1, name: "y")]
        // Run the build several times; same difficulty → label-sorted (ascending), stable every run.
        for _ in 0..<8 {
            let model = KilterHistoryModel.build(sessions: sessions, logs: logs, scope: .all,
                                                 filters: .init(), now: now, calendar: cal)
            XCTAssertEqual(model.facetValues[.grade], ["6a+/V3", "6a/V3"],
                           "equal-difficulty grades order by label, deterministically")
        }
    }

    func testRollupHardestTieBreaksByLabel() {
        let a = UUID()
        let sessions = [session(a, daysAgo: 1)]
        // Two equally-hard sends — the roll-up must pick the same label every time.
        let logs = [log(session: a, grade: "7a/V6", diff: 24, status: .sent, daysAgo: 1, name: "x"),
                    log(session: a, grade: "7a+/V6", diff: 24, status: .sent, daysAgo: 1, name: "y")]
        let lbs = (0..<8).map { _ in
            KilterHistoryModel.rollupSummary(sessions, logsBySession: logsBySession(logs))
        }
        XCTAssertEqual(Set(lbs).count, 1, "the hardest-send roll-up is deterministic for equal difficulties")
    }

    func testPRAwardingDeterministicForIdenticalStartedAt() {
        // Two sessions started at the SAME instant — PR-prior must be a stable function of id.
        let start = now
        func s(_ id: UUID) -> KilterHistoryModel.SessionItem {
            KilterHistoryModel.SessionItem(id: id, startedAt: start,
                                           endedAt: start.addingTimeInterval(3600),
                                           angle: 40, source: "ble", layoutId: 1, title: nil, hasHR: false)
        }
        let lo = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let hi = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let logs = [log(session: lo, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 0),
                    log(session: hi, grade: "7a/V6", diff: 24, status: .sent, daysAgo: 0)]
        // id-sorted: lo before hi, so hi sees lo's 18 as prior; lo (earliest) has no prior. Stable across runs.
        for _ in 0..<8 {
            let prior = KilterHistoryModel.priorHardestBySession([s(hi), s(lo)],   // input order shuffled
                                                                 logsBySession: logsBySession(logs))
            XCTAssertNil(prior[lo], "id-earliest session has no prior")
            XCTAssertEqual(prior[hi], 18, "id-later session's prior is the id-earlier one's hardest")
        }
    }

    // MARK: - FG: scope-aware stale-filter recovery

    func testStaleFilterSuggestsWidenScopeWhenMatchInAnotherPeriod() {
        // A 40-day-old session matches the angle filter, but Month scope hides it → widen, don't clear.
        let old = session(UUID(), daysAgo: 40, angle: 25)
        let logs = [log(session: old.id, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 40, angle: 25)]
        let model = KilterHistoryModel.build(sessions: [old], logs: logs, scope: .month,
                                             filters: filters(.angle, "25°"), now: now, calendar: cal)
        XCTAssertTrue(model.groups.isEmpty, "no 25° session in the current month")
        XCTAssertEqual(model.staleRecovery, .widenScope,
                       "the filter matches a session in another period → widen scope, not clear")
        XCTAssertTrue(model.isStaleFilter)
    }

    func testStaleFilterSuggestsClearWhenNoMatchAnywhere() {
        // A filter that matches NOTHING anywhere → clear filters.
        let s = session(UUID(), daysAgo: 1, angle: 40)
        let logs = [log(session: s.id, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1, angle: 40)]
        let model = KilterHistoryModel.build(sessions: [s], logs: logs, scope: .month,
                                             filters: filters(.angle, "70°"), now: now, calendar: cal)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.staleRecovery, .clearFilters,
                       "a filter that matches nothing anywhere → clear filters")
    }

    func testNoRecoveryWhenScopeHasMatches() {
        let s = session(UUID(), daysAgo: 1, angle: 40)
        let logs = [log(session: s.id, grade: "6a/V3", diff: 18, status: .sent, daysAgo: 1, angle: 40)]
        let model = KilterHistoryModel.build(sessions: [s], logs: logs, scope: .month,
                                             filters: filters(.angle, "40°"), now: now, calendar: cal)
        XCTAssertFalse(model.groups.isEmpty)
        XCTAssertEqual(model.staleRecovery, .none)
    }

    // MARK: - Helpers

    private func filters(_ facet: KilterHistoryModel.Facet, _ value: String) -> KilterHistoryModel.Filters {
        var f = KilterHistoryModel.Filters(); f.selections[facet] = value; return f
    }
    private func logsBySession(_ logs: [KilterClimbLog]) -> [UUID: [KilterClimbLog]] {
        Dictionary(grouping: logs.compactMap { l in l.sessionId.map { ($0, l) } }, by: { $0.0 })
            .mapValues { $0.map(\.1) }
    }
}

// MARK: - Backup migration + round-trip for the new KilterSession fields

@MainActor
final class KilterSessionBackupMigrationTests: XCTestCase {

    // Held as properties: a `ModelContext` does NOT retain its `ModelContainer` — letting the container
    // deallocate makes every later SwiftData call trap (the same gotcha SnappetBackupTests documents).
    private var sourceContainer: ModelContainer!
    private var targetContainer: ModelContainer!

    override func setUpWithError() throws {
        sourceContainer = try makeContainer()
        targetContainer = try makeContainer()
    }
    override func tearDown() {
        sourceContainer = nil
        targetContainer = nil
        super.tearDown()
    }

    private nonisolated func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(SnappetSchema.models),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    // MARK: - FA: date edit shifts the whole session + its logs by one delta (relative offsets preserved)

    func testDateShiftPreservesRelativeLogOffsets() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)            // +1h
        let session = KilterSession(startedAt: start, endedAt: end, angle: 40, source: "ble")

        // Two child logs at fixed offsets from the original start (the HR axis is rebased on `startedAt`,
        // so these offsets are what must be preserved).
        let l1Started = start.addingTimeInterval(300)        // +5m
        let l1Ended = start.addingTimeInterval(600)          // +10m
        let l1Attempts = [start.addingTimeInterval(330), start.addingTimeInterval(420)]
        let e1 = KilterLogEntry(climbUUID: "a", climbName: "A", angle: 40, difficulty: 18,
                                gradeLabel: "6a/V3", status: .sent, date: l1Ended,
                                startedAt: l1Started, endedAt: l1Ended, attemptTimestamps: l1Attempts)
        let e2 = KilterLogEntry(climbUUID: "b", climbName: "B", angle: 40, difficulty: 20,
                                gradeLabel: "6b/V4", status: .project, date: start.addingTimeInterval(1800),
                                startedAt: start.addingTimeInterval(1500), endedAt: start.addingTimeInterval(1800))

        // Shift the session back by 2 days.
        let newStart = start.addingTimeInterval(-2 * 86_400)
        KilterSessionMetaEditSheet.applyDateShift(to: session, entries: [e1, e2], newStart: newStart)

        let delta = newStart.timeIntervalSince(start)   // -172800
        XCTAssertEqual(session.startedAt, newStart)
        XCTAssertEqual(session.endedAt, end.addingTimeInterval(delta))
        XCTAssertLessThan(session.startedAt, session.endedAt!, "interval stays valid (start < end)")
        // Every log offset RELATIVE to the new start equals its original offset relative to the old start.
        XCTAssertEqual(e1.startedAt!.timeIntervalSince(session.startedAt), l1Started.timeIntervalSince(start), accuracy: 0.001)
        XCTAssertEqual(e1.endedAt!.timeIntervalSince(session.startedAt), l1Ended.timeIntervalSince(start), accuracy: 0.001)
        XCTAssertEqual(e1.date.timeIntervalSince(session.startedAt), l1Ended.timeIntervalSince(start), accuracy: 0.001)
        XCTAssertEqual(e1.attemptTimestamps.map { $0.timeIntervalSince(session.startedAt) },
                       l1Attempts.map { $0.timeIntervalSince(start) })
        XCTAssertEqual(e2.startedAt!.timeIntervalSince(session.startedAt), 1500, accuracy: 0.001)
        XCTAssertEqual(e2.date.timeIntervalSince(session.startedAt), 1800, accuracy: 0.001)
    }

    func testDateShiftZeroDeltaIsNoOp() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = KilterSession(startedAt: start, endedAt: start.addingTimeInterval(3600),
                                    angle: 40, source: "ble")
        let e = KilterLogEntry(climbUUID: "a", climbName: "A", angle: 40, difficulty: 18,
                               gradeLabel: "6a/V3", status: .sent, date: start.addingTimeInterval(600))
        KilterSessionMetaEditSheet.applyDateShift(to: session, entries: [e], newStart: start)
        XCTAssertEqual(session.startedAt, start)
        XCTAssertEqual(e.date, start.addingTimeInterval(600), "no shift when the date is unchanged")
    }

    /// The P4 additive `title`/`notes`/`layoutId` survive a full encode→decode→restore round trip.
    func testNewKilterSessionFieldsRoundTrip() throws {
        let source = sourceContainer.mainContext
        let id = UUID()
        source.insert(KilterSession(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    endedAt: Date(timeIntervalSince1970: 1_700_003_600),
                                    angle: 45, source: "ble",
                                    title: "Comp prep", notes: "Felt strong; flashed the warmups.",
                                    layoutId: 7))
        try source.save()

        let data = try SnappetBackup.encode(try SnappetBackup.snapshot(of: source))
        let target = targetContainer.mainContext
        try SnappetBackup.restore(try SnappetBackup.decode(data), into: target)

        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<KilterSession>()).first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.title, "Comp prep")
        XCTAssertEqual(restored.notes, "Felt strong; flashed the warmups.")
        XCTAssertEqual(restored.layoutId, 7)
    }

    /// A PRE-CHANGE backup blob (a `kilterSessions` row with NO `title`/`notes`/`layoutId` keys) must
    /// still decode — the synthesized Decodable skips the absent optionals to their nil defaults, exactly
    /// mirroring the SwiftData lightweight migration. Locks back-compat with backups made before P4.
    ///
    /// The blob is built by encoding a REAL backup (so every other model's array is structurally valid)
    /// then STRIPPING the three P4 keys from the JSON — a faithful "this file was written by a pre-P4
    /// build" fixture, not a hand-typed partial that could trip the strict same-version `.damaged` guard.
    func testPreChangeBlobDecodesWithNilNewFields() throws {
        let source = sourceContainer.mainContext
        let id = UUID()
        source.insert(KilterSession(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    angle: 40, source: "manual",
                                    title: "should be stripped", notes: "gone", layoutId: 9))
        try source.save()

        var json = String(decoding: try SnappetBackup.encode(try SnappetBackup.snapshot(of: source)),
                          as: UTF8.self)
        // Remove the P4 keys to simulate a backup written before they existed.
        for key in ["title", "notes", "layoutId"] {
            json = json.replacingOccurrences(
                of: #""\#(key)":("[^"]*"|\d+)(,)?"#, with: "", options: .regularExpression)
        }
        XCTAssertFalse(json.contains("\"title\""), "the pre-change blob must not carry the P4 keys")
        XCTAssertFalse(json.contains("\"layoutId\":9"))

        let file = try SnappetBackup.decode(Data(json.utf8))
        let row = try XCTUnwrap(file.kilterSessions.first { $0.id == id })
        XCTAssertEqual(row.angle, 40)
        XCTAssertNil(row.title, "absent key decodes to the nil default")
        XCTAssertNil(row.notes)
        XCTAssertNil(row.layoutId)

        // And it restores cleanly into a real store with the new fields nil.
        let target = targetContainer.mainContext
        try SnappetBackup.restore(file, into: target)
        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<KilterSession>()).first { $0.id == id })
        XCTAssertNil(restored.title)
        XCTAssertNil(restored.layoutId)
    }
}
