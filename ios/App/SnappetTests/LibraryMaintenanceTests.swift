import XCTest
@testable import Snappet

/// `LibraryMaintenance` + `LibraryEntry` keys (Library redesign L3, prompt 185).
final class LibraryMaintenanceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func climb(_ name: String, grade: String = "V5", gym: String? = "Gravity", wall: String? = nil,
                       color: ClimbColor? = nil, _ statuses: [KilterAscentStatus] = [.attempt]) -> SessionExercise {
        var e = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                sets: statuses.map { SetLog(climbGradeLabel: grade, climbStatusRaw: $0.rawValue) },
                                displayName: name, kindRaw: SetKind.climbAttempt.rawValue)
        e.gym = gym; e.wall = wall; e.climbColorRaw = color?.rawValue; e.climbGradeLabel = grade
        return e
    }

    private func session(daysAgo: Double, _ ex: [SessionExercise]) -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        let done = ex.map { e -> SessionExercise in
            var e = e
            for i in e.sets.indices { e.sets[i].completedAt = start }
            return e
        }
        return WorkoutSession(routineName: "S", startedAt: start, completedAt: start.addingTimeInterval(3600), exercises: done)
    }

    private func ids(_ s: [WorkoutSession]) -> ActivityIdentity { ActivityIdentity(sessions: s, resetDays: 28) }

    // MARK: - Rename

    func testRenameRewritesEveryLogAndUndoRestoresIt() throws {
        let a = climb("blue crimp"), b = climb("Blue Crimp ")
        let sessions = [session(daysAgo: 10, [a]), session(daysAgo: 3, [b, climb("Red slab")])]
        let key = try XCTUnwrap(ids(sessions).key(for: a))

        let changes = LibraryMaintenance.rename(key, to: "  Blue crimp roof ", sessions: sessions, identity: ids(sessions))
        XCTAssertEqual(changes.count, 2, "both logs, not the other climb")
        XCTAssertEqual(LibraryMaintenance.apply(changes, to: sessions), 2)
        XCTAssertEqual(sessions.flatMap(\.exercises).filter { $0.displayName == "Blue crimp roof" }.count, 2)
        XCTAssertEqual(sessions[1].exercises[1].displayName, "Red slab")
        XCTAssertNotEqual(ids(sessions).key(for: sessions[0].exercises[0]), key, "the identity moved with the name")

        LibraryMaintenance.apply(changes, to: sessions, undo: true)
        XCTAssertEqual(sessions[0].exercises[0].displayName, "blue crimp")
        XCTAssertEqual(sessions[1].exercises[0].displayName, "Blue Crimp ")
        XCTAssertEqual(ids(sessions).key(for: sessions[0].exercises[0]), key)
    }

    func testRenameIgnoresBlankAndUnchangedNames() throws {
        let a = climb("Blue crimp")
        let sessions = [session(daysAgo: 1, [a])]
        let key = try XCTUnwrap(ids(sessions).key(for: a))
        XCTAssertTrue(LibraryMaintenance.rename(key, to: "   ", sessions: sessions, identity: ids(sessions)).isEmpty)
        XCTAssertTrue(LibraryMaintenance.rename(key, to: "Blue crimp", sessions: sessions, identity: ids(sessions)).isEmpty)
    }

    func testACatalogLiftRenamesAsAnOverrideButNeverMerges() {
        let bench = SessionExercise(exerciseId: "bench", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                    sets: [SetLog(actualReps: 5, actualWeight: 80, weightUnit: .kg)])
        let sessions = [session(daysAgo: 1, [bench])]
        let key = ActivityKey(exerciseId: "bench", nameKey: "")
        XCTAssertTrue(LibraryMaintenance.canRename(key))
        XCTAssertFalse(LibraryMaintenance.canMerge(key))
        let changes = LibraryMaintenance.rename(key, to: "Flat bench", sessions: sessions, identity: ids(sessions))
        LibraryMaintenance.apply(changes, to: sessions)
        XCTAssertEqual(sessions[0].exercises[0].displayName, "Flat bench")
        XCTAssertEqual(ids(sessions).key(for: sessions[0].exercises[0]), key, "a lift keeps its catalog identity")
    }

    func testFestivalsAndOverviewsCantBeRenamed() {
        XCTAssertFalse(LibraryMaintenance.canRename(ActivityKey(exerciseId: "festival-set", nameKey: "lost lands")))
        XCTAssertFalse(LibraryMaintenance.canRename(.discipline(.climb)))
    }

    // MARK: - Merge

    func testMergingClimbsAdoptsTheTargetsIdentityAndKeepsEveryAttempt() throws {
        let target = climb("Blue crimp roof", gym: "Gravity", wall: "Cave", color: .blue, [.sent])
        let typo = climb("Blue crimp rooof", grade: "V4", gym: nil, [.attempt, .attempt])
        let short = climb("blue crimp", gym: "Gravity", [.attempt])
        let sessions = [session(daysAgo: 12, [typo]), session(daysAgo: 8, [short]), session(daysAgo: 2, [target])]
        let i = ids(sessions)
        let targetKey = try XCTUnwrap(i.key(for: target))

        let changes = LibraryMaintenance.merge([i.key(for: typo)!, i.key(for: short)!], into: targetKey,
                                               sessions: sessions, identity: i)
        XCTAssertEqual(changes.count, 2)
        LibraryMaintenance.apply(changes, to: sessions)
        let after = ids(sessions)
        let keys = Set(sessions.flatMap(\.exercises).map { after.key(for: $0) })
        XCTAssertEqual(keys.count, 1, "one climb now")
        let merged = sessions[0].exercises[0]
        XCTAssertEqual(merged.gym, "Gravity"); XCTAssertEqual(merged.wall, "Cave"); XCTAssertEqual(merged.climbColor, .blue)
        XCTAssertEqual(merged.climbGradeLabel, "V4", "grades aren't rewritten")
        XCTAssertEqual(merged.sets.count, 2, "attempts aren't touched")
    }

    func testMergeRefusesCatalogLifts() {
        let key = ActivityKey(exerciseId: "bench", nameKey: "")
        XCTAssertTrue(LibraryMaintenance.merge([ActivityKey(exerciseId: "squat", nameKey: "")], into: key,
                                               sessions: [], identity: ids([])).isEmpty)
    }

    // MARK: - Look-alikes

    func testLookalikes() {
        func row(_ title: String, _ d: WorkoutDiscipline = .climb) -> LibraryCatalog.Row {
            LibraryCatalog.Row(key: ActivityKey(exerciseId: "climb", nameKey: title.lowercased()), title: title,
                               discipline: d, sessions: 1, days: 1, recentDays: 1, efforts: 1, recentSessions: 1,
                               lastDate: now, headline: nil, bestValue: nil, climb: nil)
        }
        let target = row("Blue crimp roof")
        let rows = [target, row("blue crimp"), row("Blue crimp rooof"), row("Red slab"), row("Blue crimp roof", .run)]
        let found = LibraryMaintenance.lookalikes(of: target, in: rows).map(\.title)
        XCTAssertEqual(Set(found), ["blue crimp", "Blue crimp rooof"], "contains + typo; not a different name or discipline")
        XCTAssertEqual(LibraryMaintenance.editDistance("roof", "rooof"), 1)
    }

    func testDifferentGradesOrNumbersAreNeverLookalikes() {
        func row(_ title: String, grade: String?) -> LibraryCatalog.Row {
            LibraryCatalog.Row(key: ActivityKey(exerciseId: "climb", nameKey: title.lowercased()), title: title,
                               discipline: .climb, sessions: 1, days: 1, recentDays: 1, efforts: 1, recentSessions: 1,
                               lastDate: now, headline: nil, bestValue: nil,
                               climb: LibraryCatalog.Row.Climb(type: .boulder, grade: grade, status: nil, attempts: 1,
                                                               gym: nil, wall: nil, setStart: now, isReset: false))
        }
        let v5 = row("V5 boulder", grade: "V5")
        XCTAssertTrue(LibraryMaintenance.lookalikes(of: v5, in: [row("V4 boulder", grade: "V4")]).isEmpty, "different grade")
        XCTAssertTrue(LibraryMaintenance.lookalikes(of: row("Route 3", grade: nil), in: [row("Route 4", grade: nil)]).isEmpty,
                      "differs only in a number")
        XCTAssertEqual(LibraryMaintenance.lookalikes(of: row("Blue crimp roof", grade: "V5"),
                                                     in: [row("blue crimp", grade: "V5")]).count, 1, "same grade, contained name")
    }

    // MARK: - Entry keys

    func testEntryKeyRoundTrips() {
        let k = ActivityKey(exerciseId: "climb", nameKey: "n:blue crimp|gravity@2026-09-14")
        XCTAssertEqual(LibraryEntry.key(LibraryEntry.raw(k)), k)
        let lift = ActivityKey(exerciseId: "bench", nameKey: "")
        XCTAssertEqual(LibraryEntry.key(LibraryEntry.raw(lift)), lift)
        XCTAssertNil(LibraryEntry.key("garbage"))
    }
}
