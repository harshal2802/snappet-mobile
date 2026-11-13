import Foundation
import SwiftData

/// Test-only seed for Your videos, the split and manual tagging (prompt 246): `-uiTestSeedRacketVideos` adds one finished
/// session from an hour ago — "Match vs Alex" (table tennis, best of 3) recorded everything for 1:14:10 with the marks the
/// boards show (Watch first points, two games ended on the Watch 11–9 / 9–11 "from Watch", a phone New game, a break at
/// the end), and a drill "Forehand loop vs block" recorded everything (3 × 5:00 blocks, 1:00 rests). No Photos videos
/// (like the simulator's stand-in camera), so the player runs its virtual clock. Launch-arg guarded, fresh in-memory store.
enum RacketVideoSeed {
    static let argument = "-uiTestSeedRacketVideos"
    /// With the seed: the drill's first minute plays the bundled clip (prompt 251).
    static let bundledVideoArgument = "-uiTestRacketBundledVideo"
    /// With the seed (prompt 252): the match was filmed game by game (already split per game) and game 1 has Snappet's
    /// rallies, the first eight tagged by you, so the tag sheet shows each sport's score line ("Games 2–0 · Point 0–0",
    /// "4–2–1 · Mia serving next") and its detail link. Pickleball is scored side-out; doubles say who serves first for
    /// you (your partner).
    static let taggedGamesArgument = "-uiTestRacketTaggedGames"

    /// Game 1's tagged winners (u = you / us) and one untagged rally after them.
    static let taggedWinners = "uuuuttuu"

    /// The match as game by game: one game mark per game, the split applied, Snappet's rallies in game 1.
    static func taggedGameLog(startedAt: Date) -> RacketRecordingLog {
        var log = RacketRecordingLog(startedAt: startedAt)
        log.baseSetIndex = 0
        log.modeRaw = RacketRecordingMode.byUnit.rawValue
        log.qualityRaw = RacketRecordingQuality.hd1080.rawValue
        log.runs = [.init(startSec: 0, endSec: 1480, endReasonRaw: nil), .init(startSec: 1575, endSec: 2720, endReasonRaw: nil)]
        log.marks = [.init(kindRaw: RacketRecordingLog.MarkKind.game.rawValue, index: 0, startSec: 0, endSec: 1480),
                     .init(kindRaw: RacketRecordingLog.MarkKind.game.rawValue, index: 1, startSec: 1575, endSec: 2720)]
        var rallies: [RacketRally] = []
        for (k, c) in (taggedWinners + "-").enumerated() {
            let t = 400 + Double(k) * 30
            var r = RacketRally(startSec: t, endSec: t + 8, winner: c == "u" ? .us : c == "t" ? .them : nil)
            r.sourceRaw = RacketModelSource.raw(id: "placeholder", version: 1)
            r.confidence = 0.9
            r.confirmed = c == "-" ? nil : true
            rallies.append(r)
        }
        log.rallies = rallies
        log.endedAt = startedAt.addingTimeInterval(2720)
        log.split = RacketGameByGameSplit.split(log, now: startedAt.addingTimeInterval(2720))
        return log
    }

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
        // Prompt 251's per-sport board walks: `-uiTestRacketSport tennis`, `-uiTestRacketDoubles YES`.
        let sport = UserDefaults.standard.string(forKey: "uiTestRacketSport").flatMap(RacketSport.init(rawValue:)) ?? .tableTennis
        let doubles = UserDefaults.standard.bool(forKey: "uiTestRacketDoubles")

        var match = SessionExercise(exerciseId: RacketStats.matchExerciseId(sport), targetSets: 0, targetReps: "",
                                    targetRestSeconds: 0, sets: [],
                                    displayName: RacketStats.matchActivityName(sport),
                                    kindRaw: SetKind.duration.rawValue)
        match.disciplineRaw = WorkoutDiscipline.racket.rawValue
        match.racketSportRaw = sport.rawValue
        match.racketModeRaw = RacketMode.match.rawValue
        match.opponent = "Alex"
        if doubles {
            match.partner = "Mia"
            match.racketOpponentPlayer1 = "Jordan"
            match.racketOpponentPlayer2 = "Lee"
            match.opponent = "Jordan & Lee"
            match.racketFirstServerRaw = "us"
        }
        match.racketBestOf = 3
        match.racketRecordingRaw = RacketRecordingMode.everything.rawValue
        for (end, mine, theirs) in [(1482.0, 11, 9), (2722.0, 9, 11)] {
            var g = SetLog(completedAt: start.addingTimeInterval(end))
            g.scoreFor = mine; g.scoreAgainst = theirs; g.scoreFromWatch = true
            match.sets.append(g)
        }
        match.racketRecordingLog = matchLog(startedAt: start)
        if ProcessInfo.processInfo.arguments.contains(taggedGamesArgument) {
            match.racketRecordingRaw = nil
            match.racketRecordingLog = taggedGameLog(startedAt: start)
            // Tennis / padel: they served the first game, so rally 9 (game 2) is yours.
            match.racketFirstServerRaw = sport.usesSets ? "them" : "us"
            if sport == .pickleball { match.racketSideOut = true }
            if doubles { match.racketOurFirstServerRaw = RacketDoublesServe.Player.partner.rawValue }
        }

        let drillStart = start.addingTimeInterval(4600)
        var drill = SessionExercise(exerciseId: RacketStats.drillExerciseId(sport), targetSets: 3, targetReps: "",
                                    targetRestSeconds: 60, sets: [], displayName: "Forehand loop vs block",
                                    kindRaw: SetKind.duration.rawValue)
        drill.disciplineRaw = WorkoutDiscipline.racket.rawValue
        drill.racketSportRaw = sport.rawValue
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
        if ProcessInfo.processInfo.arguments.contains(bundledVideoArgument) {
            // Prompt 251: real frames on the simulator — the bundled 3 s clip laid end to end over the first minute,
            // so block 1's rallies play video on the tag sheet, Fix and Shots.
            let id = RecapClipSeed.bundledScheme + RecapClipSeed.bundledClipResource + ".mov"
            dlog.assets = stride(from: 0.0, to: 60, by: 3).map { .init(localIdentifier: id, startSec: $0, durationSec: 3) }
        }
        drill.racketRecordingLog = dlog

        var exercises = [match, drill]
        if ProcessInfo.processInfo.arguments.contains("-uiTestPickPhotosVideo") {
            // SplitPhotos: a match with no recording yet, for a video added from Photos.
            var sam = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                      targetRestSeconds: 0, sets: [], displayName: RacketStats.matchActivityName(.tableTennis),
                                      kindRaw: SetKind.duration.rawValue)
            sam.disciplineRaw = WorkoutDiscipline.racket.rawValue
            sam.racketSportRaw = RacketSport.tableTennis.rawValue
            sam.racketModeRaw = RacketMode.match.rawValue
            sam.opponent = "Sam"
            sam.racketBestOf = 3
            exercises.insert(sam, at: 0)
        }
        let session = WorkoutSession(routineID: nil, routineName: "Racket videos", exercises: exercises)
        session.startedAt = start
        session.completedAt = start.addingTimeInterval(5700)
        context.insert(session)
        try? context.save()
    }
}
