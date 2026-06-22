import XCTest
@testable import Snappet

/// The wording / accent / icon guard for the Recap feed's ONE card → display mapping (`FeedCardDisplay`).
///
/// Before this descriptor, FOUR surfaces each owned a parallel switch and drifted apart (the D1–D25
/// audit). Now every surface reads `FeedCard.display(unit:)`. This test pins one golden
/// `(kicker, hero, heroCaption, primaryLine, accent, iconName)` per representative case across all 27
/// `FeedCardKind`s, so any future copy/accent change is intentional (and the Kotlin port has a parity
/// vector). It also covers the unit-aware run hero (km vs mi) folded into the descriptor.
final class FeedCardDisplayTests: XCTestCase {

    /// Assert the descriptor's six pinned fields for one payload.
    private func assertDisplay(_ payload: FeedCardPayload, kind: FeedCardKind, unit: DistanceUnit = .km,
                               kicker: String, hero: String, heroCaption: String, primaryLine: String?,
                               accent: FeedAccent, iconName: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let d = FeedCardDisplay(payload: payload, kind: kind, distanceUnit: unit)
        XCTAssertEqual(d.kicker, kicker, "kicker", file: file, line: line)
        XCTAssertEqual(d.hero, hero, "hero", file: file, line: line)
        XCTAssertEqual(d.heroCaption, heroCaption, "heroCaption", file: file, line: line)
        XCTAssertEqual(d.primaryLine, primaryLine, "primaryLine", file: file, line: line)
        XCTAssertEqual(d.accent, accent, "accent", file: file, line: line)
        XCTAssertEqual(d.iconName, iconName, "iconName", file: file, line: line)
    }

    // MARK: a1 / a2 — sessions

    func testClimbSession() {
        assertDisplay(.climbSession(ClimbSessionPayload(
            title: "Morning board", hardestSendGrade: "V6", totalClimbs: 12, sends: 8, projects: 2,
            attemptsOnly: 2, totalAttempts: 19, durationSec: 3600, angle: 40, pyramid: [], isPRSession: false)),
            kind: .a1Session,
            kicker: "Morning board", hero: "V6", heroCaption: "Hardest send",
            primaryLine: "8 sends", accent: .kilter, iconName: "figure.climbing")
    }

    func testWorkoutSessionLift() {
        assertDisplay(.workoutSession(WorkoutSessionPayload(
            title: "Push day", disciplineRaw: "strength", totalVolume: 1250, distanceMeters: nil,
            exerciseCount: 5, setCount: 18, durationSec: 3000)),
            kind: .a2Session,
            kicker: "Push day", hero: "1,250 kg", heroCaption: "Volume",
            primaryLine: "18 sets", accent: .workout, iconName: "dumbbell.fill")
    }

    func testWorkoutSessionRunKilometers() {
        assertDisplay(.workoutSession(WorkoutSessionPayload(
            title: "Tempo run", disciplineRaw: "running", totalVolume: 0, distanceMeters: 5200,
            exerciseCount: 1, setCount: 4, durationSec: 1560)),
            kind: .a2Session, unit: .km,
            kicker: "Tempo run", hero: "5.2 km", heroCaption: "Distance",
            primaryLine: "4 splits", accent: .workout, iconName: "figure.run")
    }

    func testWorkoutSessionRunMiles() {
        // Same payload, miles unit → the hero distance converts (unit-awareness folded into the descriptor).
        assertDisplay(.workoutSession(WorkoutSessionPayload(
            title: "Tempo run", disciplineRaw: "running", totalVolume: 0, distanceMeters: 1609.344,
            exerciseCount: 1, setCount: 1, durationSec: 480)),
            kind: .a2Session, unit: .mi,
            kicker: "Tempo run", hero: "1 mi", heroCaption: "Distance",
            primaryLine: "1 splits", accent: .workout, iconName: "figure.run")
    }

    // MARK: b — milestones

    func testGradePRWithPrevious() {
        assertDisplay(.gradePR(GradePRPayload(newGrade: "V7", newDifficulty: 21, previousGrade: "V6", climbName: "Crimp City")),
            kind: .b1GradePR,
            kicker: "New hardest ever", hero: "V7", heroCaption: "New grade",
            primaryLine: "up from V6", accent: .brand, iconName: "trophy.fill")
    }

