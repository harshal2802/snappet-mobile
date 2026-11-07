import Foundation
import SwiftData

/// Test-only seed for Your videos, the split and manual tagging (prompt 246): `-uiTestSeedRacketVideos` adds one finished
/// session from an hour ago — "Match vs Alex" (table tennis, best of 3) recorded everything for 1:14:10 with the marks the
/// boards show (Watch first points, two games ended on the Watch 11–9 / 9–11 "from Watch", a phone New game, a break at
/// the end), and a drill "Forehand loop vs block" recorded everything (3 × 5:00 blocks, 1:00 rests). No Photos videos
/// (like the simulator's stand-in camera), so the player runs its virtual clock. Launch-arg guarded, fresh in-memory store.
enum RacketVideoSeed {
    static let argument = "-uiTestSeedRacketVideos"

    /// The match recording's marks, as the boards' numbers (TtSplitReview).
    static func matchLog(startedAt: Date) -> RacketRecordingLog {
        var log = RacketRecordingLog(startedAt: startedAt)
        log.baseSetIndex = 0
        log.qualityRaw = RacketRecordingQuality.hd1080.rawValue
        log.runs = [.init(startSec: 0, endSec: 4450, endReasonRaw: nil)]
        func mark(_ k: RacketRecordingLog.MarkKind, _ t: Double) -> RacketRecordingLog.Mark {
            .init(kindRaw: k.rawValue, index: nil, startSec: t, endSec: nil)
        }
        log.marks = [mark(.firstPoint, 385), mark(.newGame, 1480), mark(.firstPoint, 1575), mark(.newGame, 2720),
                     mark(.firstPoint, 2835), mark(.newGame, 3990), mark(.breakStart, 4320)]
        log.endedAt = startedAt.addingTimeInterval(4450)
        return log
    }

    @MainActor
    static func seedIfRequested(into context: ModelContext, now: Date = .now) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let start = now.addingTimeInterval(-3 * 3600)

        var match = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                    targetRestSeconds: 0, sets: [],
                                    displayName: RacketStats.matchActivityName(.tableTennis),
                                    kindRaw: SetKind.duration.rawValue)
        match.disciplineRaw = WorkoutDiscipline.racket.rawValue
        match.racketSportRaw = RacketSport.tableTennis.rawValue
        match.racketModeRaw = RacketMode.match.rawValue
        match.opponent = "Alex"
        match.racketBestOf = 3
        match.racketRecordingRaw = RacketRecordingMode.everything.rawValue
        for (end, mine, theirs) in [(1482.0, 11, 9), (2722.0, 9, 11)] {
            var g = SetLog(completedAt: start.addingTimeInterval(end))
            g.scoreFor = mine; g.scoreAgainst = theirs; g.scoreFromWatch = true
            match.sets.append(g)
        }
        match.racketRecordingLog = matchLog(startedAt: start)

        let drillStart = start.addingTimeInterval(4600)
        var drill = SessionExercise(exerciseId: RacketStats.drillExerciseId(.tableTennis), targetSets: 3, targetReps: "",
                                    targetRestSeconds: 60, sets: [], displayName: "Forehand loop vs block",
                                    kindRaw: SetKind.duration.rawValue)
        drill.disciplineRaw = WorkoutDiscipline.racket.rawValue
        drill.racketSportRaw = RacketSport.tableTennis.rawValue
        drill.racketModeRaw = RacketMode.drill.rawValue
        drill.racketRecordingRaw = RacketRecordingMode.everything.rawValue
        drill.plannedSets = 3
        drill.drillBlockSec = 300
        var dlog = RacketRecordingLog(startedAt: drillStart)
        dlog.baseSetIndex = 0
        dlog.runs = [.init(startSec: 0, endSec: 1030, endReasonRaw: nil)]
        for b in 0..<3 {
            let s = 10 + Double(b) * 360
            dlog.marks.append(.init(kindRaw: "block", index: b, startSec: s, endSec: s + 300))
            if b < 2 { dlog.marks.append(.init(kindRaw: "rest", index: b, startSec: s + 300, endSec: s + 360)) }
            drill.sets.append(SetLog(completedAt: drillStart.addingTimeInterval(s + 300), durationSec: 300))
        }
        dlog.endedAt = drillStart.addingTimeInterval(1030)
        drill.racketRecordingLog = dlog

        let session = WorkoutSession(routineID: nil, routineName: "Racket videos", exercises: [match, drill])
        session.startedAt = start
        session.completedAt = start.addingTimeInterval(5700)
        context.insert(session)
        try? context.save()
    }
}
