import XCTest
import SwiftData
@testable import Snappet

/// Prompt 146 — the history behind a session, tested on the same four-week fixture the redesign was
/// reviewed with (`RoutineHistorySeed`): Push Day ×8, Finger day ×6, Bouldering ×5, Easy run ×4.
@MainActor
final class SessionInsightsTests: XCTestCase {
    private var container: ModelContainer!
    private var all: [WorkoutSession] = []

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        RoutineHistorySeed.seed(into: container.mainContext, now: Date(timeIntervalSince1970: 1_790_000_000))
        all = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    override func tearDown() async throws { container = nil }

    private func latest(_ name: String) -> WorkoutSession { all.filter { $0.routineName == name }.last! }
    private func name(_ ex: SessionExercise) -> String { ex.displayName ?? ex.exerciseId }

    // MARK: - Series

    func testComparesWithTheRoutineOrTheSameQuickSession() {
        let push = latest("Push Day")
        XCTAssertEqual(SessionInsights.comparable(for: push, in: all).count, 7)
        let boulder = latest("Bouldering")
        XCTAssertEqual(SessionInsights.comparable(for: boulder, in: all).count, 4, "no routine: same name + type")
        XCTAssertEqual(SessionInsights.Kind.of(boulder), .climb)
        XCTAssertEqual(SessionInsights.Kind.of(latest("Finger day")), .hangboard)
        XCTAssertEqual(SessionInsights.Kind.of(latest("Easy run")), .run)
    }

    func testOrdinalsAndMilestones() {
        XCTAssertEqual(SessionInsights.ordinal(8), "8th")
        XCTAssertEqual(SessionInsights.ordinal(11), "11th")
        XCTAssertEqual(SessionInsights.ordinal(22), "22nd")
        XCTAssertEqual(SessionInsights.ordinal(103), "103rd")
        XCTAssertTrue(SessionInsights.nextMilestone(count: 8) == (10, 5))
        XCTAssertTrue(SessionInsights.nextMilestone(count: 10) == (25, 10))
    }

    func testWeekStreakCountsBackFromThisWeek() {
        let push = latest("Push Day")
        let prior = SessionInsights.comparable(for: push, in: all)
        XCTAssertGreaterThanOrEqual(SessionInsights.weekStreak(push, prior: prior), 4)
    }

    // MARK: - Strength

    func testStrengthHeadlineShowsChangeSinceLastTime() {
        let push = latest("Push Day")
        let prior = SessionInsights.comparable(for: push, in: all)
        let now = SessionInsights.headline(push, unit: .kg)
        let last = SessionInsights.headline(prior[0], unit: .kg)
        XCTAssertEqual(now.map(\.label), ["kg volume", "top set", "sets"])
        XCTAssertEqual(now[1].display, "67.5×6")
        let top = SessionInsights.change(now[1], last: last[1], kind: .strength)
        XCTAssertEqual(top?.text, "▲ +2.5 kg")
        XCTAssertEqual(top?.direction, .better)
    }

    func testStrengthBadgesAreRealRecords() {
        let push = latest("Push Day")
        let prior = SessionInsights.comparable(for: push, in: all)
        let badges = SessionInsights.badges(push, prior: prior, allHistory: all, resolve: name, unit: .kg)
        XCTAssertTrue(badges.contains { if case .weightPR(_, let kg, 6, let prev) = $0 { return kg == 67.5 && prev == 65 }; return false },
                      "\(badges)")
        XCTAssertTrue(badges.contains(.bestVolume(name: "Push Day")))
        XCTAssertTrue(badges.contains { if case .weekStreak = $0 { return true }; return false })
    }

    func testExercisesCompareThemselves() {
        let push = latest("Push Day")
        let rows = SessionInsights.exerciseCompares(push, history: all, unit: .kg, resolve: name)
        XCTAssertEqual(rows.count, 3)
        let bench = rows[0]
        XCTAssertEqual(bench.change?.text, "▲ +2.5 kg")
        XCTAssertEqual(bench.setChanges.first, "+2.5 kg")
        XCTAssertTrue(bench.summary.contains("est. 1RM"), bench.summary)
        XCTAssertGreaterThanOrEqual(bench.trend.count, 3)
        let pulls = rows[2]
        XCTAssertTrue(pulls.summary.contains("bodyweight"), "bodyweight reports reps, never 0 kg: \(pulls.summary)")
        XCTAssertTrue(pulls.trend.isEmpty)
    }

