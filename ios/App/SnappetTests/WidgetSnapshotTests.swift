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

    // MARK: - Builder

    func testBuilderEmptyWithNoRows() {
        let s = WidgetSnapshotBuilder.build(habits: [], completions: [], focusSessions: [],
                                            now: now, calendar: cal)
        XCTAssertEqual(s.habits, [])
        XCTAssertEqual(s.dayStreak, 0)
        XCTAssertEqual(s.focusMinutesToday, 0)
        XCTAssertEqual(s.dayStart, todayStart)
        XCTAssertEqual(s.version, SnappetWidgetSnapshot.currentVersion)
    }

    func testBuilderReproducesTodayFactsAndBestStreak() {
        let read = Habit(name: "Read", symbol: "book")
        let run = Habit(name: "Run", symbol: "figure.run")
        for row in [read, run] { context.insert(row) }

        // Read: today + yesterday + 2 days ago → current streak 3, done today.
        // Run: today only → current streak 1, done today.
        var completions: [HabitCompletion] = []
        for d in [0, 1, 2] {
            completions.append(HabitCompletion(habitID: read.id, day: cal.startOfDay(for: daysAgo(d))))
        }
        completions.append(HabitCompletion(habitID: run.id, day: todayStart))
        for row in completions { context.insert(row) }

        let focus = [
            PomodoroSession(minutes: 25, completedAt: todayStart.addingTimeInterval(8 * 3600)),
            PomodoroSession(minutes: 15, completedAt: todayStart.addingTimeInterval(11 * 3600)),
            PomodoroSession(minutes: 99, completedAt: daysAgo(1)),   // yesterday — excluded
        ]
        for row in focus { context.insert(row) }

        let s = WidgetSnapshotBuilder.build(habits: [read, run], completions: completions,
                                            focusSessions: focus, now: now, calendar: cal)

        // Parity with TodayDigest.habitsToday: both done today → 0 remaining.
        XCTAssertEqual(s.habitsTotal, 2)
        XCTAssertEqual(s.habitsRemaining, 0)
        XCTAssertTrue(s.allHabitsDone)
        XCTAssertEqual(Set(s.habits.map(\.name)), ["Read", "Run"])
        XCTAssertTrue(s.habits.allSatisfy(\.doneToday))
        XCTAssertEqual(s.habits.first { $0.name == "Read" }?.symbol, "book")

        // Best current streak across habits (Read's 3 beats Run's 1).
        XCTAssertEqual(s.dayStreak, 3)
        // TodayDigest.focusToday parity: only today's blocks (25 + 15).
        XCTAssertEqual(s.focusMinutesToday, 40)
    }

    func testBuilderHabitsRemainingMatchesTodayDigest() {
        // A habit done only yesterday is still "remaining" today.
        let stretch = Habit(name: "Stretch", symbol: "figure.flexibility")
        context.insert(stretch)
        let doneYesterday = HabitCompletion(habitID: stretch.id, day: cal.startOfDay(for: daysAgo(1)))
        context.insert(doneYesterday)

        let s = WidgetSnapshotBuilder.build(habits: [stretch], completions: [doneYesterday],
                                            focusSessions: [], now: now, calendar: cal)
        let digest = TodayDigest.habitsToday(habits: [stretch], completions: [doneYesterday],
                                             now: now, calendar: cal)
        XCTAssertEqual(s.habitsRemaining, digest?.remaining)   // 1 == 1
        XCTAssertFalse(s.habits.first?.doneToday ?? true)
        // The streak stays alive (yesterday) even though it's not done today.
        XCTAssertEqual(s.dayStreak, 1)
    }
}