    func testGradePRFirstPeak() {
        assertDisplay(.gradePR(GradePRPayload(newGrade: "V4", newDifficulty: 12, previousGrade: nil, climbName: "")),
            kind: .b1GradePR,
            kicker: "New hardest ever", hero: "V4", heroCaption: "New grade",
            primaryLine: "your first peak", accent: .brand, iconName: "trophy.fill")
    }

    func testMostClimbsBeat() {
        assertDisplay(.mostClimbs(MostClimbsPayload(count: 22, previousRecord: 18)),
            kind: .b3MostClimbs,
            kicker: "Biggest session", hero: "22", heroCaption: "climbs in one go",
            primaryLine: "beat 18", accent: .kilter, iconName: "flame.fill")
    }

    func testStreakRecord() {
        assertDisplay(.streak(StreakPayload(days: 14, weeks: 2, isRecord: true, previousBest: 10)),
            kind: .b5Streak,
            kicker: "Longest streak ever", hero: "14", heroCaption: "days in a row",
            primaryLine: "past best 10", accent: .kilter, iconName: "crown.fill")
    }

    func testStreakNonRecord() {
        assertDisplay(.streak(StreakPayload(days: 5, weeks: 1, isRecord: false, previousBest: 0)),
            kind: .b5Streak,
            kicker: "Streak", hero: "5", heroCaption: "days in a row",
            primaryLine: "1 week unbroken", accent: .kilter, iconName: "calendar")
    }

    func testFirstAtGrade() {
        assertDisplay(.firstAtGrade(FirstAtGradePayload(grade: "V5", climbName: "Slab Master")),
            kind: .b2FirstAtGrade,
            kicker: "First at grade", hero: "V5", heroCaption: "your first V5",
            primaryLine: "Slab Master", accent: .kilter, iconName: "star.fill")
    }

    func testLiftPRWithPrevious() {
        assertDisplay(.liftPR(LiftPRPayload(exerciseName: "Bench", oneRepMaxKg: 100, weightKg: 90, reps: 5,
                                            previousOneRepMaxKg: 95, unit: "kg")),
            kind: .b4LiftPR,
            kicker: "Lift PR", hero: "100 kg", heroCaption: "est. 1RM · Bench",
            primaryLine: "was 95 kg", accent: .brand, iconName: "dumbbell.fill")
    }

    // MARK: c — pyramid / progression / level / angles

    func testPyramid() {
        let rows = [PyramidRow(grade: "V5", difficulty: 15, sends: 4, flashes: 1, projects: 0, attemptsOnly: 0),
                    PyramidRow(grade: "V6", difficulty: 18, sends: 2, flashes: 0, projects: 0, attemptsOnly: 0),
                    PyramidRow(grade: "V7", difficulty: 21, sends: 0, flashes: 0, projects: 0, attemptsOnly: 1)]
        assertDisplay(.pyramid(PyramidPayload(rows: rows, totalSends: 6, maxGrade: "V6")),
            kind: .c1Pyramid,
            kicker: "Grade pyramid", hero: "V6", heroCaption: "6 sends",
            primaryLine: "across 2 grades", accent: .kilter, iconName: "triangle.fill")
    }

    func testPyramidHealth() {
        assertDisplay(.pyramidHealth(PyramidHealthPayload(rows: [], consolidateGrade: "V5", note: "Shore up V5 before pushing on")),
            kind: .c2PyramidHealth,
            kicker: "Pyramid health", hero: "V5", heroCaption: "consolidate",
            primaryLine: "Shore up V5 before pushing on", accent: .kilter, iconName: "triangle.fill")
    }

    func testProgression() {
        let pts = [ProgressionPayload.Point(label: "Jan", grade: "V4"),
                   ProgressionPayload.Point(label: "Feb", grade: "V5"),
                   ProgressionPayload.Point(label: "Mar", grade: "V6")]
        assertDisplay(.progression(ProgressionPayload(points: pts, fromGrade: "V4", toGrade: "V6")),
            kind: .c3Progression,
            kicker: "Progression", hero: "V4 → V6", heroCaption: "over 3 months",
            primaryLine: nil, accent: .kilter, iconName: "chart.line.uptrend.xyaxis")
    }

    func testClimbingLevel() {
        assertDisplay(.climbingLevel(ClimbingLevelPayload(level: "V5", maxGrade: "V7")),
            kind: .c4ClimbingLevel,
            kicker: "Climbing level", hero: "V5", heroCaption: "working grade",
            primaryLine: "max V7", accent: .kilter, iconName: "figure.climbing")
    }

