import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the home-screen widgets' read path (#81 Phase 1): the **pure** snapshot codec
/// (`WidgetSnapshotStore.encode`/`decode`), its migration-safe defaulting decode, and the pure
/// `WidgetSnapshotBuilder` — which must reproduce the same Today facts the app shows
/// (`TodayDigest` / `HabitMilestones`). No App-Group container is touched (that's the device-pending
/// file edge); everything here runs on the simulator with no entitlement/provisioning.
@MainActor
final class WidgetSnapshotTests: XCTestCase {

    /// Held as a property: a `ModelContext` does not retain its `ModelContainer`, so a deallocated
    /// container traps later SwiftData calls (the repo's standard gotcha). Rows are inserted to be
    /// container-backed even though the builder is pure.
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    /// Fixed, DST-free clock: 2026-06-10 12:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_781_092_800)
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private var todayStart: Date { cal.startOfDay(for: now) }
    private func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func sampleSnapshot() -> SnappetWidgetSnapshot {
        SnappetWidgetSnapshot(
            generatedAt: now, dayStart: todayStart,
            habits: [
                .init(id: UUID(), name: "Read", symbol: "book", doneToday: true),
                .init(id: UUID(), name: "Run", symbol: "figure.run", doneToday: false),
            ],
            dayStreak: 4, focusMinutesToday: 50)
    }

    // MARK: - Codec

    func testCodecRoundTrips() throws {
        let original = sampleSnapshot()
        let decoded = try XCTUnwrap(WidgetSnapshotStore.decode(WidgetSnapshotStore.encode(original)))
        XCTAssertEqual(decoded, original)
        // Computed conveniences the widget renders.
        XCTAssertEqual(decoded.habitsRemaining, 1)
        XCTAssertEqual(decoded.habitsTotal, 2)
        XCTAssertFalse(decoded.allHabitsDone)
    }

    func testDecodeRejectsCorruptBytes() {
        XCTAssertNil(WidgetSnapshotStore.decode(Data("not json".utf8)))
    }

