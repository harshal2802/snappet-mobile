import XCTest
@testable import Snappet

/// Unit tests for the pure `WorkoutRecommender` (workout-redesign E7) — determinism, allocation,
/// muscle-focus biasing, strategy presets, and the equipment constraints. No device, synthetic inputs,
/// exactly like `KilterRecommenderTests`.
final class WorkoutRecommenderTests: XCTestCase {

    // MARK: - Candidates

    private func candidate(_ id: String, _ muscles: [Muscle], compound: Bool = false,
                           equipment: Equipment? = .barbell, bodyweight: Bool = false) -> WorkoutRecommender.Candidate {
        WorkoutRecommender.Candidate(id: id, name: id, primaryMuscles: muscles,
                                     equipment: equipment, isCompound: compound, isBodyweight: bodyweight)
    }

    /// A broad pool spanning the major muscle groups so allocation always has something to draw.
    private var pool: [WorkoutRecommender.Candidate] {
        [candidate("squat", [.quadriceps], compound: true),
         candidate("bench", [.chest], compound: true),
         candidate("row", [.middleBack], compound: true, equipment: .dumbbell),
         candidate("ohp", [.shoulders], compound: true),
         candidate("curl", [.biceps], equipment: .dumbbell),
         candidate("pushdown", [.triceps], equipment: .cable),
         candidate("legcurl", [.hamstrings], equipment: .machine),
         candidate("raise", [.calves], equipment: .machine),
         candidate("plank", [.abdominals], equipment: .bodyOnly, bodyweight: true),
         candidate("pullup", [.lats], compound: true, equipment: .bodyOnly, bodyweight: true)]
    }

    private func signal(daysSince: [Muscle: Int] = [:], volume: [Muscle: Int] = [:]) -> WorkoutHistoryStats {
        WorkoutHistoryStats(daysSinceByDiscipline: [:], lastTrainedByDiscipline: [:], medianGapDays: nil,
                            daysSinceByMuscle: daysSince, lastTrainedByMuscle: [:], weeklyVolumeByMuscle: volume)
    }

    // MARK: - Determinism

