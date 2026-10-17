import XCTest
@testable import Snappet

/// Every picker is the Library (Library redesign L4b, prompt 187): what a picker offers under Yours, in what order,
/// with what "Last: …" line.
final class LibraryPickTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func lift(_ id: String, _ sets: [(Int, Double)]) -> SessionExercise {
        SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                        sets: sets.map { SetLog(actualReps: $0.0, actualWeight: $0.1, weightUnit: .kg) },
                        kindRaw: SetKind.repsWeight.rawValue)
    }

    private func session(daysAgo: Double, _ ex: [SessionExercise], name: String = "S") -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        let done = ex.map { e -> SessionExercise in
            var e = e
            if e.sets.isEmpty { e.sets = [SetLog(climbGradeLabel: e.climbGradeLabel, climbStatusRaw: "attempt")] }
            for i in e.sets.indices { e.sets[i].completedAt = start }
            e.id = UUID()
            return e
        }
        return WorkoutSession(routineName: name, startedAt: start, completedAt: start.addingTimeInterval(3600),
                              exercises: done)
    }

    private func yours(_ history: [WorkoutSession], created: [LibraryCatalog.CreatedInput] = []) -> [LibraryCatalog.Row] {
        LibraryCatalog.yours(history: history, identity: ActivityIdentity(sessions: history, resetDays: 28), unit: .kg,
                             now: now, created: created, title: LibraryCatalog.fallbackTitle)
    }

    func testMostUsedFirstAndTheLastLineIsWhatYouDidLastTime() {
        let history = [
            session(daysAgo: 9, [lift("bench", [(8, 70), (8, 70)]), lift("squat", [(5, 100)])]),
            session(daysAgo: 2, [lift("bench", [(8, 75), (8, 75), (7, 75), (6, 72.5)])]),
        ]
        let rows = LibraryPick.rows(yours(history), hidden: [], query: "", discipline: nil)
        XCTAssertEqual(rows.map(\.key.exerciseId), ["bench", "squat"], "bench is done on 2 days, squat on 1")
        XCTAssertEqual(LibraryPick.subtitle(rows[0]), "Last: 4 × 8 @ 75 kg", "the latest session, not the best one")
        XCTAssertEqual(LibraryPick.subtitle(rows[1]), "Last: 1 × 5 @ 100 kg")
    }

    func testAHalfKiloIsKeptInTheLastLine() {
        let rows = LibraryPick.rows(yours([session(daysAgo: 1, [lift("ohp", [(5, 42.5)])])]), hidden: [], query: "",
                                    discipline: nil)
        XCTAssertEqual(LibraryPick.subtitle(rows[0]), "Last: 1 × 5 @ 42.5 kg")
    }

    func testHiddenAndFestivalRowsAreNotOffered() {
        var set = SessionExercise(exerciseId: ActivityIdentity.festivalExerciseId, targetSets: 0, targetReps: "",
                                  targetRestSeconds: 0, sets: [SetLog(durationSec: 1800)], displayName: "Artist",
                                  kindRaw: SetKind.duration.rawValue)
        set.disciplineRaw = WorkoutDiscipline.dance.rawValue
        let history = [session(daysAgo: 1, [lift("bench", [(8, 70)]), lift("row", [(10, 50)])]),
                       session(daysAgo: 1, [set], name: "ALLDAT")]
        let all = yours(history)
        let rowKey = all.first { $0.key.exerciseId == "row" }!.key
        let offered = LibraryPick.rows(all, hidden: [rowKey], query: "", discipline: nil)
        XCTAssertEqual(offered.map(\.key.exerciseId), ["bench"])
    }

    func testCreatedButNotDoneComesAfterWhatYouveDone() {
        let route = LibraryCreate.named("Riverside 5k", discipline: .run)
        let key = ActivityIdentity(sessions: [], resetDays: 28).key(for: route, loggedAt: now)!
        let created = LibraryCatalog.CreatedInput(key: key, template: LibraryTemplate(exercise: route,
                                                                                    targetDistanceMeters: 5_000),
                                                  createdAt: now)
        let rows = LibraryPick.rows(yours([session(daysAgo: 30, [lift("bench", [(8, 70)])])], created: [created]),
                                    hidden: [], query: "", discipline: nil)
        XCTAssertEqual(rows.map(\.title), ["bench", "Riverside 5k"])
        XCTAssertEqual(LibraryPick.subtitle(rows[1]), "5 km · not done yet")
    }

    func testDisciplineAndSearchFilterYours() {
        let climb = LibraryCreate.climb(AddClimbParams(type: .boulder, scale: .vScale, grade: "V4", name: "Blue arete",
                                                       gym: "Gravity", wall: "Slab", color: .blue))
        let history = [session(daysAgo: 1, [lift("bench", [(8, 70)]), climb])]
        let all = yours(history)
        XCTAssertEqual(LibraryPick.rows(all, hidden: [], query: "", discipline: .climb).map(\.title), ["Blue arete"])
        XCTAssertEqual(LibraryPick.rows(all, hidden: [], query: "arete", discipline: nil).count, 1)
        XCTAssertEqual(LibraryPick.subtitle(LibraryPick.rows(all, hidden: [], query: "", discipline: .climb)[0]),
                       "Last: V4 · 1 attempt")
    }

    func testOpensOnExploreWithNothingLogged() {
        XCTAssertFalse(LibraryPick.opensOnYours([]))
        XCTAssertTrue(LibraryPick.opensOnYours(yours([session(daysAgo: 1, [lift("bench", [(8, 70)])])])))
    }
}
