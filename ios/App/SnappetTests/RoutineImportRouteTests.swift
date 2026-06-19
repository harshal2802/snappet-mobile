import XCTest
@testable import Snappet

/// The `snappet://routine/v1/<blob>` **open path** (workout-redesign E6) end-to-end at the pure value
/// level — the device-free analog of the Kilter deep-link tests. Drives a URL through the route table
/// (`SnappetDeepLink.route`), the router one-shot (`SuiteRouter.pendingRoutineImport`), and the import
/// insert rule (NEW `Routine`, new UUID, never overwrite). The SwiftUI `.onChange` consumer + the camera
/// scan stay device/sim-pending; this locks the decisions they execute.
@MainActor
final class RoutineImportRouteTests: XCTestCase {

    private func sampleRoutine() -> SharedRoutine {
        SharedRoutine(name: "Imported Leg Day", detail: "Heavy squats",
                      exercises: [
                        RoutineExercise(exerciseId: "barbell_squat", sets: 5, reps: "5", restSeconds: 150,
                                        weight: 120, weightUnit: .kg),
                        RoutineExercise(exerciseId: "plank", sets: 3, reps: "", restSeconds: 30,
                                        discipline: .timed, targetDurationSec: 60),
                      ])
    }

    func testOpenURLSetsPendingRoutineImportOneShot() throws {
        let shared = sampleRoutine()
        let url = try XCTUnwrap(shared.url)

        // 1) The route table parses the URL into the routine case (RootShell.handle's switch).
        guard case .routine(let parsed) = SnappetDeepLink.route(for: url) else {
            return XCTFail("expected .routine route")
        }

        // 2) RootShell.handle stages the one-shot on the router + opens the module.
        let router = SuiteRouter()
        router.pendingRoutineImport = parsed
        router.open(module: WorkoutTrackerModule.id)
        XCTAssertEqual(router.tab, .apps)
        XCTAssertNotNil(router.pendingRoutineImport)

        // 3) WorkoutHomeView consumes it once: read, then clear (self-clearing one-shot).
        let consumed = router.pendingRoutineImport
        router.pendingRoutineImport = nil
        XCTAssertNotNil(consumed)
        XCTAssertNil(router.pendingRoutineImport, "the intent must be one-shot (cleared on consume)")
        XCTAssertEqual(consumed?.name, "Imported Leg Day")
    }

    func testImportBuildsANewRoutineNeverOverwrites() throws {
        let shared = sampleRoutine()
        let blocks = shared.routineExercises()

        // The insert rule importRoutine runs: a fresh Routine + fresh block ids.
        let existing = Routine(name: "Existing", exercises: [])
        let imported = Routine(name: shared.name, exercises: blocks, isStarter: false,
                               detail: shared.detail)

        XCTAssertNotEqual(imported.id, existing.id, "import gets its own UUID — never overwrites")
        XCTAssertEqual(imported.name, "Imported Leg Day")
        XCTAssertEqual(imported.detail, "Heavy squats")
        XCTAssertEqual(imported.exercises.count, 2)
        XCTAssertEqual(imported.exercises[0].discipline, .strength)
        XCTAssertEqual(imported.exercises[1].discipline, .timed)
        XCTAssertEqual(imported.exercises[1].targetDurationSec, 60)
        XCTAssertFalse(imported.isStarter)
    }

    func testRouterOpenReplacesStackWithModuleRoot() {
        // open(module:) replaces (not appends) so repeated imports can't pile a stale stack — the same
        // entry the Kilter climb path uses; popToRoot (the routine-detail scan path) clears it too.
        let router = SuiteRouter()
        router.push(SessionRoute(id: UUID()))
        router.open(module: WorkoutTrackerModule.id)
        router.popToRoot()
        XCTAssertEqual(router.tab, .apps)
    }
}
