import XCTest
@testable import Snappet

/// Created-but-not-logged activities (Library redesign L4a, prompt 186).
final class LibraryCreateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func climbParams(_ name: String) -> AddClimbParams {
        AddClimbParams(type: .boulder, scale: .vScale, grade: "V6", name: name, gym: "Gravity", wall: "Cave", color: .red)
    }

    private func session(daysAgo: Double, _ ex: [SessionExercise]) -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        let done = ex.map { e -> SessionExercise in
            var e = e
            if e.sets.isEmpty { e.sets = [SetLog(climbGradeLabel: e.climbGradeLabel, climbStatusRaw: "attempt")] }
            for i in e.sets.indices { e.sets[i].completedAt = start }
            return e
        }
        return WorkoutSession(routineName: "S", startedAt: start, completedAt: start.addingTimeInterval(3600), exercises: done)
    }

    private func rows(_ history: [WorkoutSession], created: [LibraryCatalog.CreatedInput]) -> [LibraryCatalog.Row] {
        LibraryCatalog.yours(history: history, identity: ActivityIdentity(sessions: history, resetDays: 28), unit: .kg,
                             now: now, created: created, title: LibraryCatalog.fallbackTitle)
    }

    private func created(_ ex: SessionExercise, daysAgo: Double, meters: Double? = nil,
                         history: [WorkoutSession] = []) -> LibraryCatalog.CreatedInput {
        let at = now.addingTimeInterval(-daysAgo * 86_400)
        let key = ActivityIdentity(sessions: history, resetDays: 28).key(for: ex, loggedAt: at)!
        return .init(key: key, template: LibraryTemplate(exercise: ex, targetDistanceMeters: meters), createdAt: at)
    }

    func testACreatedClimbShowsAsNotDoneYet() throws {
        let c = created(LibraryCreate.climb(climbParams("Red roof")), daysAgo: 3)
        let row = try XCTUnwrap(rows([], created: [c]).first)
        XCTAssertTrue(row.notDoneYet)
        XCTAssertEqual(row.title, "Red roof")
        XCTAssertEqual(row.climb?.grade, "V6")
        XCTAssertEqual(row.sessions, 0)
    }

    func testLoggingTheCreatedClimbReplacesItsRow() {
        let template = LibraryCreate.climb(climbParams("Red roof"))
        let c = created(template, daysAgo: 5)
        var logged = template; logged.id = UUID()
        let history = [session(daysAgo: 2, [logged])]
        let r = rows(history, created: [c])
        XCTAssertEqual(r.count, 1, "the logged climb replaces the 'not done yet' one")
        XCTAssertFalse(r[0].notDoneYet)
    }

    func testAnOlderLogOfTheSameNameDoesntHideANewlyCreatedClimb() {
        // Logged 60 days ago (an earlier set), created again today: still a new project.
        var old = LibraryCreate.climb(climbParams("Red roof")); old.id = UUID()
        let history = [session(daysAgo: 60, [old])]
        let c = created(LibraryCreate.climb(climbParams("Red roof")), daysAgo: 0, history: history)
        XCTAssertEqual(rows(history, created: [c]).filter(\.notDoneYet).count, 1)
    }

    func testARunRouteShowsItsDistance() throws {
        let c = created(LibraryCreate.named("Riverside 5k", discipline: .run), daysAgo: 1, meters: 5_000)
        let row = try XCTUnwrap(rows([], created: [c]).first)
        XCTAssertEqual(row.discipline, .run)
        XCTAssertEqual(row.headline, "5 km · not done yet")
    }

    func testLogItNowAndAddToRoutineUseTheTemplate() throws {
        let t = LibraryTemplate(exercise: LibraryCreate.named("Riverside 5k", discipline: .run), targetDistanceMeters: 5_000)
        let key = ActivityKey(exerciseId: "adhoc-run", nameKey: "riverside 5k")
        let ids = ActivityIdentity(sessions: [])
        let ex = try XCTUnwrap(ActivityLauncher.sessionExercise(for: key, history: [], identity: ids, template: t))
        XCTAssertEqual(ex.displayName, "Riverside 5k")
        XCTAssertNotEqual(ex.id, t.exercise.id)
        let block = try XCTUnwrap(ActivityLauncher.routineBlock(for: key, history: [], identity: ids, defaultUnit: .kg,
                                                                template: t))
        XCTAssertEqual(block.discipline, .run)
        XCTAssertEqual(block.targetDistanceMeters, 5_000)
    }

    func testTemplateRoundTripsThroughTheEntry() {
        let e = LibraryEntry(key: ActivityKey(exerciseId: "adhoc-run", nameKey: "riverside 5k"))
        let t = LibraryTemplate(exercise: LibraryCreate.named("Riverside 5k", discipline: .run), targetDistanceMeters: 5_000)
        e.template = t
        XCTAssertEqual(e.template, t)
    }
}
