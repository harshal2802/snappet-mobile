import XCTest
@testable import Snappet

/// Unit tests for the widget check-off path's PURE pieces (#81 Phase 2): the `HabitToggle` codec and
/// the `HabitCheckoffReconciler` plan that turns drained outbox toggles into SwiftData inserts/
/// deletes. The App-Group directory I/O (`WidgetOutbox` append/pending/remove) is the thin device
/// edge and isn't unit-tested; the planning logic that decides what to persist is what matters and is
/// fully covered here — idempotent, order-tolerant, no-op-when-in-sync.
final class WidgetOutboxTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let day = Date(timeIntervalSince1970: 1_781_092_800)   // 2026-06-10 12:00 UTC
    private func at(_ secs: TimeInterval) -> Date { day.addingTimeInterval(secs) }
    private func key(_ habit: UUID) -> HabitCheckoffReconciler.CompletionKey {
        .init(habitID: habit, day: cal.startOfDay(for: day))
    }

    // MARK: - HabitToggle codec

    func testHabitToggleRoundTrips() throws {
        let original = HabitToggle(habitID: UUID(), day: day, desired: true, requestedAt: at(5))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HabitToggle.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Reconciler plan

    func testInsertsWhenDesiredAndAbsent() {
        let h = UUID()
        let plan = HabitCheckoffReconciler.plan(
            toggles: [HabitToggle(habitID: h, day: day, desired: true, requestedAt: at(1))],
            existing: [], calendar: cal)
        XCTAssertEqual(plan.inserts, [key(h)])
        XCTAssertEqual(plan.deletes, [])
    }

    func testDeletesWhenNotDesiredAndPresent() {
        let h = UUID()
        let plan = HabitCheckoffReconciler.plan(
            toggles: [HabitToggle(habitID: h, day: day, desired: false, requestedAt: at(1))],
            existing: [key(h)], calendar: cal)
        XCTAssertEqual(plan.inserts, [])
        XCTAssertEqual(plan.deletes, [key(h)])
    }

    func testNoOpWhenAlreadyInSync() {
        let h1 = UUID(), h2 = UUID()
        // h1 wants done and already is; h2 wants not-done and already isn't.
        let plan = HabitCheckoffReconciler.plan(
            toggles: [
                HabitToggle(habitID: h1, day: day, desired: true, requestedAt: at(1)),
                HabitToggle(habitID: h2, day: day, desired: false, requestedAt: at(2)),
            ],
            existing: [key(h1)], calendar: cal)
        XCTAssertEqual(plan.inserts, [])
        XCTAssertEqual(plan.deletes, [])
    }

    func testLastDesiredStatePerKeyWins() {
        let h = UUID()
        // Toggle on, then off (older first) → net off → with nothing existing, that's a no-op.
        let plan = HabitCheckoffReconciler.plan(
            toggles: [
                HabitToggle(habitID: h, day: day, desired: true, requestedAt: at(1)),
                HabitToggle(habitID: h, day: day, desired: false, requestedAt: at(2)),
            ],
            existing: [], calendar: cal)
        XCTAssertEqual(plan.inserts, [])
        XCTAssertEqual(plan.deletes, [])
    }

    func testLastWriteWinsIsOrderIndependent() {
        let h = UUID()
        // Same two toggles, supplied newest-first — the requestedAt sort still makes "on" win last.
        let plan = HabitCheckoffReconciler.plan(
            toggles: [
                HabitToggle(habitID: h, day: day, desired: false, requestedAt: at(1)),
                HabitToggle(habitID: h, day: day, desired: true, requestedAt: at(2)),
            ].shuffled(),
            existing: [], calendar: cal)
        XCTAssertEqual(plan.inserts, [key(h)])   // final desired = true (the at(2) request)
        XCTAssertEqual(plan.deletes, [])
    }

    func testDayIsNormalisedToStartOfDay() {
        let h = UUID()
        // A toggle stamped mid-afternoon still keys to that day's start-of-day.
        let plan = HabitCheckoffReconciler.plan(
            toggles: [HabitToggle(habitID: h, day: at(9 * 3600), desired: true, requestedAt: at(1))],
            existing: [], calendar: cal)
        XCTAssertEqual(plan.inserts, [key(h)])
    }

    func testMixedInsertsAndDeletesAcrossHabits() {
        let add = UUID(), remove = UUID(), keep = UUID()
        let plan = HabitCheckoffReconciler.plan(
            toggles: [
                HabitToggle(habitID: add, day: day, desired: true, requestedAt: at(1)),
                HabitToggle(habitID: remove, day: day, desired: false, requestedAt: at(2)),
                HabitToggle(habitID: keep, day: day, desired: true, requestedAt: at(3)),
            ],
            existing: [key(remove), key(keep)], calendar: cal)
        XCTAssertEqual(plan.inserts, [key(add)])
        XCTAssertEqual(plan.deletes, [key(remove)])
    }
}
