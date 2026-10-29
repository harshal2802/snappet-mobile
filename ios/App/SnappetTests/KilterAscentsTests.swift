import XCTest
@testable import Snappet

/// Prompt 208 — filter by what you've climbed: the log index (sent at ANY angle, open projects, badges),
/// the catalog "Not tried" exclusion, and Plan a session's "Projects first".
final class KilterAscentsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func log(_ uuid: String, _ status: KilterAscentStatus, tries: Int = 1, daysAgo: Double = 0,
                     angle: Int = 40) -> KilterAscentIndex.Log {
        .init(climbUUID: uuid, status: status, attempts: tries, date: t0.addingTimeInterval(-daysAgo * 86_400), angle: angle)
    }

    func testSentAtAnyAngleProjectsAndOrdering() {
        let index = KilterAscentIndex([
            log("priest", .sent, tries: 2, daysAgo: 1),
            log("pho", .attempt, tries: 2, daysAgo: 3), log("pho", .project, tries: 1, daysAgo: 1),
            log("legs", .attempt, tries: 2, daysAgo: 13),
            log("wyoming", .sent, daysAgo: 13, angle: 50),
            log("beenice", .attempt, daysAgo: 1),
            log("beenice", .sent, daysAgo: 0),      // tried then sent → no longer a project
        ])
        XCTAssertEqual(index.sentUUIDs, ["beenice", "priest", "wyoming"], "most recent first")
        XCTAssertEqual(index.projectUUIDs, ["pho", "legs"])
        XCTAssertEqual(Set(index.loggedUUIDs), ["priest", "pho", "legs", "wyoming", "beenice"])
        XCTAssertEqual(index.summary("pho")?.tries, 3)
    }

    func testBadgesAndYouLine() {
        let index = KilterAscentIndex([
            log("priest", .sent, tries: 2), log("ghost", .flash), log("wyoming", .sent, angle: 50),
            log("pho", .attempt, tries: 3),
        ])
        XCTAssertEqual(index.badge("priest", angle: 40), "✓ Sent")
        XCTAssertEqual(index.badge("wyoming", angle: 40), "✓ Sent at 50°", "sent at another angle still counts")
        XCTAssertEqual(index.badge("pho", angle: 40), "◐ 3 tries")
        XCTAssertNil(index.badge("never", angle: 40))
        XCTAssertEqual(index.youLine("ghost"), "you: flashed")
        XCTAssertEqual(index.youLine("priest"), "you: sent · 2 tries")
        XCTAssertEqual(index.youLine("pho"), "you: 3 tries")
    }

    func testClimbChoiceAndStrategyDefaults() {
        XCTAssertTrue(KilterPlanClimbChoice.includeSent.allowsSent)
        XCTAssertFalse(KilterPlanClimbChoice.newOnly.allowsSent)
        XCTAssertFalse(KilterPlanClimbChoice.projectsFirst.allowsSent)
        XCTAssertEqual(KilterRecommender.config(for: .balanced).climbChoice, .newOnly)
        XCTAssertEqual(KilterRecommender.config(for: .project).climbChoice, .projectsFirst)
        XCTAssertEqual(KilterRecommender.config(for: .volume).climbChoice, .includeSent)
        XCTAssertEqual(KilterRecommender.config(for: .recovery).climbChoice, .includeSent)
    }

    // MARK: - Plan: projects first

    private func item(_ uuid: String, _ diff: Double) -> KilterListItem {
        KilterListItem(uuid: uuid, name: uuid, setter: "s", difficulty: diff, gradeLabel: "g", quality: 2, ascents: 100)
    }

    private func climbLog(_ uuid: String, _ diff: Double, _ status: KilterAscentStatus, daysAgo: Double = 0) -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: "g", difficulty: diff, status: status,
                       attempts: 1, startedAt: nil, endedAt: nil, loggedAt: t0.addingTimeInterval(-daysAgo * 86_400))
    }

    func testProjectsFirstFillsProjectSlotsWithOpenProjects() {
        // Working grade 20; open projects at 21 (recent) and 22 (older); a far one at 30 is out of reach.
        let history = [climbLog("s1", 20, .sent), climbLog("s2", 20, .sent),
                       climbLog("projA", 21, .attempt, daysAgo: 1), climbLog("projB", 22, .attempt, daysAgo: 5),
                       climbLog("far", 30, .attempt)]
        let candidates = (14...24).flatMap { d in [item("new\(d)a", Double(d)), item("new\(d)b", Double(d))] }
            + [item("projA", 21), item("projB", 22), item("far", 30), item("s1", 20), item("s2", 20)]
        let plan = KilterRecommender.recommend(history: history, candidates: candidates, anchor: 20,
                                               options: .init(targetCount: 5, climbChoice: .projectsFirst,
                                                              mix: .init(warmup: 2, send: 1, project: 2)))
        let projects = plan.picks.filter { $0.goal == .project }.map(\.item.uuid)
        XCTAssertEqual(projects.sorted(), ["projA", "projB"])
        XCTAssertFalse(plan.picks.contains { $0.item.uuid == "far" })
        XCTAssertFalse(plan.picks.filter { $0.goal != .warmup }.contains { $0.item.uuid.hasPrefix("s") },
                       "sent climbs stay out of send / project slots")

        let newOnly = KilterRecommender.recommend(history: history, candidates: candidates, anchor: 20,
                                                  options: .init(targetCount: 5, climbChoice: .newOnly,
                                                                 mix: .init(warmup: 2, send: 1, project: 2)))
        XCTAssertNotEqual(newOnly.picks.filter { $0.goal == .project }.map(\.item.uuid).sorted(), ["projA", "projB"],
                          "without Projects first the slots aren't reserved for projects")
    }

    func testOpenProjectsIgnoreClimbsSentAtAnotherAngle() {
        let open = KilterRecommender.openProjects([climbLog("a", 20, .attempt), climbLog("a", 20, .sent),
                                                   climbLog("b", 20, .project, daysAgo: 2)])
        XCTAssertEqual(Array(open.keys), ["b"])
    }

    /// 2026-10-28 device report: a sent 6c (bph52) was the first warm-up of a "New climbs only" plan.
    func testNewClimbsOnlyKeepsSentClimbsOutOfWarmUpsUnlessNothingNewIsLeft() {
        let history = [climbLog("bph52", 20, .sent), climbLog("joint", 20, .sent),
                       climbLog("s21a", 21, .sent), climbLog("s21b", 21, .sent)]   // working grade 21
        let warmupGrades = [item("bph52", 20), item("new20", 20), item("new19", 19)]
        let atGrade = (21...23).flatMap { d in [item("n\(d)a", Double(d)), item("n\(d)b", Double(d))] }
        let opts = KilterRecommender.Options(targetCount: 6, climbChoice: .newOnly, mix: .init(warmup: 2, send: 3, project: 1))

        let plan = KilterRecommender.recommend(history: history, candidates: warmupGrades + atGrade, anchor: 21, options: opts)
        XCTAssertEqual(plan.picks.filter { $0.goal == .warmup }.map(\.item.uuid).sorted(), ["new19", "new20"])
        XCTAssertFalse(plan.picks.contains { $0.item.uuid == "bph52" })

        // Only one new climb at warm-up grades → the second warm-up falls back to a sent one.
        let sparse = KilterRecommender.recommend(history: history, candidates: [item("bph52", 20), item("new20", 20)] + atGrade,
                                                 anchor: 21, options: opts)
        XCTAssertEqual(sparse.picks.filter { $0.goal == .warmup }.map(\.item.uuid).sorted(), ["bph52", "new20"])

        // Include sent still revisits it freely.
        let incl = KilterRecommender.recommend(history: history, candidates: warmupGrades + atGrade, anchor: 21,
                                               options: .init(targetCount: 6, climbChoice: .includeSent,
                                                              mix: .init(warmup: 2, send: 3, project: 1)))
        XCTAssertEqual(incl.picks.filter { $0.goal == .warmup }.count, 2)
    }

    /// Session length goes up to 30 (user, 2026-10-28) — the plan builder fills it from a big enough pool.
    func testA30ClimbSessionIsFilled() {
        let history = [climbLog("s1", 20, .sent), climbLog("s2", 20, .sent)]
        let pool = (14...24).flatMap { d in (0..<8).map { item("c\(d)-\($0)", Double(d)) } }
        let plan = KilterRecommender.recommend(history: history, candidates: pool, anchor: 20,
                                               options: .init(targetCount: 30, climbChoice: .newOnly))
        XCTAssertEqual(plan.picks.count, 30)
        XCTAssertEqual(Set(plan.picks.map(\.item.uuid)).count, 30, "no climb twice")
    }

    /// The plan header names the whole log in distinct climbs (it read "your last 20 logged climbs" — a count of
    /// entries that sounded like a cut-off window).
    func testPlanHistoryLineCountsDistinctClimbs() {
        let index = KilterAscentIndex([log("a", .sent), log("a", .sent), log("b", .attempt), log("c", .flash)])
        XCTAssertEqual(KilterPlanView.historyLine(index, choice: .newOnly),
                       "3 climbs logged — 2 sent (excluded), 1 project (included)")
        XCTAssertEqual(KilterPlanView.historyLine(index, choice: .includeSent),
                       "3 climbs logged — 2 sent (included), 1 project (included)")
        XCTAssertEqual(KilterPlanView.historyLine(index, choice: .projectsFirst),
                       "3 climbs logged — 2 sent (excluded), 1 project (picked first)")
        XCTAssertEqual(KilterPlanView.historyLine(KilterAscentIndex([]), choice: .newOnly),
                       "No climbs logged yet — starting from the catalog.")
    }
}