    func testAngleDist() {
        let slices = [AngleDistPayload.Slice(angle: 40, sends: 10), AngleDistPayload.Slice(angle: 30, sends: 6)]
        assertDisplay(.angleDist(AngleDistPayload(slices: slices, topAngle: 40)),
            kind: .c5AngleDist,
            kicker: "Angles", hero: "40°", heroCaption: "most sends",
            primaryLine: "2 angles climbed", accent: .kilter, iconName: "ruler")
    }

    // MARK: d — trends

    func testWeeklyVolume() {
        let buckets = [WeeklyVolumePayload.Bucket(label: "W1", sends: 8),
                       WeeklyVolumePayload.Bucket(label: "W2", sends: 12)]
        assertDisplay(.weeklyVolume(WeeklyVolumePayload(buckets: buckets, deltaVsPrev: 4)),
            kind: .d1WeeklyVolume,
            kicker: "Weekly volume", hero: "12", heroCaption: "sends this week",
            primaryLine: "▲ 4 vs last week", accent: .kilter, iconName: "chart.bar.fill")
    }

    func testPeriodVsLast() {
        assertDisplay(.periodVsLast(PeriodVsLastPayload(currentLabel: "June", current: 30, previous: 24)),
            kind: .d2PeriodVsLast,
            kicker: "This period", hero: "30", heroCaption: "sends · June",
            primaryLine: "▲ 6 vs last", accent: .kilter, iconName: "calendar")
    }

    func testDisciplineSplit() {
        let slices = [DisciplineSplitPayload.Slice(label: "Climbing", count: 12),
                      DisciplineSplitPayload.Slice(label: "Strength", count: 5)]
        assertDisplay(.disciplineSplit(DisciplineSplitPayload(slices: slices, topLabel: "Climbing")),
            kind: .d3DisciplineSplit,
            kicker: "Discipline split", hero: "Climbing", heroCaption: "most sessions",
            primaryLine: "Climbing 12 · Strength 5", accent: .workout, iconName: "chart.pie.fill")
    }

    func testTrendArrows() {
        let arrows = [TrendArrowsPayload.Arrow(label: "Volume", deltaPct: 12, improving: true),
                      TrendArrowsPayload.Arrow(label: "Grade", deltaPct: -3, improving: false)]
        assertDisplay(.trendArrows(TrendArrowsPayload(arrows: arrows)),
            kind: .d4TrendArrows,
            kicker: "90-day trends", hero: "▲ 12%", heroCaption: "Volume",
            primaryLine: "Grade ▼3%", accent: .kilter, iconName: "arrow.up.arrow.down")
    }

    // MARK: e — HR / effort

    func testEffort() {
        assertDisplay(.effort(EffortPayload(title: "Hard session", zones: [], avgBpm: 140, maxBpm: 178,
                                            trimp: 88, redlineSeconds: 120, totalSeconds: 3000, durationSec: 3000)),
            kind: .e1Effort,
            kicker: "Hard session", hero: "178", heroCaption: "Peak BPM",
            primaryLine: "avg 140 · TRIMP 88", accent: .effort, iconName: "bolt.heart.fill")
    }

    func testHardestEffort() {
        assertDisplay(.hardestEffort(HardestEffortPayload(grade: "V6", climbName: "Redline", peakBpm: 182,
                                                          peakHRRPercent: 88, zoneAtPeak: 5, sendTimeOffsetSec: 600)),
            kind: .e2HardestEffort,
            kicker: "Hardest-effort send", hero: "182", heroCaption: "Peak BPM on a send",
            primaryLine: "V6 · 88% HRR · Z5 · Max", accent: .effort, iconName: "flame.fill")
    }

    func testHRTrend() {
        let pts = [HRTrendPayload.Point(date: Date(timeIntervalSince1970: 0), avgBpm: 150, maxBpm: 180),
                   HRTrendPayload.Point(date: Date(timeIntervalSince1970: 100), avgBpm: 144, maxBpm: 176)]
        assertDisplay(.hrTrend(HRTrendPayload(points: pts)),
            kind: .e3HRTrend,
            kicker: "HR trend", hero: "144", heroCaption: "Recent avg BPM",
            primaryLine: "▼ 6 bpm vs first", accent: .workout, iconName: "chart.xyaxis.line")
    }

