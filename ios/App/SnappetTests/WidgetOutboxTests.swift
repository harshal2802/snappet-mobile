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
    private func insert(_ habit: UUID, at secs: TimeInterval) -> HabitCheckoffReconciler.Insert {
        .init(key: key(habit), loggedAt: at(secs))
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
            existing: [], liveHabitIDs: [h], calendar: cal)
        XCTAssertEqual(plan.inserts, [insert(h, at: 1)])   // loggedAt = the tap time
        XCTAssertEqual(plan.deletes, [])
    }

    func testDeletesWhenNotDesiredAndPresent() {
        let h = UUID()
        let plan = HabitCheckoffReconciler.plan(
            toggles: [HabitToggle(habitID: h, day: day, desired: false, requestedAt: at(1))],
            existing: [key(h)], liveHabitIDs: [h], calendar: cal)
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
            existing: [key(h1)], liveHabitIDs: [h1, h2], calendar: cal)
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
            existing: [], liveHabitIDs: [h], calendar: cal)
        XCTAssertEqual(plan.inserts, [])
        XCTAssertEqual(plan.deletes, [])
    }

    func testLastWriteWinsIsOrderIndependent() {
        let h = UUID()
        // Same two toggles, supplied newest-first — the requestedAt sort still makes "on" win last,
        // and loggedAt is that final desired-DONE request's time (at(2)).
        let plan = HabitCheckoffReconciler.plan(
            toggles: [
                HabitToggle(habitID: h, day: day, desired: false, requestedAt: at(1)),
                HabitToggle(habitID: h, day: day, desired: true, requestedAt: at(2)),
            ].shuffled(),
            existing: [], liveHabitIDs: [h], calendar: cal)
        XCTAssertEqual(plan.inserts, [insert(h, at: 2)])
        XCTAssertEqual(plan.deletes, [])
    }

    func testDayIsNormalisedToStartOfDay() {
        let h = UUID()
        // A toggle stamped mid-afternoon still keys to that day's start-of-day (but loggedAt keeps
        // the precise tap time for the activity log).
        let plan = HabitCheckoffReconciler.plan(
            toggles: [HabitToggle(habitID: h, day: at(9 * 3600), desired: true, requestedAt: at(9 * 3600))],
            existing: [], liveHabitIDs: [h], calendar: cal)
        XCTAssertEqual(plan.inserts, [insert(h, at: 9 * 3600)])
    }

    /// Orphan guard: a check-ON for a habit that no longer exists (stale snapshot) is dropped, so
    /// reconciliation can't leave a dangling HabitCompletion behind.
    func testOrphanInsertForDeletedHabitIsDropped() {
        let gone = UUID(), live = UUID()
        let plan = HabitCheckoffReconciler.plan(
            toggles: [
                HabitToggle(habitID: gone, day: day, desired: true, requestedAt: at(1)),
                HabitToggle(habitID: live, day: day, desired: true, requestedAt: at(2)),
            ],
            existing: [], liveHabitIDs: [live], calendar: cal)   // `gone` not live
        XCTAssertEqual(plan.inserts, [insert(live, at: 2)])
        XCTAssertEqual(plan.deletes, [])
    }

    func testMixedInsertsAndDeletesAcrossHabits() {
        let add = UUID(), remove = UUID(), keep = UUID()
        let plan = HabitCheckoffReconciler.plan(
            toggles: [
                HabitToggle(habitID: add, day: day, desired: true, requestedAt: at(1)),
                HabitToggle(habitID: remove, day: day, desired: false, requestedAt: at(2)),
                HabitToggle(habitID: keep, day: day, desired: true, requestedAt: at(3)),
            ],
            existing: [key(remove), key(keep)], liveHabitIDs: [add, remove, keep], calendar: cal)
        XCTAssertEqual(plan.inserts, [insert(add, at: 1)])
        XCTAssertEqual(plan.deletes, [key(remove)])
    }
}
