import XCTest
@testable import Snappet

/// Prompt 262: the racket card shows on a session's recap / finished detail whenever the session holds a match or a
/// drill, after the dominant discipline's own cards and never twice (`RacketRecapReach`); removing the last exercise
/// offers deleting the session (`SessionSetEditing.isLastExercise`). Pure — no view, no device.
final class RacketRecapReachTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    private func entity(_ d: WorkoutDiscipline, sets: Int, mode: RacketMode? = nil) -> SessionExercise {
        var ex = SessionExercise(exerciseId: "x.\(d.rawValue)", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                 sets: [], kindRaw: d.defaultSetKind.rawValue)
        ex.disciplineRaw = d.rawValue
        ex.racketModeRaw = mode?.rawValue
        for k in 0..<sets {
            ex.sets.append(d == .strength
                           ? SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg, completedAt: t0.addingTimeInterval(Double(k)))
                           : SetLog(completedAt: t0.addingTimeInterval(Double(k)), durationSec: 45))
        }
        return ex
    }
    private func session(_ ex: [SessionExercise]) -> WorkoutSession {
        WorkoutSession(routineID: nil, routineName: "S", startedAt: t0, completedAt: t0.addingTimeInterval(1800), exercises: ex)
    }

    func testRacketEntityIsAMatchOrADrill() {
        XCTAssertTrue(RacketRecapReach.hasRacketEntity([entity(.racket, sets: 2, mode: .match)]))
        XCTAssertTrue(RacketRecapReach.hasRacketEntity([entity(.racket, sets: 0, mode: .drill)]), "a drill, even with no blocks")
        XCTAssertTrue(RacketRecapReach.hasRacketEntity([entity(.racket, sets: 0)]), "no mode reads as a match")
        XCTAssertFalse(RacketRecapReach.hasRacketEntity([entity(.strength, sets: 3), entity(.timed, sets: 2)]))
        XCTAssertFalse(RacketRecapReach.hasRacketEntity([]))
    }

    /// The review's case: one match (2 games) and two lifts (3 sets each) — strength dominates both ways.
    func testMatchPlusLiftsAddsTheRacketCardInBothPlaces() {
        let ex = [entity(.racket, sets: 2, mode: .match), entity(.strength, sets: 3), entity(.strength, sets: 3)]
        let s = session(ex)
        XCTAssertEqual(FreeformSummary.dominant(for: s), .lifting)
        XCTAssertEqual(SessionInsights.Kind.of(s), .strength)
        XCTAssertTrue(RacketRecapReach.addsRacketCard(dominant: .lifting, exercises: ex), "recap: after the strength cards")
        XCTAssertTrue(RacketRecapReach.detailAddsRacketCard(kind: .strength, exercises: ex), "detail: the strength branch adds it")
    }

    /// More games than lift sets: racket dominant by sets, but strength by exercises — the detail's strength branch
    /// still adds the card (it renders no `SessionRecapCards`), and the recap shows it once (as the dominant card).
    func testRacketDominantBySetsButStrengthByExercises() {
        let ex = [entity(.racket, sets: 5, mode: .match), entity(.strength, sets: 1), entity(.strength, sets: 1)]
        let s = session(ex)
        XCTAssertEqual(FreeformSummary.dominant(for: s), .racket)
        XCTAssertEqual(SessionInsights.Kind.of(s), .strength)
        XCTAssertFalse(RacketRecapReach.addsRacketCard(dominant: .racket, exercises: ex), "never twice")
        XCTAssertTrue(RacketRecapReach.detailAddsRacketCard(kind: .strength, exercises: ex))
    }

    /// Two matches and one lift with many sets: workout type other (→ `SessionRecapCards`), lifting dominant by sets.
    func testOtherKindWithLiftingDominantGoesThroughTheRecapCards() {
        let ex = [entity(.racket, sets: 1, mode: .match), entity(.racket, sets: 1, mode: .match), entity(.strength, sets: 5)]
        let s = session(ex)
        XCTAssertEqual(SessionInsights.Kind.of(s), .other)
        XCTAssertEqual(FreeformSummary.dominant(for: s), .lifting)
        XCTAssertFalse(RacketRecapReach.detailAddsRacketCard(kind: .other, exercises: ex), "the recap cards add it instead")
        XCTAssertTrue(RacketRecapReach.addsRacketCard(dominant: .lifting, exercises: ex))
    }

    func testEveryNonRacketDominantAddsItOnlyWithARacketEntity() {
        let withRacket = [entity(.racket, sets: 0, mode: .drill), entity(.timed, sets: 3)]
        let without = [entity(.timed, sets: 3)]
        for d: FreeformSummary.Dominant in [.lifting, .climbing, .timed, .running, .dance, .other, .none] {
            XCTAssertTrue(RacketRecapReach.addsRacketCard(dominant: d, exercises: withRacket), "\(d)")
            XCTAssertFalse(RacketRecapReach.addsRacketCard(dominant: d, exercises: without), "\(d)")
        }
        XCTAssertFalse(RacketRecapReach.addsRacketCard(dominant: .racket, exercises: withRacket))
    }

    func testOnlyTheStrengthBranchAddsItsOwnCard() {
        let ex = [entity(.racket, sets: 1, mode: .match), entity(.strength, sets: 3)]
        for k: SessionInsights.Kind in [.hangboard, .timed, .climb, .run, .other] {
            XCTAssertFalse(RacketRecapReach.detailAddsRacketCard(kind: k, exercises: ex), "\(k) renders SessionRecapCards")
        }
        XCTAssertFalse(RacketRecapReach.detailAddsRacketCard(kind: .strength, exercises: [entity(.strength, sets: 3)]))
    }

    // MARK: Last exercise (F16)

    func testIsLastExercise() {
        let a = entity(.strength, sets: 3), b = entity(.racket, sets: 2, mode: .match)
        XCTAssertTrue(SessionSetEditing.isLastExercise(a.id, in: [a]))
        XCTAssertFalse(SessionSetEditing.isLastExercise(a.id, in: [a, b]))
        XCTAssertFalse(SessionSetEditing.isLastExercise(b.id, in: [a, b]))
        XCTAssertFalse(SessionSetEditing.isLastExercise(UUID(), in: [a]), "an id not in the session")
        XCTAssertFalse(SessionSetEditing.isLastExercise(a.id, in: []))
    }
}