    func testStalledLiftGetsANudge() {
        // OHP was 37.5 kg for the last two seeded sessions; add a third at the same weight.
        let push = latest("Push Day")
        var ex = push.exercises
        for i in ex.indices where ex[i].exerciseId == "Standing_Military_Press" {
            ex[i].sets = ex[i].sets.map { var s = $0; s.actualWeight = 37.5; return s }
        }
        push.exercises = ex
        // The two sessions before it as well — "held for 3 sessions" means three in a row.
        for prev in all.filter({ $0.routineName == "Push Day" }).dropLast().suffix(2) {
            var pex = prev.exercises
            for i in pex.indices where pex[i].exerciseId == "Standing_Military_Press" {
                pex[i].sets = pex[i].sets.map { var s = $0; s.actualWeight = 37.5; return s }
            }
            prev.exercises = pex
        }
        let rows = SessionInsights.exerciseCompares(push, history: all, unit: .kg, resolve: name)
        XCTAssertNotNil(rows.first { $0.id == push.exercises[1].id }?.nudge)
    }

    func testProgressHasTheRoutineTrendAndBest() {
        let push = latest("Push Day")
        let p = SessionInsights.progress(push, prior: SessionInsights.comparable(for: push, in: all), unit: .kg)
        XCTAssertEqual(p?.title, "Volume")
        XCTAssertEqual(p?.points.count, 8)
        XCTAssertEqual(p?.points.last, p?.best, "today is the best ever")
    }

    // MARK: - Hangboard

    func testHangboardHeadlineBadgesAndForceGrid() {
        let f = latest("Finger day")
        let prior = SessionInsights.comparable(for: f, in: all)
        let h = SessionInsights.headline(f, unit: .kg)
        XCTAssertEqual(h.map(\.label), ["kg added", "kg peak force", "hangs"])
        XCTAssertEqual(h[0].display, "+11.25")
        XCTAssertEqual(h[2].display, "9/9")
        XCTAssertEqual(SessionInsights.change(h[0], last: SessionInsights.headline(prior[0], unit: .kg)[0], kind: .hangboard)?.text,
                       "▲ +1.25")
        let badges = SessionInsights.badges(f, prior: prior, allHistory: all, resolve: name, unit: .kg)
        XCTAssertTrue(badges.contains(.heaviestLoad(kg: 11.25)))
        XCTAssertTrue(badges.contains { if case .peakForcePR = $0 { return true }; return false })
        let grid = SessionInsights.forceGrid(f)
        XCTAssertEqual(grid?.cells.count, 3)
        XCTAssertEqual(grid?.cells.first?.count, 3)
        XCTAssertGreaterThan(grid?.fatigue ?? 0, 0)
        XCTAssertEqual(SessionInsights.progress(f, prior: prior, unit: .kg)?.title, "Added load")
    }

    // MARK: - Climbing + running

    func testClimbingShowsTheFirstSendAndPyramid() {
        let b = latest("Bouldering")
        let prior = SessionInsights.comparable(for: b, in: all)
        let badges = SessionInsights.badges(b, prior: prior, allHistory: all, resolve: name, unit: .kg)
        XCTAssertTrue(badges.contains(.firstSend(grade: "V5")), "\(badges)")
        let h = SessionInsights.headline(b, unit: .kg)
        XCTAssertEqual(h[1].display, "V5")
        XCTAssertEqual(SessionInsights.change(h[1], last: SessionInsights.headline(prior[0], unit: .kg)[1], kind: .climb)?.text,
                       "▲ new high")
        let rows = SessionInsights.pyramid(b, history: all)
        XCTAssertEqual(rows.first?.grade, "V5")
        XCTAssertEqual(rows.first?.today, 2)
        XCTAssertGreaterThan(rows.first { $0.grade == "V4" }?.last30 ?? 0, 0)
    }

    func testRunningPaceIsLowerIsBetter() {
        let r = latest("Easy run")
        let prior = SessionInsights.comparable(for: r, in: all)
        let h = SessionInsights.headline(r, unit: .kg)
        let pace = SessionInsights.change(h[1], last: SessionInsights.headline(prior[0], unit: .kg)[1], kind: .run)
        XCTAssertEqual(pace?.text, "▼ 9 s faster")
        XCTAssertEqual(pace?.direction, .better)
        let badges = SessionInsights.badges(r, prior: prior, allHistory: all, resolve: name, unit: .kg)
        XCTAssertTrue(badges.contains { if case .fastestPace = $0 { return true }; return false })
        XCTAssertEqual(SessionInsights.progress(r, prior: prior, unit: .kg)?.lowerIsBetter, true)
    }

    // MARK: - Bug fixes

    func testHeartRateRecoveryNeverPrintsADoubleMinus() {
        XCTAssertEqual(HREffortBadge.recoveryText(8.2), "−8 bpm rec.")
        XCTAssertNil(HREffortBadge.recoveryText(-3), "HR still rising — no '−−3'")
        XCTAssertNil(HREffortBadge.recoveryText(0.3))
    }
}