    func testDeterministic() {
        let s = signal(daysSince: [.quadriceps: 5, .chest: 1])
        let a = WorkoutRecommender.recommend(candidates: pool, signal: s)
        let b = WorkoutRecommender.recommend(candidates: pool, signal: s)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testStableOrderAcrossInputOrder() {
        let s = signal()
        let a = WorkoutRecommender.recommend(candidates: pool, signal: s)
        let b = WorkoutRecommender.recommend(candidates: pool.reversed(), signal: s)
        XCTAssertEqual(a.picks.map(\.id), b.picks.map(\.id), "Picks are stable regardless of input order")
    }

    // MARK: - Allocation

    func testBalancedAllocationSumsToTarget() {
        for t in 1...10 {
            let a = WorkoutRecommender.allocation(target: t)
            XCTAssertEqual(a.warmUp + a.main + a.accessory + a.finisher, t, "target \(t)")
            XCTAssertGreaterThanOrEqual(a.main, 1, "target \(t) always has a main")
        }
    }

    func testMixAllocationSumsToTargetAndRespectsZeroWeight() {
        let mix = WorkoutRecommender.Mix(warmUp: 0, main: 3, accessory: 1, finisher: 0)
        for t in 1...10 {
            let a = WorkoutRecommender.allocation(target: t, mix: mix)
            XCTAssertEqual(a.warmUp + a.main + a.accessory + a.finisher, t, "target \(t)")
            XCTAssertEqual(a.warmUp, 0, "zero-weight goal is dropped (target \(t))")
            XCTAssertEqual(a.finisher, 0, "zero-weight goal is dropped (target \(t))")
        }
    }

    func testRecommendHonorsTargetCount() {
        let s = signal()
        let plan = WorkoutRecommender.recommend(candidates: pool, signal: s,
                                                options: .init(targetCount: 5))
        XCTAssertEqual(plan.picks.count, 5)
    }

    // MARK: - Muscle focus

    func testFocusMusclesPrefersLeastRecentlyTrained() {
        // Quads trained 7 days ago (freshest), chest 1 day ago (most fatigued).
        let s = signal(daysSince: [.quadriceps: 7, .chest: 1, .biceps: 3])
        let focus = WorkoutRecommender.focusMuscles(signal: s, count: 3)
        XCTAssertEqual(focus.first, .quadriceps, "Most days since trained is freshest → first focus")
        XCTAssertFalse(focus.prefix(2).contains(.chest), "A just-trained muscle is not a top focus")
    }

    func testNeverTrainedMuscleIsFresh() {
        // Only chest has any history; an untrained muscle should outrank it.
        let s = signal(daysSince: [.chest: 1])
        let focus = WorkoutRecommender.focusMuscles(signal: s, count: 1)
        XCTAssertNotEqual(focus.first, .chest)
    }

    func testRecommendBiasesMainTowardFreshMuscle() {
        // Make quads by far the freshest; the squat (a quad compound) should land in the main block.
        let s = signal(daysSince: [.quadriceps: 10, .chest: 0, .shoulders: 0, .middleBack: 0, .lats: 0])
        let plan = WorkoutRecommender.recommend(candidates: pool, signal: s,
                                                options: .init(targetCount: 6))
        let mainIds = Set(plan.picks(for: .main).map(\.id))
        XCTAssertTrue(mainIds.contains("squat"), "The fresh-muscle compound is selected as a main lift")
    }

    // MARK: - Strategy presets

    func testStrategyConfigsAreDistinct() {
        let strength = WorkoutRecommender.config(for: .strength)
        let recovery = WorkoutRecommender.config(for: .recovery)
        XCTAssertEqual(strength.scheme?.mainReps, "5")
        XCTAssertNotEqual(strength.targetCount, recovery.targetCount)
    }

    func testStrengthSchemeAppliesToMainReps() {
        let cfg = WorkoutRecommender.config(for: .strength)
        let s = signal()
        let plan = WorkoutRecommender.recommend(candidates: pool, signal: s,
                                                options: .init(targetCount: cfg.targetCount, mix: cfg.mix, scheme: cfg.scheme))
        for main in plan.picks(for: .main) {
            XCTAssertEqual(main.reps, "5", "Strength strategy trains mains at 5 reps")
            XCTAssertEqual(main.restSeconds, 180)
        }
    }

    // MARK: - Constraints

    func testExcludedEquipmentDropsThoseExercises() {
        let s = signal()
        let plan = WorkoutRecommender.recommend(candidates: pool, signal: s,
                                                options: .init(targetCount: 8, excludedEquipment: [.barbell]))
        for pick in plan.picks {
            XCTAssertNotEqual(pick.candidate.equipment, .barbell, "No barbell exercise survives the constraint")
        }
    }

    func testBodyweightOnlyKeepsOnlyBodyweight() {
        let s = signal()
        let plan = WorkoutRecommender.recommend(candidates: pool, signal: s,
                                                options: .init(targetCount: 8, bodyweightOnly: true))
        XCTAssertFalse(plan.isEmpty)
        for pick in plan.picks {
            XCTAssertTrue(pick.candidate.isBodyweight, "Only body-only movements remain")
        }
    }

    func testEmptyPoolAfterConstraintsReturnsEmpty() {
        let s = signal()
        let onlyBarbell = [candidate("squat", [.quadriceps], compound: true, equipment: .barbell)]
        let plan = WorkoutRecommender.recommend(candidates: onlyBarbell, signal: s,
                                                options: .init(bodyweightOnly: true))
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - Re-roll

    func testRerollChangesSelectionDeterministically() {
        let s = signal()
        let base = WorkoutRecommender.recommend(candidates: pool, signal: s, options: .init(targetCount: 4))
        let reroll = WorkoutRecommender.recommend(candidates: pool, signal: s,
                                                  options: .init(targetCount: 4, rerollSeed: 1))
        let rerollAgain = WorkoutRecommender.recommend(candidates: pool, signal: s,
                                                       options: .init(targetCount: 4, rerollSeed: 1))
        XCTAssertEqual(reroll, rerollAgain, "Re-roll is deterministic per seed")
        XCTAssertNotEqual(base.picks.map(\.id), reroll.picks.map(\.id), "A re-roll surfaces a different set")
    }
}
