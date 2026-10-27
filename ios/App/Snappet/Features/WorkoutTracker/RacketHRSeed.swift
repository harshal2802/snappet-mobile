import Foundation
import SwiftData

/// Test-only seed for the game heart-rate sheet + HRV (2026-10-26): `-uiTestSeedRacketHR` adds one finished
/// "City Open" session from yesterday — a best-of-5 table tennis match vs Alex Chen, three games, with a full
/// chest-strap series (1 Hz bpm + beat-to-beat RR), so the sheet, the per-game HRV and the session HRV render in
/// the simulator. Strictly launch-arg guarded, fresh in-memory store — zero production impact.
enum RacketHRSeed {
    static let argument = "-uiTestSeedRacketHR"

    @MainActor
    static func seedIfRequested(into context: ModelContext, now: Date = .now) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let start = now.addingTimeInterval(-86_400)
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: [],
                                 displayName: RacketStats.matchActivityName(.tableTennis),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        ex.opponent = "Alex Chen"
        ex.racketEvent = "City Open"
        ex.racketRound = "R16"
        for (end, mine, theirs) in [(300.0, 11, 7), (600.0, 9, 11), (900.0, 11, 8)] {
            var g = SetLog(completedAt: start.addingTimeInterval(end))
            g.scoreFor = mine; g.scoreAgainst = theirs
            ex.sets.append(g)
        }
        let session = WorkoutSession(routineID: nil, routineName: "City Open", exercises: [ex])
        session.startedAt = start
        session.completedAt = start.addingTimeInterval(920)
        session.metricsSourceRaw = MetricsSourceKind.ble.rawValue
        session.maxHR = 190
        session.restHR = 55
        // Rising effort through each game; HRV falls as the match goes on (alternating RR → RMSSD = the gap).
        session.hrSeries = stride(from: 0.0, through: 920, by: 1).map { t in
            let game = min(2, Int(t / 300)), into = t.truncatingRemainder(dividingBy: 300)
            let bpm = 140 + Double(game) * 8 + into / 300 * 25
            let gap = [36.0, 24, 14][game]
            return HRPoint(t: t, bpm: bpm, rrIntervalsMs: [60_000 / bpm, 60_000 / bpm + gap])
        }
        context.insert(session)
        try? context.save()
    }
}
