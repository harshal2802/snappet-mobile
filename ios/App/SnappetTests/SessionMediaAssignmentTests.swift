import XCTest
@testable import Snappet

/// Unit tests for the **pure** per-set media assignment (no device, no Photos): the
/// completion-timeline flattening (incl. skipping un-completed sets) and the clip→set placement
/// rule (set-window ownership, the rest-period rule, and the after-last-set → General fallback).
final class SessionMediaAssignmentTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let exA = UUID()
    private let exB = UUID()

    private func clip(_ offset: Double) -> SessionMediaAssignment.ClipInput {
        .init(id: UUID(), offsetSec: offset)
    }

    // MARK: - completions(from:)

    func testCompletionsFlattenAndSortByTime() {
        // Two exercises, sets completed out of declaration order in time.
        let exercises = [
            SessionExercise(id: exA, exerciseId: "squat", targetSets: 2, targetReps: "5",
                            targetRestSeconds: 60,
                            sets: [set(120), set(240)]),
            SessionExercise(id: exB, exerciseId: "curl", targetSets: 1, targetReps: "10",
                            targetRestSeconds: 60,
                            sets: [set(60)]),
        ]
        let comps = SessionMediaAssignment.completions(from: exercises, startedAt: start)
        XCTAssertEqual(comps.map(\.completionOffset), [60, 120, 240])      // sorted by time
        XCTAssertEqual(comps.first?.exerciseID, exB)                       // curl finished first
    }

    func testCompletionsSkipUncompletedSets() {
        let exercises = [
            SessionExercise(id: exA, exerciseId: "squat", targetSets: 3, targetReps: "5",
                            targetRestSeconds: 60,
                            sets: [set(120), SetLog(completedAt: nil), set(360)]),
        ]
        let comps = SessionMediaAssignment.completions(from: exercises, startedAt: start)
        XCTAssertEqual(comps.map(\.setIndex), [0, 2])                      // the nil-completion set #1 is dropped
    }

    // MARK: - assign(clips:completions:)

    private var threeSets: [SessionMediaAssignment.SetCompletion] {
        [.init(exerciseID: exA, setIndex: 0, completionOffset: 120),
         .init(exerciseID: exA, setIndex: 1, completionOffset: 240),
         .init(exerciseID: exB, setIndex: 0, completionOffset: 600)]
    }

    func testClipDuringFirstSet() {
        let c = clip(100)                                                 // before the 120s completion
        let out = SessionMediaAssignment.assign(clips: [c], completions: threeSets)
        XCTAssertEqual(out[c.id], .init(exerciseID: exA, setIndex: 0))
    }

    func testClipInRestAfterSetBelongsToSetJustCompleted() {
        // Filmed at 130s — after set 0 (120s) finished, before set 1 (240s): the rest-period rule
        // attaches it to the *next* completion's set (set 1, the one being performed/just before).
        let c = clip(130)
        let out = SessionMediaAssignment.assign(clips: [c], completions: threeSets)
        XCTAssertEqual(out[c.id], .init(exerciseID: exA, setIndex: 1))
    }

    func testClipExactlyAtCompletionAttachesToThatSet() {
        let c = clip(240)                                                 // boundary is inclusive (>=)
        let out = SessionMediaAssignment.assign(clips: [c], completions: threeSets)
        XCTAssertEqual(out[c.id], .init(exerciseID: exA, setIndex: 1))
    }

    func testClipAfterLastSetIsGeneral() {
        let c = clip(800)                                                 // after the last completion (600s)
        let out = SessionMediaAssignment.assign(clips: [c], completions: threeSets)
        XCTAssertNil(out[c.id])                                           // unassigned → General
    }

    func testCrossesExerciseBoundary() {
        let c = clip(400)                                                 // between exA set1 (240) and exB set0 (600)
        let out = SessionMediaAssignment.assign(clips: [c], completions: threeSets)
        XCTAssertEqual(out[c.id], .init(exerciseID: exB, setIndex: 0))    // attaches to the next set (other exercise)
    }

    func testNoCompletionsLeavesEverythingGeneral() {
        let out = SessionMediaAssignment.assign(clips: [clip(10), clip(500)], completions: [])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - reindexAfterDeletion(_:removing:)

    func testReindexPinBelowDeletionIsUntouched() {
        XCTAssertEqual(SessionMediaAssignment.reindexAfterDeletion(0, removing: IndexSet([2])), 0)
    }

    func testReindexPinAboveDeletionShiftsDown() {
        XCTAssertEqual(SessionMediaAssignment.reindexAfterDeletion(3, removing: IndexSet([1])), 2)
    }

    func testReindexPinOnDeletedSetFallsBackToExercise() {
        XCTAssertNil(SessionMediaAssignment.reindexAfterDeletion(2, removing: IndexSet([2])))
    }

    func testReindexAcrossMultipleDeletions() {
        // Sets 0 and 2 deleted: a pin on set 4 has two deletions below it → new index 2.
        XCTAssertEqual(SessionMediaAssignment.reindexAfterDeletion(4, removing: IndexSet([0, 2])), 2)
        // A pin on set 1 has one deletion below it → new index 0.
        XCTAssertEqual(SessionMediaAssignment.reindexAfterDeletion(1, removing: IndexSet([0, 2])), 0)
    }

    // MARK: - Helpers

    private func set(_ completionOffset: Double) -> SetLog {
        SetLog(actualReps: 5, actualWeight: nil, weightUnit: .kg,
               completedAt: start.addingTimeInterval(completionOffset))
    }
}