    /// A snapshot written by an OLDER app build (missing keys added later) must decode with
    /// defaults, never crash the widget — the repo's migration-safe Codable discipline.
    func testDecodeToleratesMissingKeys() throws {
        let data = try WidgetSnapshotStore.encode(sampleSnapshot())
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "habits")
        obj.removeValue(forKey: "dayStreak")
        obj.removeValue(forKey: "focusMinutesToday")
        let trimmed = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try XCTUnwrap(WidgetSnapshotStore.decode(trimmed))
        XCTAssertEqual(decoded.habits, [])
        XCTAssertEqual(decoded.dayStreak, 0)
        XCTAssertEqual(decoded.focusMinutesToday, 0)
    }

    /// A snapshot from a NEWER contract version than this binary understands is rejected (→ nil), so
    /// the widget shows its placeholder instead of misreading fields it can't trust.
    func testDecodeRejectsFutureVersion() throws {
        let data = try WidgetSnapshotStore.encode(sampleSnapshot())
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["version"] = SnappetWidgetSnapshot.currentVersion + 1
        let future = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(WidgetSnapshotStore.decode(future))
    }

    func testEmptyFactoryIsNeverAllDone() {
        // The "no data yet" state a fresh widget shows — and the non-obvious allHabitsDone guard:
        // zero habits must NOT read as "all done".
        let s = SnappetWidgetSnapshot.empty(now: now, calendar: cal)
        XCTAssertEqual(s.habits, [])
        XCTAssertEqual(s.habitsTotal, 0)
        XCTAssertEqual(s.habitsRemaining, 0)
        XCTAssertFalse(s.allHabitsDone)        // guard: !habits.isEmpty
        XCTAssertEqual(s.dayStreak, 0)
        XCTAssertEqual(s.dayStart, todayStart)
    }

    // MARK: - Staleness (resolvedForDisplay)

    func testResolvedForDisplayIsIdentityWhenBuiltToday() {
        let s = SnappetWidgetSnapshot(
            generatedAt: now, dayStart: todayStart,
            habits: [.init(id: UUID(), name: "Read", symbol: "book", doneToday: true)],
            dayStreak: 5, focusMinutesToday: 30)
        XCTAssertEqual(s.resolvedForDisplay(now: now, calendar: cal), s)
    }

    func testResolvedForDisplayNeutralisesAStaleSnapshot() {
        // Built yesterday: "all done", a streak, focus minutes — none of which apply to today.
        let stale = SnappetWidgetSnapshot(
            generatedAt: daysAgo(1), dayStart: cal.startOfDay(for: daysAgo(1)),
            habits: [
                .init(id: UUID(), name: "Read", symbol: "book", doneToday: true),
                .init(id: UUID(), name: "Run", symbol: "figure.run", doneToday: true),
            ],
            dayStreak: 5, focusMinutesToday: 30)

        let shown = stale.resolvedForDisplay(now: now, calendar: cal)
        XCTAssertEqual(shown.dayStart, todayStart)
        XCTAssertTrue(shown.habits.allSatisfy { !$0.doneToday })   // no yesterday checkmarks today
        XCTAssertEqual(shown.habitsRemaining, 2)
        XCTAssertFalse(shown.allHabitsDone)                        // not "all done" after midnight
        XCTAssertEqual(shown.dayStreak, 0)
        XCTAssertEqual(shown.focusMinutesToday, 0)
        XCTAssertEqual(shown.habits.map(\.name), ["Read", "Run"])  // identities preserved
    }

    // MARK: - Builder

    func testBuilderEmptyWithNoRows() {
        let s = WidgetSnapshotBuilder.build(records: [], habits: [], completions: [],
                                            focusSessions: [], now: now, calendar: cal)
        XCTAssertEqual(s.habits, [])
        XCTAssertEqual(s.habitsTotal, 0)
        XCTAssertFalse(s.allHabitsDone)        // no habits ⇒ not "all done"
        XCTAssertEqual(s.dayStreak, 0)
        XCTAssertEqual(s.focusMinutesToday, 0)
        XCTAssertEqual(s.dayStart, todayStart)
        XCTAssertEqual(s.version, SnappetWidgetSnapshot.currentVersion)
    }

    func testBuilderReproducesTodayFacts() {
        let read = Habit(name: "Read", symbol: "book")
        let run = Habit(name: "Run", symbol: "figure.run")
        for row in [read, run] { context.insert(row) }

        // Both habits done today.
        let completions = [
            HabitCompletion(habitID: read.id, day: todayStart),
            HabitCompletion(habitID: run.id, day: todayStart),
        ]
        for row in completions { context.insert(row) }

        let focus = [
            PomodoroSession(minutes: 25, completedAt: todayStart.addingTimeInterval(8 * 3600)),
            PomodoroSession(minutes: 15, completedAt: todayStart.addingTimeInterval(11 * 3600)),
            PomodoroSession(minutes: 99, completedAt: daysAgo(1)),   // yesterday — excluded
        ]
        for row in focus { context.insert(row) }

        let s = WidgetSnapshotBuilder.build(records: [], habits: [read, run],
                                            completions: completions, focusSessions: focus,
                                            now: now, calendar: cal)

        // Parity with TodayDigest.habitsToday: both done today → 0 remaining.
        XCTAssertEqual(s.habitsTotal, 2)
        XCTAssertEqual(s.habitsRemaining, 0)
        XCTAssertTrue(s.allHabitsDone)
        XCTAssertEqual(Set(s.habits.map(\.name)), ["Read", "Run"])
        XCTAssertTrue(s.habits.allSatisfy(\.doneToday))
        XCTAssertEqual(s.habits.first { $0.name == "Read" }?.symbol, "book")
        // TodayDigest.focusToday parity: only today's blocks (25 + 15).
        XCTAssertEqual(s.focusMinutesToday, 40)
    }

    /// The widget's `dayStreak` is the SAME suite-engagement streak Home shows: consecutive days
    /// ending today with a logged action — derived from UsageRecords via `TodayDigest.activityStreak`
    /// (not a habit streak), so the widget can't diverge from the Home dashboard.
    func testBuilderDayStreakMatchesActivityStreak() {
        let records = [
            UsageRecord(module: "habit", action: "done", summary: "a",
                        timestamp: todayStart.addingTimeInterval(9 * 3600)),
            UsageRecord(module: "pomodoro", action: "session", summary: "b",
                        timestamp: cal.startOfDay(for: daysAgo(1))),
            UsageRecord(module: "budget", action: "entry", summary: "c",
                        timestamp: cal.startOfDay(for: daysAgo(2))),
            // gap at day 3 — the streak must stop here…
            UsageRecord(module: "journal", action: "entry", summary: "d",
                        timestamp: cal.startOfDay(for: daysAgo(4))),   // …so this doesn't count
        ]
        for row in records { context.insert(row) }

        let s = WidgetSnapshotBuilder.build(records: records, habits: [], completions: [],
                                            focusSessions: [], now: now, calendar: cal)
        XCTAssertEqual(s.dayStreak, 3)
        // Exact parity with the shared pure function Home routes through.
        XCTAssertEqual(s.dayStreak,
                       TodayDigest.activityStreak(records: records, now: now, calendar: cal))
    }

    func testBuilderHabitsRemainingMatchesTodayDigest() {
        // A habit done only yesterday is still "remaining" today.
        let stretch = Habit(name: "Stretch", symbol: "figure.flexibility")
        context.insert(stretch)
        let doneYesterday = HabitCompletion(habitID: stretch.id, day: cal.startOfDay(for: daysAgo(1)))
        context.insert(doneYesterday)

        let s = WidgetSnapshotBuilder.build(records: [], habits: [stretch],
                                            completions: [doneYesterday],
                                            focusSessions: [], now: now, calendar: cal)
        let digest = TodayDigest.habitsToday(habits: [stretch], completions: [doneYesterday],
                                             now: now, calendar: cal)
        XCTAssertEqual(s.habitsRemaining, digest?.remaining)   // 1 == 1
        XCTAssertFalse(s.habits.first?.doneToday ?? true)
        // No activity records → no engagement streak (independent of habit completions).
        XCTAssertEqual(s.dayStreak, 0)
    }

    /// Today has no logged action → the engagement streak is 0 even if earlier days had activity
    /// (the strict "ending today" rule, matching HomeDashboardView).
    func testBuilderDayStreakZeroWhenNothingToday() {
        let records = [
            UsageRecord(module: "habit", action: "done", summary: "a",
                        timestamp: cal.startOfDay(for: daysAgo(1))),
            UsageRecord(module: "habit", action: "done", summary: "b",
                        timestamp: cal.startOfDay(for: daysAgo(2))),
        ]
        for row in records { context.insert(row) }
        let s = WidgetSnapshotBuilder.build(records: records, habits: [], completions: [],
                                            focusSessions: [], now: now, calendar: cal)
        XCTAssertEqual(s.dayStreak, 0)
    }
}
