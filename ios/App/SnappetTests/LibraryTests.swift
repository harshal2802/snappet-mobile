import XCTest
@testable import Snappet

/// Unit tests for the **pure** workout-library core (workout-redesign E3): the `LibraryBuilder` merge, the
/// `ExerciseCategory → WorkoutDiscipline` seam, the discipline-faceted `LibraryFacets` filter (and its
/// per-discipline swap), and the best-effort `LibraryRecords`. No SwiftUI / SwiftData / device.
final class LibraryTests: XCTestCase {

    // MARK: - Fixtures

    private func ex(_ id: String, _ name: String, category: ExerciseCategory = .strength,
                    equipment: Equipment? = .barbell, muscles: [Muscle] = [.chest],
                    custom: Bool = false) -> Exercise {
        Exercise(id: id, name: name, force: nil, level: .beginner, mechanic: nil,
                 equipment: equipment, primaryMuscles: muscles, secondaryMuscles: [],
                 instructions: [], category: category, isCustom: custom)
    }

    // MARK: - Builder

    func testBuilderMergesAllDisciplinesAndKeepsExerciseId() {
        let strength = [ex("bench", "Bench Press"), ex("custom-1", "My Lift", custom: true)]
        let items = LibraryBuilder.items(strength: strength, timed: [])

        // The strength exerciseId is carried VERBATIM (the persistence contract).
        XCTAssertNotNil(items.first { $0.id == "bench" })
        XCTAssertEqual(items.first { $0.id == "bench" }?.discipline, .strength)
        XCTAssertTrue(items.first { $0.id == "custom-1" }?.isCustom == true)

        // Climb + run starters + timed suggestions are all folded in.
        XCTAssertTrue(items.contains { $0.discipline == .climb })
        XCTAssertTrue(items.contains { $0.discipline == .run })
        XCTAssertTrue(items.contains { $0.discipline == .timed }, "seeded timed suggestions present")
        XCTAssertEqual(items.first { $0.id == "climb.boulder" }?.discipline, .climb)
    }

    func testCardioExerciseMapsToRunDiscipline() {
        // README §10 Q6 — the two "type" vocabularies reconciled.
        XCTAssertEqual(LibraryBuilder.discipline(for: .cardio), .run)
        XCTAssertEqual(LibraryBuilder.discipline(for: .strength), .strength)
        XCTAssertEqual(LibraryBuilder.discipline(for: .powerlifting), .strength)
        XCTAssertEqual(LibraryBuilder.discipline(for: .stretching), .strength)
    }

    func testSavedTimedRowSuppressesDuplicateSuggestion() throws {
        let savedDeadHang = LibraryBuilder.TimedSnapshot(
            id: UUID(), name: "Dead hang", category: .hangboard, specData: nil, lastUsedAt: .now)
        let items = LibraryBuilder.items(strength: [], timed: [savedDeadHang])
        let deadHangs = items.filter { $0.title == "Dead hang" }
        XCTAssertEqual(deadHangs.count, 1, "the saved row replaces the seeded suggestion of the same name")
        // The surviving one is the saved (catalog-backed) row.
        if case .timed(_, _, let catalogID)? = deadHangs.first?.source {
            XCTAssertEqual(catalogID, savedDeadHang.id)
        } else { XCTFail("expected a timed source") }
    }

    func testDisciplinesPresentInCanonicalOrder() {
        let items = LibraryBuilder.items(strength: [ex("bench", "Bench Press")], timed: [])
        let disciplines = LibraryBuilder.disciplines(in: items)
        // strength + climb + run + timed are seeded; dance/other are not.
        XCTAssertEqual(disciplines, [.strength, .climb, .run, .timed])
    }

    // MARK: - Search + filter

    func testSearchMatchesTitleAndSubtitleTokens() {
        let items = LibraryBuilder.items(strength: [ex("bench", "Bench Press", muscles: [.chest])], timed: [])
        let hits = LibraryBuilder.apply(items, query: "bench chest", discipline: nil, facets: LibraryFacets())
        XCTAssertEqual(hits.map(\.id), ["bench"])
        XCTAssertTrue(LibraryBuilder.apply(items, query: "zzz", discipline: nil, facets: LibraryFacets()).isEmpty)
    }

    func testDisciplineFilterIsTheTopFacet() {
        let items = LibraryBuilder.items(strength: [ex("bench", "Bench Press")], timed: [])
        let climbsOnly = LibraryBuilder.apply(items, query: "", discipline: .climb, facets: LibraryFacets())
        XCTAssertFalse(climbsOnly.isEmpty)
        XCTAssertTrue(climbsOnly.allSatisfy { $0.discipline == .climb })
    }

    func testStrengthFacetsMuscleAndEquipment() {
        let strength = [ex("bench", "Bench", equipment: .barbell, muscles: [.chest]),
                        ex("pullup", "Pull-up", equipment: .bodyOnly, muscles: [.lats])]
        let items = LibraryBuilder.items(strength: strength, timed: [])

        var byMuscle = LibraryFacets(); byMuscle.muscles = [.lats]
        XCTAssertEqual(LibraryBuilder.apply(items, query: "", discipline: .strength, facets: byMuscle).map(\.id), ["pullup"])

        var byEquip = LibraryFacets(); byEquip.equipment = [.barbell]
        XCTAssertEqual(LibraryBuilder.apply(items, query: "", discipline: .strength, facets: byEquip).map(\.id), ["bench"])

        var noEquip = LibraryFacets(); noEquip.noEquipment = true
        XCTAssertEqual(LibraryBuilder.apply(items, query: "", discipline: .strength, facets: noEquip).map(\.id), ["pullup"])
    }

