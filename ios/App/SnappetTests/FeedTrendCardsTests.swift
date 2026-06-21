import XCTest
@testable import Snappet

/// F6 follow-on: d3 discipline split (>= 2 disciplines) + d4 90-day trend arrows (volume sign), pure.
final class FeedTrendCardsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    private let cal = Calendar(identifier: .gregorian)

    // MARK: fixtures

    private func kilterSession(dayOffset: Int) -> KilterSessionInput {
        let date = t0.addingTimeInterval(Double(dayOffset) * 86_400)
        return KilterSessionInput(id: UUID(), startedAt: date, endedAt: date.addingTimeInterval(3_600), angle: 40)
    }

    private func workout(dayOffset: Int, discipline: String?, completed: Bool = true) -> WorkoutSessionInput {
        let date = t0.addingTimeInterval(Double(dayOffset) * 86_400)
        let ex = WorkoutExerciseInput(exerciseId: "e", disciplineRaw: discipline,
                                      sets: [WorkoutSetInput(actualReps: 5, actualWeight: 50, completedAt: date)])
        return WorkoutSessionInput(id: UUID(), routineName: "R", startedAt: date,
                                   completedAt: completed ? date.addingTimeInterval(3_000) : nil, exercises: [ex])
    }

    private func log(dayOffset: Int) -> KilterClimbLog {
        let date = t0.addingTimeInterval(Double(dayOffset) * 86_400)
        return KilterClimbLog(climbUUID: UUID().uuidString, climbName: "C", gradeLabel: "V4", difficulty: 13,
                              status: .sent, attempts: 1, startedAt: date, endedAt: date, loggedAt: date, angle: 40)
    }

    private func bucket(_ label: String, _ start: Date, _ sends: Int) -> KilterAllTimeStats.VolumeBucket {
        KilterAllTimeStats.VolumeBucket(periodLabel: label, start: start, sends: sends)
    }

    private func stats(buckets: [KilterAllTimeStats.VolumeBucket]) -> KilterAllTimeStats {
        var s = KilterAllTimeStats.empty
        s.sendsPerWeek = buckets
        return s
    }

    // MARK: d3 — discipline split

    func testDisciplineSplitNeedsTwoDistinctDisciplines() {
        // Only climbing sessions → a single discipline → no card.
        let one = FeedTrendCards.disciplineSplit(
            kilterSessions: [kilterSession(dayOffset: 0), kilterSession(dayOffset: 1)],
            workoutSessions: [])
        XCTAssertNil(one, "a single discipline is not eligible")

        // Climbing + strength → 2 disciplines → a card with desc-by-count slices.
        let two = FeedTrendCards.disciplineSplit(
            kilterSessions: [kilterSession(dayOffset: 0), kilterSession(dayOffset: 1)],
            workoutSessions: [workout(dayOffset: 2, discipline: "strength")])
        guard let split = two else { return XCTFail("expected a discipline split") }
        XCTAssertEqual(split.slices.count, 2)
        XCTAssertEqual(split.slices.first?.label, "Climbing")
        XCTAssertEqual(split.slices.first?.count, 2)
        XCTAssertEqual(split.topLabel, "Climbing")
        // descending by count
        XCTAssertGreaterThanOrEqual(split.slices[0].count, split.slices[1].count)
    }

    func testDisciplineSplitIgnoresIncompleteWorkouts() {
        // An incomplete workout does not add a discipline → only "Climbing" remains → not eligible.
        let split = FeedTrendCards.disciplineSplit(
            kilterSessions: [kilterSession(dayOffset: 0)],
            workoutSessions: [workout(dayOffset: 1, discipline: "running", completed: false)])
        XCTAssertNil(split, "incomplete workouts contribute no discipline")
    }

    func testDisciplineSplitUsesDominantDisciplineAndDefault() {
        // A completed workout whose exercises have no disciplineRaw defaults to "strength".
        let date = t0
        let blankWorkout = WorkoutSessionInput(
            id: UUID(), routineName: "R", startedAt: date, completedAt: date.addingTimeInterval(1_000),
            exercises: [WorkoutExerciseInput(exerciseId: "e", disciplineRaw: nil,
                                             sets: [WorkoutSetInput(actualReps: 5, completedAt: date)])])
        let split = FeedTrendCards.disciplineSplit(
            kilterSessions: [kilterSession(dayOffset: 0)],
            workoutSessions: [blankWorkout])
        guard let split else { return XCTFail("expected a split") }
        XCTAssertEqual(Set(split.slices.map(\.label)), ["Climbing", "strength"])
    }

    // MARK: d4 — trend arrows

    func testTrendArrowsNeedsNinetyDaysOfHistory() {
        // Earliest log only 10 days back → below the 90-day gate → no card even with buckets.
        let now = t0.addingTimeInterval(120 * 86_400)
        let recentLogs = [log(dayOffset: 110)]   // 10 days before `now`
        let buckets = [bucket("W1", t0, 1), bucket("W2", t0, 5)]
        XCTAssertNil(FeedTrendCards.trendArrows(allTime: stats(buckets: buckets), logs: recentLogs, now: now))
    }

    func testTrendArrowsImprovingWhenNewerHalfHigher() {
        let now = t0.addingTimeInterval(200 * 86_400)
        let oldLogs = [log(dayOffset: 0)]   // ~200 days back → passes the 90-day gate
        // older half mean = 1, newer half mean = 5 → +400%, improving.
        let buckets = [
            bucket("W1", t0, 1), bucket("W2", t0, 1),
            bucket("W3", t0, 5), bucket("W4", t0, 5),
        ]
        guard let payload = FeedTrendCards.trendArrows(allTime: stats(buckets: buckets), logs: oldLogs, now: now) else {
            return XCTFail("expected a trend arrows payload")
        }
        XCTAssertEqual(payload.arrows.count, 1)
        let arrow = payload.arrows[0]
        XCTAssertEqual(arrow.label, "Weekly volume")
        XCTAssertTrue(arrow.improving)
        XCTAssertEqual(arrow.deltaPct, 400)
    }

    func testTrendArrowsDecliningWhenNewerHalfLower() {
        let now = t0.addingTimeInterval(200 * 86_400)
        let oldLogs = [log(dayOffset: 0)]
        // older mean = 6, newer mean = 3 → -50%, not improving.
        let buckets = [
            bucket("W1", t0, 6), bucket("W2", t0, 6),
            bucket("W3", t0, 3), bucket("W4", t0, 3),
        ]
        guard let payload = FeedTrendCards.trendArrows(allTime: stats(buckets: buckets), logs: oldLogs, now: now) else {
            return XCTFail("expected a trend arrows payload")
        }
        XCTAssertFalse(payload.arrows[0].improving)
        XCTAssertEqual(payload.arrows[0].deltaPct, -50)
    }

    func testTrendArrowsNeedsTwoBuckets() {
        let now = t0.addingTimeInterval(200 * 86_400)
        let oldLogs = [log(dayOffset: 0)]
        // A single bucket cannot form two non-empty halves.
        XCTAssertNil(FeedTrendCards.trendArrows(allTime: stats(buckets: [bucket("W1", t0, 4)]), logs: oldLogs, now: now))
    }

    // MARK: degrade-by-absence + end-to-end

    func testDegradeByAbsenceOnEmpty() {
        let cards = FeedTrendCards.cards(allTime: .empty, kilterSessions: [], workoutSessions: [],
                                         logs: [], now: t0, calendar: cal, anchor: t0)
        XCTAssertTrue(cards.isEmpty, "no inputs → no cards")
    }

    func testCardsAreAggregatesWithNoContentId() {
        let now = t0.addingTimeInterval(200 * 86_400)
        let buckets = [bucket("W1", t0, 1), bucket("W2", t0, 1), bucket("W3", t0, 5), bucket("W4", t0, 5)]
        let cards = FeedTrendCards.cards(
            allTime: stats(buckets: buckets),
            kilterSessions: [kilterSession(dayOffset: 190)],
            workoutSessions: [workout(dayOffset: 191, discipline: "strength")],
            logs: [log(dayOffset: 0)], now: now, calendar: cal, anchor: now)
        XCTAssertEqual(Set(cards.map(\.kind)), [.d3DisciplineSplit, .d4TrendArrows])
        for c in cards {
            XCTAssertEqual(c.contentId, "", "aggregate cards carry no per-climb contentId")
            XCTAssertEqual(c.sourceRefs.first?.objectKind, "aggregate")
            XCTAssertEqual(c.category, .trend)
            XCTAssertLessThanOrEqual(c.anchorDate, now, "anchorDate is never in the future")
        }
    }
}
