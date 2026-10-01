import Foundation
import SwiftData

/// Test-only seed (prompt 146): several weeks of realistic history across workout types, so the session
/// detail can be reviewed and UI-tested with real "vs last time" / trend / streak data on the simulator.
///
/// `-uiTestSeedRoutineHistory` — implies a fresh in-memory store (see `SnappetApp`), zero production
/// impact. Seeds:
/// - **Push Day** (strength, Mon/Thu schedule): 8 sessions over 4 weeks, bench/OHP creeping up, the
///   latest a bench PR.
/// - **Finger day** (Max hangs protocol with added load + Tindeq force reps): 6 sessions, load rising.
/// - **Bouldering** (quick sessions): 5 sessions, grades rising, latest a first V5 send.
/// - **Easy run**: 4 sessions, pace improving.
enum RoutineHistorySeed {
    static let argument = "-uiTestSeedRoutineHistory"
    static let pushDayID = UUID(uuidString: "5EED0001-0000-0000-0000-00000000B001")!
    static let fingerDayID = UUID(uuidString: "5EED0001-0000-0000-0000-00000000F001")!

    @MainActor
    static func seedIfRequested(into context: ModelContext, now: Date = .now) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        seed(into: context, now: now)
    }

    /// The seed itself — also used directly by `SessionInsightsTests` as a realistic fixture.
    @MainActor
    static func seed(into context: ModelContext, now: Date = .now) {
        let cal = Calendar.current
        func daysAgo(_ d: Int, hour: Int = 18) -> Date {
            let day = cal.date(byAdding: .day, value: -d, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }

        // Push Day routine + schedule.
        let push = Routine(id: pushDayID, name: "Push Day", exercises: [
            RoutineExercise(exerciseId: "Barbell_Bench_Press_-_Medium_Grip", sets: 4, reps: "6", restSeconds: 150,
                            weight: 60, weightUnit: .kg),
            RoutineExercise(exerciseId: "Standing_Military_Press", sets: 3, reps: "8", restSeconds: 120,
                            weight: 35, weightUnit: .kg),
            RoutineExercise(exerciseId: "Pullups", sets: 3, reps: "8", restSeconds: 90),
        ], isStarter: false)
        var schedule = RoutineSchedule(startDay: DayKey(daysAgo(30), calendar: cal))
        schedule.repeatRule = .weekly(weekdays: [2, 5], everyWeeks: 1)
        push.schedule = schedule
        context.insert(push)

        // 8 sessions: every ~3.5 days, oldest first; bench +2.5 kg every other session.
        for (i, ago) in [28, 24, 21, 17, 14, 10, 7, 0].enumerated() {
            let start = daysAgo(ago)
            let bench = 57.5 + Double(i / 2) * 2.5 + (i == 7 ? 2.5 : 0)   // latest = PR
            let ohp = 32.5 + Double(i / 3) * 2.5
            let pullReps = 6 + i / 3
            func sets(_ n: Int, reps: Int, kg: Double?, from t: Date) -> [SetLog] {
                (0..<n).map { k in
                    var s = SetLog(actualReps: reps - (k == n - 1 && i % 2 == 0 ? 1 : 0), actualWeight: kg, weightUnit: kg == nil ? nil : .kg)
                    s.completedAt = t.addingTimeInterval(Double(k) * 180)
                    return s
                }
            }
            let ex = [
                SessionExercise(exerciseId: "Barbell_Bench_Press_-_Medium_Grip", targetSets: 4, targetReps: "6",
                                targetRestSeconds: 150, targetWeight: bench, targetWeightUnit: .kg,
                                sets: sets(4, reps: 6, kg: bench, from: start.addingTimeInterval(300))),
                SessionExercise(exerciseId: "Standing_Military_Press", targetSets: 3, targetReps: "8",
                                targetRestSeconds: 120, targetWeight: ohp, targetWeightUnit: .kg,
                                sets: sets(3, reps: 8, kg: ohp, from: start.addingTimeInterval(1_500))),
                SessionExercise(exerciseId: "Pullups", targetSets: 3, targetReps: "8", targetRestSeconds: 90,
                                sets: sets(3, reps: pullReps, kg: nil, from: start.addingTimeInterval(2_400))),
            ]
            let duration = Double(46 + (i % 3) * 4) * 60
            context.insert(WorkoutSession(routineID: pushDayID, routineName: "Push Day", startedAt: start,
                                          completedAt: start.addingTimeInterval(duration), exercises: ex,
                                          hrSeries: StudioDemoSeed.syntheticHRSeries(durationSec: duration, sampleEverySec: 5),
                                          kcalEstimate: 310 + Double(i) * 6))
        }

        // Finger day: Max hangs with rising added load, force reps per rep.
        var maxHangs = TimedExerciseSpec.maxHangs
        let finger = Routine(id: fingerDayID, name: "Finger day", exercises: [
            RoutineExercise(exerciseId: "timed.seed:maxhangs", sets: 1, reps: "", restSeconds: 0,
                            displayName: "Max hangs", discipline: .timed,
                            timedSpecData: try? JSONEncoder().encode(maxHangs), timedCategory: "hangboard"),
        ], isStarter: false)
        context.insert(finger)
        for (i, ago) in [26, 22, 18, 13, 8, 2].enumerated() {
            let start = daysAgo(ago, hour: 7)
            let added = 5.0 + Double(i) * 1.25
            maxHangs.load = HangLoad(kind: .added, amount: added)
            var log = SetLog(durationSec: 63, loadKg: added)
            log.completedAt = start.addingTimeInterval(1_300)
            log.forceReps = (1...3).flatMap { set in (1...3).map { rep in
                ForceRepRecord(set: set, rep: rep, hand: nil,
                               peakKg: 44 + Double(i) * 0.9 - Double(set - 1) * 0.6,
                               meanKg: 42 + Double(i) * 0.8 - Double(set - 1) * 0.7, holdSec: 7)
            } }
            var ex = SessionExercise(exerciseId: "timed.seed:maxhangs", targetSets: 1, targetReps: "",
                                     targetRestSeconds: 0, sets: [log], displayName: "Max hangs",
                                     kindRaw: SetKind.duration.rawValue)
            ex.disciplineRaw = WorkoutDiscipline.timed.rawValue
            ex.timedSpec = maxHangs
            context.insert(WorkoutSession(routineID: fingerDayID, routineName: "Finger day", startedAt: start,
                                          completedAt: start.addingTimeInterval(22 * 60), exercises: [ex]))
        }

        // Bouldering quick sessions: grades creeping up, latest a first V5 send.
        let grades = [["V2", "V3", "V3"], ["V3", "V3", "V4"], ["V3", "V4", "V4"], ["V4", "V4", "V4"], ["V4", "V5", "V5"]]
        for (i, ago) in [27, 20, 15, 9, 1].enumerated() {
            let start = daysAgo(ago, hour: 19)
            let ex: [SessionExercise] = grades[i].enumerated().map { j, g in
                let sent = !(i < 4 && g == "V4" && j == 2)
                var attempt = SetLog(climbGradeLabel: g, climbStatusRaw: sent ? KilterAscentStatus.sent.rawValue
                                                                              : KilterAscentStatus.attempt.rawValue,
                                     climbAttempts: sent ? 2 : 3)
                attempt.completedAt = start.addingTimeInterval(Double(j) * 600)
                var e = SessionExercise(exerciseId: "climb.boulder", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                        sets: [attempt], displayName: "\(g) boulder", kindRaw: SetKind.climbAttempt.rawValue)
                e.disciplineRaw = WorkoutDiscipline.climb.rawValue
                e.climbGradeLabel = g
                return e
            }
            context.insert(WorkoutSession(routineID: nil, routineName: "Bouldering", startedAt: start,
                                          completedAt: start.addingTimeInterval(80 * 60), exercises: ex))
        }

        // Easy runs: 5 km, getting faster.
        for (i, ago) in [25, 16, 11, 4].enumerated() {
            let start = daysAgo(ago, hour: 6)
            let secs = 1_800 - Double(i) * 45
            var leg = SetLog(durationSec: secs, distanceMeters: 5_000)
            leg.completedAt = start.addingTimeInterval(secs)
            var e = SessionExercise(exerciseId: "run.easy", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                    sets: [leg], displayName: "Easy run", kindRaw: SetKind.duration.rawValue)
            e.disciplineRaw = WorkoutDiscipline.run.rawValue
            context.insert(WorkoutSession(routineID: nil, routineName: "Easy run", startedAt: start,
                                          completedAt: start.addingTimeInterval(secs + 120), exercises: [e],
                                          hrSeries: StudioDemoSeed.syntheticHRSeries(durationSec: secs, sampleEverySec: 5)))
        }
        try? context.save()
    }
}