    func testClimbAndRunFacetsSwap() {
        let items = LibraryBuilder.items(strength: [], timed: [])

        var boulderOnly = LibraryFacets(); boulderOnly.climbTypes = [.boulder]
        let boulders = LibraryBuilder.apply(items, query: "", discipline: .climb, facets: boulderOnly)
        XCTAssertEqual(boulders.map(\.id), ["climb.boulder"])

        var trailOnly = LibraryFacets(); trailOnly.runTerrains = [.trail]
        let trails = LibraryBuilder.apply(items, query: "", discipline: .run, facets: trailOnly)
        XCTAssertEqual(trails.map(\.id), ["run.trail"])

        var hangboardOnly = LibraryFacets(); hangboardOnly.timedCategories = [.hangboard]
        let hangboards = LibraryBuilder.apply(items, query: "", discipline: .timed, facets: hangboardOnly)
        XCTAssertFalse(hangboards.isEmpty)
        XCTAssertTrue(hangboards.allSatisfy {
            if case .timed(_, let cat, _) = $0.source { return cat == .hangboard }; return false
        })
    }

    func testKeepOnlyDropsIrrelevantFacets() {
        var f = LibraryFacets()
        f.muscles = [.chest]; f.climbTypes = [.boulder]; f.runTerrains = [.road]
        f.keepOnly(.climb)
        XCTAssertTrue(f.muscles.isEmpty, "switching to climb drops the strength muscle facet")
        XCTAssertTrue(f.runTerrains.isEmpty)
        XCTAssertEqual(f.climbTypes, [.boulder])
        // "All types" keeps everything.
        var g = LibraryFacets(); g.muscles = [.chest]; g.climbTypes = [.boulder]
        g.keepOnly(nil)
        XCTAssertEqual(g.muscles, [.chest]); XCTAssertEqual(g.climbTypes, [.boulder])
    }

    func testFacetsActiveCountAndClear() {
        var f = LibraryFacets()
        XCTAssertTrue(f.isEmpty)
        f.muscles = [.chest, .lats]; f.noEquipment = true
        XCTAssertEqual(f.activeCount, 3)
        XCTAssertFalse(f.isEmpty)
        f.clear()
        XCTAssertTrue(f.isEmpty)
    }

    // MARK: - Records (best-effort from session blobs)

    private func strengthSession(_ exerciseId: String, reps: Int, weight: Double) -> WorkoutSession {
        let set = SetLog(actualReps: reps, actualWeight: weight, weightUnit: .kg, completedAt: .now)
        let ex = SessionExercise(exerciseId: exerciseId, targetSets: 1, targetReps: "\(reps)",
                                 targetRestSeconds: 0, sets: [set], kindRaw: SetKind.repsWeight.rawValue)
        let s = WorkoutSession(routineName: "S", exercises: [ex])
        s.completedAt = .now
        return s
    }

    func testStrengthRecordsFromHistory() {
        let history = [strengthSession("bench", reps: 5, weight: 100),
                       strengthSession("bench", reps: 3, weight: 120)]
        let item = LibraryItem(id: "bench", title: "Bench", subtitle: "", discipline: .strength,
                               symbol: "dumbbell.fill", isCustom: false,
                               source: .strength(ex("bench", "Bench")))
        let records = LibraryRecords.records(for: item, history: history, unit: .kg)
        XCTAssertTrue(records.contains { $0.label == "Best set" })
        XCTAssertTrue(records.contains { $0.label == "Sessions" && $0.value == "2" })
    }

    func testClimbRecordsFromHistory() {
        var attempt = SetLog(completedAt: .now)
        attempt.climbStatusRaw = KilterAscentStatus.sent.rawValue
        var climb = SessionExercise(exerciseId: "climb-1", targetSets: 0, targetReps: "",
                                    targetRestSeconds: 0, sets: [attempt],
                                    kindRaw: SetKind.climbAttempt.rawValue)
        climb.disciplineRaw = WorkoutDiscipline.climb.rawValue
        climb.climbGradeLabel = "V5"
        climb.climbGradeScaleRaw = GradeScale.vScale.rawValue
        let s = WorkoutSession(routineName: "C", exercises: [climb]); s.completedAt = .now

        let item = LibraryItem(id: "climb.boulder", title: "Boulder", subtitle: "", discipline: .climb,
                               symbol: "figure.bouldering", isCustom: false,
                               source: .climb(ClimbStarter.all[0]))
        let records = LibraryRecords.records(for: item, history: [s], unit: .kg)
        XCTAssertEqual(records.first { $0.label == "Hardest send" }?.value, "V5")
        XCTAssertEqual(records.first { $0.label == "Sends" }?.value, "1")
    }

    func testRecordsEmptyWhenDisciplineNeverLogged() {
        let item = LibraryItem(id: "run.easy", title: "Easy run", subtitle: "", discipline: .run,
                               symbol: "figure.run", isCustom: false, source: .run(RunStarter.all[0]))
        XCTAssertTrue(LibraryRecords.records(for: item, history: [], unit: .kg).isEmpty)
    }
}