    func testEffortEfficiency() {
        assertDisplay(.effortEfficiency(EffortEfficiencyPayload(gradeBand: "V5", oldAvgBpm: 165, newAvgBpm: 152)),
            kind: .e4EffortEfficiency,
            kicker: "Fitness gain", hero: "152", heroCaption: "avg BPM sending V5",
            primaryLine: "was 165 — same grade, less effort", accent: .recovery, iconName: "bolt.heart")
    }

    func testHRVRecovery() {
        assertDisplay(.hrvRecovery(HRVRecoveryPayload(rmssd: 62, note: "Well recovered")),
            kind: .e5HRVRecovery,
            kicker: "Recovery", hero: "62", heroCaption: "RMSSD",
            primaryLine: "Well recovered", accent: .recovery, iconName: "heart.text.square")
    }

    // MARK: a3 / g1 / onThisDay / restNudge

    func testOnTheBoardHardest() {
        assertDisplay(.onTheBoard(OnTheBoardPayload(litCount: 9, hardestGrade: "V5", gradeSpread: "V3–V5")),
            kind: .a3OnTheBoard,
            kicker: "On the board", hero: "9", heroCaption: "climbs lit",
            primaryLine: "hardest V5", accent: .kilter, iconName: "square.grid.3x3.fill")
    }

    func testOnTheBoardNoGrade() {
        assertDisplay(.onTheBoard(OnTheBoardPayload(litCount: 4, hardestGrade: nil, gradeSpread: "")),
            kind: .a3OnTheBoard,
            kicker: "On the board", hero: "4", heroCaption: "climbs lit",
            primaryLine: "pulled up, not logged", accent: .kilter, iconName: "square.grid.3x3.fill")
    }

    func testProjectSent() {
        assertDisplay(.projectSent(ProjectSentPayload(grade: "V7", climbName: "The Nemesis", sessions: 3)),
            kind: .g1ProjectSent,
            kicker: "Project sent", hero: "V7", heroCaption: "after 3 sessions",
            primaryLine: "The Nemesis", accent: .brand, iconName: "checkmark.seal.fill")
    }

    func testConsistency() {
        assertDisplay(.consistency(ConsistencyPayload(activeDays: 18, windowDays: 30, perDay: [])),
            kind: .consistencyMap,
            kicker: "Consistency", hero: "18", heroCaption: "active days",
            primaryLine: "in the last 30", accent: .kilter, iconName: "square.grid.3x3.fill")
    }

    func testOnThisDay() {
        assertDisplay(.onThisDay(OnThisDayPayload(yearsAgo: 2, grade: "V4", summary: "Sent your first V4")),
            kind: .onThisDay,
            kicker: "On this day", hero: "V4", heroCaption: "2 yr ago",
            primaryLine: "Sent your first V4", accent: .kilter, iconName: "clock.arrow.circlepath")
    }

    func testRestNudge() {
        assertDisplay(.restNudge(RestNudgePayload(hardDays: 4, note: "Take a rest day")),
            kind: .restNudge,
            kicker: "Go gentler", hero: "4", heroCaption: "hard days in a row",
            primaryLine: "Take a rest day", accent: .aerobic, iconName: "leaf.fill")
    }

    // MARK: coverage guard

