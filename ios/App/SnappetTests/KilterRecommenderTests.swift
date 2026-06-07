import XCTest
@testable import Snappet

/// Unit tests for the **pure** `KilterRecommender` — working-grade detection + session planning over
/// synthetic history/candidates. No SwiftData, no catalog DB, no device.
final class KilterRecommenderTests: XCTestCase {

    // MARK: - Builders

    private func item(_ uuid: String, diff: Double, quality: Double = 2, ascents: Int = 100,
                      grade: String = "g") -> KilterListItem {
        KilterListItem(uuid: uuid, name: uuid, setter: "setter", difficulty: diff,
                       gradeLabel: grade, quality: quality, ascents: ascents)
    }

    private func log(_ uuid: String, diff: Double, _ status: KilterAscentStatus,
                     grade: String = "g") -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: grade, difficulty: diff,
                       status: status, attempts: 1, startedAt: nil, endedAt: nil,
                       loggedAt: Date(timeIntervalSince1970: 0))
    }

    private func uuids(_ picks: [KilterRecommender.Pick]) -> [String] { picks.map(\.item.uuid) }

    // MARK: - Working grade

    func testWorkingDifficultyPicksHardestQualifyingBucket() {
        let history = [
            log("a", diff: 16, .sent), log("b", diff: 16, .flash), log("c", diff: 16, .sent),
            log("d", diff: 18, .sent), log("e", diff: 18, .sent),
            log("f", diff: 20, .sent),                                  // a single 20 → below threshold
        ]
        // 16 has 3 sends, 18 has 2, 20 has 1; threshold 2 → hardest qualifying = 18.
        XCTAssertEqual(KilterRecommender.workingDifficulty(history: history, sendThreshold: 2), 18)
    }

    func testWorkingDifficultyFallsBackToHardestSingleSend() {
        let history = [log("a", diff: 16, .sent), log("b", diff: 18, .flash)]   // none meets threshold 2
        XCTAssertEqual(KilterRecommender.workingDifficulty(history: history, sendThreshold: 2), 18)
    }

    func testWorkingDifficultyNilWithNoSends() {
        let history = [log("a", diff: 16, .attempt), log("b", diff: 16, .project)]
        XCTAssertNil(KilterRecommender.workingDifficulty(history: history))
    }

    // MARK: - Allocation

    func testAllocationSumsToTarget() {
        for t in 3...12 {
            let a = KilterRecommender.allocation(target: t)
            XCTAssertEqual(a.warmup + a.send + a.project, t, "target \(t)")
            XCTAssertGreaterThanOrEqual(a.warmup, 1)
            XCTAssertGreaterThanOrEqual(a.send, 1)
            XCTAssertGreaterThanOrEqual(a.project, 1)
        }
        XCTAssertEqual(KilterRecommender.allocation(target: 6).warmup, 2)
        XCTAssertEqual(KilterRecommender.allocation(target: 6).send, 3)
        XCTAssertEqual(KilterRecommender.allocation(target: 6).project, 1)
    }

    // MARK: - Recommend

    func testRecommendGroupsByGoalAroundWorking() {
        let history = [log("h1", diff: 16, .sent), log("h2", diff: 16, .sent)]   // working = 16
        let candidates = [
            item("w14", diff: 14), item("w15", diff: 15),                         // warm-up band (16−2,16−1)
            item("s16a", diff: 16), item("s16b", diff: 16), item("s16c", diff: 16), // send band (16)
            item("p17", diff: 17), item("p18", diff: 18),                         // project band (16+1)
        ]
        let plan = KilterRecommender.recommend(history: history, candidates: candidates)   // target 6 → (2,3,1)

        XCTAssertEqual(plan.workingDifficulty, 16)
        let warm = plan.picks(for: .warmup)
        let send = plan.picks(for: .send)
        let proj = plan.picks(for: .project)
        XCTAssertEqual(warm.count, 2)
        XCTAssertEqual(send.count, 3)
        XCTAssertEqual(proj.count, 1)
        XCTAssertTrue(warm.allSatisfy { $0.item.difficulty < 16 })
        XCTAssertTrue(send.allSatisfy { $0.item.difficulty == 16 })
        XCTAssertTrue(proj.allSatisfy { $0.item.difficulty > 16 })
    }

    func testPreferUnsentExcludesSentClimbsFromSendGoal() {
        // Working = 16; "s16a" is already sent so it must not be recommended as a fresh send target.
        let history = [log("s16a", diff: 16, .sent), log("hx", diff: 16, .sent)]
        let candidates = [item("s16a", diff: 16), item("s16b", diff: 16), item("s16c", diff: 16)]
        let plan = KilterRecommender.recommend(history: history, candidates: candidates,
                                               options: .init(targetCount: 4))   // (1,2,1) → send 2
        let send = uuids(plan.picks(for: .send))
        XCTAssertFalse(send.contains("s16a"), "an already-sent climb shouldn't be a send target")
        XCTAssertEqual(Set(send), ["s16b", "s16c"])
    }

    func testNoDuplicateClimbAcrossGoals() {
        let history = [log("h1", diff: 16, .sent), log("h2", diff: 16, .sent)]
        let candidates = (10...20).map { item("c\($0)", diff: Double($0)) }
        let all = uuids(KilterRecommender.recommend(history: history, candidates: candidates).picks)
        XCTAssertEqual(all.count, Set(all).count, "no climb should appear twice")
    }

    func testDeterministicForSameInput() {
        let history = [log("h1", diff: 16, .sent), log("h2", diff: 16, .sent)]
        let candidates = (10...20).map { item("c\($0)", diff: Double($0), quality: Double($0 % 3)) }
        let a = KilterRecommender.recommend(history: history, candidates: candidates)
        let b = KilterRecommender.recommend(history: history, candidates: candidates)
        XCTAssertEqual(a, b)
    }

    func testHigherQualityWins() {
        let history = [log("h1", diff: 16, .sent), log("h2", diff: 16, .sent)]
        let candidates = [
            item("low", diff: 16, quality: 1, ascents: 5),
            item("high", diff: 16, quality: 3, ascents: 5),
        ]
        let send = uuids(KilterRecommender.recommend(
            history: history, candidates: candidates, options: .init(targetCount: 1)).picks(for: .send))
        XCTAssertEqual(send.first, "high")
    }

    func testColdStartWithNoHistoryStillRecommends() {
        let candidates = [12, 14, 16, 18, 20].map { item("c\($0)", diff: Double($0)) }   // median 16
        let plan = KilterRecommender.recommend(history: [], candidates: candidates)
        XCTAssertNil(plan.workingDifficulty)               // we never claim a working grade
        XCTAssertNil(plan.workingGradeLabel)
        XCTAssertFalse(plan.isEmpty)                        // but still produces a session
    }

    func testEmptyCandidatesKeepsWorkingButNoPicks() {
        let history = [log("h1", diff: 16, .sent, grade: "6a/V3"),
                       log("h2", diff: 16, .sent, grade: "6a/V3")]
        let plan = KilterRecommender.recommend(history: history, candidates: [])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.workingDifficulty, 16)
        XCTAssertEqual(plan.workingGradeLabel, "6a/V3")
    }

    // MARK: - Anchor ↔ candidate-window coherence (review fix)

    /// The window a caller fetches candidates over must include every band `recommend` can draw on
    /// (buckets w-4 … w+2) — otherwise the deep warm-up fallbacks point at climbs that were never
    /// fetched (the `w-4` band was previously dead because the view fetched only down to anchor-3).
    func testCandidateWindowCoversAllBands() {
        let window = KilterRecommender.candidateWindow(anchor: 16)
        XCTAssertEqual(window.min, 11.5, accuracy: 0.0001)
        XCTAssertEqual(window.max, 18.5, accuracy: 0.0001)
        for bucket in 12...18 {   // w-4 … w+2 for w = 16
            XCTAssertTrue(window.min <= Double(bucket) && Double(bucket) <= window.max,
                          "bucket \(bucket) must lie inside the fetch window \(window)")
        }
    }

    /// With the closer warm-up bands empty, the recommender must still reach the deep [w-4] fallback.
    func testWarmupReachesDeepFallbackBand() {
        let history = [log("h1", diff: 16, .sent), log("h2", diff: 16, .sent)]   // working = 16
        let candidates = [
            item("warm12", diff: 12),       // the only warm-up option, at w-4
            item("s16", diff: 16),          // a send
            item("p17", diff: 17),          // a project
        ]
        let plan = KilterRecommender.recommend(history: history, candidates: candidates)
        XCTAssertEqual(uuids(plan.picks(for: .warmup)), ["warm12"],
                       "a w-4 climb must be pickable when the closer warm-up bands are empty")
    }

    /// An explicit `anchor` (the path the view uses) centres the bands on that value — not on the
    /// candidate median — so a hard-skewed catalog can't pull the plan off the working grade, and
    /// every goal band fills from the fetched pool.
    func testExplicitAnchorDrivesBandCentre() {
        let candidates = [
            item("w14", diff: 14), item("w15", diff: 15),
            item("s16a", diff: 16), item("s16b", diff: 16), item("s16c", diff: 16),
            item("p17", diff: 17),
            item("x21", diff: 21), item("x22", diff: 22),   // hard outliers the median path would chase
        ]
        let plan = KilterRecommender.recommend(history: [], candidates: candidates, anchor: 16)  // (2,3,1)
        XCTAssertNil(plan.workingDifficulty)
        XCTAssertEqual(plan.picks(for: .warmup).count, 2)
        XCTAssertEqual(plan.picks(for: .send).count, 3)
        XCTAssertEqual(plan.picks(for: .project).count, 1)
        XCTAssertTrue(plan.picks(for: .send).allSatisfy { $0.item.difficulty == 16 })
        XCTAssertFalse(uuids(plan.picks).contains("x21"))
        XCTAssertFalse(uuids(plan.picks).contains("x22"))
    }
}
