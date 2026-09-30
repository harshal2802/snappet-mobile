import XCTest
import SwiftData
@testable import Snappet

/// Prompt 137 — the SwiftData edge of the routine ↔ habit link: create/attach, tick-off on finish
/// (idempotent, un-skips), skip recording, and unlink keeping history.
@MainActor
final class HabitRoutineLinkTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    private func completions() -> [HabitCompletion] { (try? context.fetch(FetchDescriptor<HabitCompletion>())) ?? [] }
    private func habits() -> [Habit] { (try? context.fetch(FetchDescriptor<Habit>())) ?? [] }

    func testNewHabitIsCreatedNamedAfterTheRoutine() {
        let r = Routine(name: "Push Day")
        context.insert(r)
        let h = HabitRoutineLink.apply(.newHabit, to: r, in: context, core: nil)
        XCTAssertEqual(h?.name, "Push Day")
        XCTAssertEqual(r.linkedHabitID, h?.id)
        XCTAssertEqual(habits().count, 1)
    }

    func testSeveralRoutinesCanShareOneHabit() {
        let gym = Habit(name: "Gym")
        let a = Routine(name: "Push"), b = Routine(name: "Pull")
        [a, b].forEach(context.insert)
        context.insert(gym)
        HabitRoutineLink.apply(.existing(gym.id), to: a, in: context, core: nil)
        HabitRoutineLink.apply(.existing(gym.id), to: b, in: context, core: nil)
        XCTAssertEqual(habits().count, 1)
        HabitRoutineLink.markDone(routine: a, day: .now, in: context, core: nil)
        HabitRoutineLink.markDone(routine: b, day: .now, in: context, core: nil)
        XCTAssertEqual(completions().count, 1, "two workouts on one day tick the shared habit once")
    }

    func testMarkDoneIsIdempotentAndClearsASkip() throws {
        let r = Routine(name: "Legs")
        context.insert(r)
        let h = try XCTUnwrap(HabitRoutineLink.apply(.newHabit, to: r, in: context, core: nil))
        let today = DayKey(.now)
        HabitRoutineLink.recordSkip(routine: r, day: today, in: context)
        XCTAssertEqual(h.skippedDayKeys, [today.value])
        HabitRoutineLink.markDone(routine: r, day: .now, in: context, core: nil)
        HabitRoutineLink.markDone(routine: r, day: .now, in: context, core: nil)
        XCTAssertEqual(completions().count, 1)
        XCTAssertEqual(h.skippedDayKeys ?? [], [], "training after skipping un-skips the day")
    }

    func testUnlinkedRoutineTouchesNoHabit() {
        let r = Routine(name: "Solo")
        context.insert(r)
        HabitRoutineLink.markDone(routine: r, day: .now, in: context, core: nil)
        HabitRoutineLink.recordSkip(routine: r, day: DayKey(.now), in: context)
        XCTAssertTrue(completions().isEmpty)
        XCTAssertTrue(habits().isEmpty)
    }

    func testUnlinkAllKeepsTheHabitAndItsHistory() throws {
        let r = Routine(name: "Core")
        context.insert(r)
        let h = try XCTUnwrap(HabitRoutineLink.apply(.newHabit, to: r, in: context, core: nil))
        HabitRoutineLink.markDone(routine: r, day: .now, in: context, core: nil)
        try context.save()
        HabitRoutineLink.unlinkAll(habitID: h.id, in: context)
        XCTAssertNil(r.linkedHabitID)
        XCTAssertEqual(habits().count, 1)
        XCTAssertEqual(completions().count, 1)
    }
}