    func testEveryKindHasANonEmptyDisplay() {
        // A smoke check that the descriptor produces a non-empty kicker/hero for a representative payload
        // of EVERY kind — so a newly-added FeedCardKind can't silently render blank.
        let samples: [(FeedCardKind, FeedCardPayload)] = [
            (.a1Session, .climbSession(ClimbSessionPayload(title: nil, hardestSendGrade: "V3", totalClimbs: 1,
                sends: 1, projects: 0, attemptsOnly: 0, totalAttempts: 1, durationSec: 60, angle: 30,
                pyramid: [], isPRSession: false))),
            (.a2Session, .workoutSession(WorkoutSessionPayload(title: "W", disciplineRaw: "strength",
                totalVolume: 100, distanceMeters: nil, exerciseCount: 1, setCount: 1, durationSec: 60))),
            (.b1GradePR, .gradePR(GradePRPayload(newGrade: "V3", newDifficulty: 9, previousGrade: nil, climbName: ""))),
            (.b2FirstAtGrade, .firstAtGrade(FirstAtGradePayload(grade: "V3", climbName: "X"))),
            (.b3MostClimbs, .mostClimbs(MostClimbsPayload(count: 5, previousRecord: nil))),
            (.b4LiftPR, .liftPR(LiftPRPayload(exerciseName: "X", oneRepMaxKg: 80, weightKg: 70, reps: 5,
                previousOneRepMaxKg: nil, unit: "kg"))),
            (.b5Streak, .streak(StreakPayload(days: 3, weeks: 0, isRecord: false, previousBest: 0))),
            (.c1Pyramid, .pyramid(PyramidPayload(rows: [], totalSends: 1, maxGrade: "V3"))),
            (.c2PyramidHealth, .pyramidHealth(PyramidHealthPayload(rows: [], consolidateGrade: "V3", note: "n"))),
            (.c3Progression, .progression(ProgressionPayload(points: [], fromGrade: "V3", toGrade: "V4"))),
            (.c4ClimbingLevel, .climbingLevel(ClimbingLevelPayload(level: "V3", maxGrade: nil))),
            (.c5AngleDist, .angleDist(AngleDistPayload(slices: [], topAngle: 30))),
            (.d1WeeklyVolume, .weeklyVolume(WeeklyVolumePayload(buckets: [], deltaVsPrev: 0))),
            (.d2PeriodVsLast, .periodVsLast(PeriodVsLastPayload(currentLabel: "X", current: 1, previous: 0))),
            (.d3DisciplineSplit, .disciplineSplit(DisciplineSplitPayload(slices: [], topLabel: "X"))),
            (.d4TrendArrows, .trendArrows(TrendArrowsPayload(arrows: []))),
            (.e1Effort, .effort(EffortPayload(title: nil, zones: [], avgBpm: 1, maxBpm: 1, trimp: 1,
                redlineSeconds: 0, totalSeconds: 1, durationSec: 1))),
            (.e2HardestEffort, .hardestEffort(HardestEffortPayload(grade: "V3", climbName: "X", peakBpm: 1,
                peakHRRPercent: nil, zoneAtPeak: 0, sendTimeOffsetSec: 0))),
            (.e3HRTrend, .hrTrend(HRTrendPayload(points: []))),
            (.e4EffortEfficiency, .effortEfficiency(EffortEfficiencyPayload(gradeBand: "V3", oldAvgBpm: 2, newAvgBpm: 1))),
            (.e5HRVRecovery, .hrvRecovery(HRVRecoveryPayload(rmssd: 1, note: "n"))),
            (.a3OnTheBoard, .onTheBoard(OnTheBoardPayload(litCount: 1, hardestGrade: nil, gradeSpread: ""))),
            (.g1ProjectSent, .projectSent(ProjectSentPayload(grade: "V3", climbName: "X", sessions: 1))),
            (.consistencyMap, .consistency(ConsistencyPayload(activeDays: 1, windowDays: 7, perDay: []))),
            (.onThisDay, .onThisDay(OnThisDayPayload(yearsAgo: 1, grade: nil, summary: "s"))),
            (.restNudge, .restNudge(RestNudgePayload(hardDays: 1, note: "n"))),
        ]
        XCTAssertEqual(samples.count, FeedCardKind.allCases.count, "every FeedCardKind has a sample")
        for (kind, payload) in samples {
            let d = FeedCardDisplay(payload: payload, kind: kind)
            XCTAssertFalse(d.kicker.isEmpty, "\(kind) kicker non-empty")
            XCTAssertFalse(d.hero.isEmpty, "\(kind) hero non-empty")
            XCTAssertFalse(d.heroCaption.isEmpty, "\(kind) heroCaption non-empty")
            XCTAssertFalse(d.iconName.isEmpty, "\(kind) iconName non-empty")
        }
    }

    // MARK: identifier parity (byte-for-byte with the old literals)

    func testIdentifierDerivesFromKind() {
        func card(_ kind: FeedCardKind) -> FeedCard {
            FeedCard(id: "x", kind: kind, category: .trend, salience: 0, anchorDate: Date(),
                     sourceRefs: [], payload: .streak(StreakPayload(days: 3, weeks: 0)))
        }
        XCTAssertEqual(card(.a1Session).identifier, "feed.card.a1Session")
        XCTAssertEqual(card(.b1GradePR).identifier, "feed.card.b1GradePR")
        XCTAssertEqual(card(.consistencyMap).identifier, "feed.card.consistencyMap")
        XCTAssertEqual(card(.restNudge).identifier, "feed.card.restNudge")
        XCTAssertEqual(card(.g1ProjectSent).identifier, "feed.card.g1ProjectSent")
    }
}
