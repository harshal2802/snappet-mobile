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

    /// With the seed (prompt 253, the Watch-mode player): `-uiTestRacketPlayer portrait|landscape|missing|opening`.
    /// The match was filmed game by game: game 1 (5:00) has 21 rallies (rally 13 untagged, 7 – 5 after rally 12, 11 – 9 at the end, as
    /// the boards) and game 2 (1:00) none. `portrait` / `landscape` lay a synthetic bundled clip (a drawn table and a
    /// moving ball, no real footage) end to end over both games; `missing` points at a video that isn't in Photos;
    /// `opening` holds the player on its iCloud download state.
    static let playerArgument = "-uiTestRacketPlayer"
    /// Game 1's winners in the player seed: u = you, t = them, - = untagged.
    static let playerWinners = "uututtutuutu-uttuttuu"

    static func playerLog(startedAt: Date, variant: String) -> RacketRecordingLog {
        var log = RacketRecordingLog(startedAt: startedAt)
        log.baseSetIndex = 0
        log.modeRaw = RacketRecordingMode.byUnit.rawValue
        log.qualityRaw = RacketRecordingQuality.hd1080.rawValue
        log.runs = [.init(startSec: 0, endSec: 300, endReasonRaw: nil), .init(startSec: 330, endSec: 390, endReasonRaw: nil)]
        log.marks = [.init(kindRaw: RacketRecordingLog.MarkKind.game.rawValue, index: 0, startSec: 0, endSec: 300),
                     .init(kindRaw: RacketRecordingLog.MarkKind.game.rawValue, index: 1, startSec: 330, endSec: 390)]
        log.rallies = playerWinners.enumerated().map { k, c in
            let t = 8 + Double(k) * 14
            return RacketRally(startSec: t, endSec: t + 4 + Double((k * 7) % 5) + 0.2,
                               winner: c == "u" ? .us : c == "t" ? .them : nil)
        }
        let clip: String
        switch variant {
        case "landscape": clip = RecapClipSeed.bundledScheme + "racket-uitest-landscape.mov"
        case "missing": clip = "uitest-missing-video/L0/001"
        default: clip = RecapClipSeed.bundledScheme + "racket-uitest-portrait.mov"
        }
        if variant == "missing" {
            log.assets = [.init(localIdentifier: clip, startSec: 0, durationSec: 300), .init(localIdentifier: clip, startSec: 330, durationSec: 60)]
        } else {
            log.assets = (stride(from: 0.0, to: 300, by: 6).map { $0 } + stride(from: 330.0, to: 390, by: 6).map { $0 })
                .map { .init(localIdentifier: clip, startSec: $0, durationSec: 6) }
        }
        log.endedAt = startedAt.addingTimeInterval(390)
        log.split = RacketGameByGameSplit.split(log, now: startedAt.addingTimeInterval(390))
        return log
    }

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

    /// With the seed (prompt 258, the user's real match): the match was split and saved some time ago — warmup,
    /// Games 1–3, a break, Game 4, a 3:10 break that was really a timeout, Game 5, Game 6, not play. Games 4 and 5 have
    /// no score yet; with `-uiTestRacketSplitTimeoutScored` they are 6–5 and 5–3.
    static let splitTimeoutArgument = "-uiTestRacketSplitTimeout"
    static let splitTimeoutScoredArgument = "-uiTestRacketSplitTimeoutScored"

    /// The saved split's parts (kind, start, end), seconds on the recording.
    static let timeoutMatchParts: [(RacketPartKind, Double, Double)] = [
        (.warmup, 0, 300), (.game, 300, 900), (.game, 900, 1500), (.game, 1500, 2100), (.breakTime, 2100, 2220),
        (.game, 2220, 2700), (.breakTime, 2700, 2890), (.game, 2890, 3300), (.game, 3300, 3900), (.notPlay, 3900, 4000),
    ]

    /// The match as saved: the log (split applied, each game linked to its logged game) and its six games. Rallies:
    /// three in Game 4 (you, you, them), one hit during the timeout, two in Game 5 (them, you).
    static func splitTimeoutMatch(startedAt: Date, scored: Bool) -> (log: RacketRecordingLog, sets: [SetLog]) {
        var log = RacketRecordingLog(startedAt: startedAt)
        log.baseSetIndex = 0
        log.qualityRaw = RacketRecordingQuality.hd1080.rawValue
        log.runs = [.init(startSec: 0, endSec: 4000, endReasonRaw: nil)]
        log.endedAt = startedAt.addingTimeInterval(4000)
        var parts: [RacketVideoPart] = []
        var sets: [SetLog] = []
        let scores: [(Int, Int)?] = [(11, 7), (9, 11), (11, 8), scored ? (6, 5) : nil, scored ? (5, 3) : nil, nil]
        for (kind, a, b) in timeoutMatchParts {
            var p = RacketVideoPart(kind: kind, startSec: a, endSec: b)
            if kind == .game {
                p.setIndex = sets.count
                var g = SetLog(completedAt: startedAt.addingTimeInterval(b), durationSec: b - a)
                if let sc = scores[sets.count] { g.scoreFor = sc.0; g.scoreAgainst = sc.1 } else { g.scoreUnconfirmed = true }
                sets.append(g)
            }
            parts.append(p)
        }
        log.split = RacketSplit(parts: parts, appliedAt: startedAt.addingTimeInterval(4100))
        log.rallies = [RacketRally(startSec: 2300, endSec: 2308, winner: .us), RacketRally(startSec: 2400, endSec: 2410, winner: .us),
                       RacketRally(startSec: 2500, endSec: 2506, winner: .them), RacketRally(startSec: 2750, endSec: 2755),
                       RacketRally(startSec: 2950, endSec: 2957, winner: .them), RacketRally(startSec: 3050, endSec: 3060, winner: .us)]
        return (log, sets)
    }

    /// With the seed (prompt 260, the user's real case): a stray 9–11 logged by mistake five minutes before the
    /// recording (6.4 s, no video), then the recording's three games, 9–11 each, split and saved (`baseSetIndex` 1,
    /// links 1, 2, 3, then a short not-play part), rallies tagged in each game. The last game was logged from the stop
    /// sheet: its length is still the whole recording (792 s) though its video is 211 s. Best of 5: the recap reads
    /// "L 0–4"; the truth is three games, 0–3. A second match ("vs Sam", game by game, one game) has a recording too.
    static let editMatchArgument = "-uiTestRacketEditMatch"

    /// The real case's parts (kind, start, end) and its recording's length.
    static let strayParts: [(RacketPartKind, Double, Double)] = [(.game, 0, 270), (.game, 270, 540), (.game, 540, 751), (.notPlay, 751, 792)]
    static let strayRecordingSec: Double = 792

    static func strayGameMatch(recordingStart: Date) -> (log: RacketRecordingLog, sets: [SetLog]) {
        var log = RacketRecordingLog(startedAt: recordingStart)
        log.baseSetIndex = 1
        log.qualityRaw = RacketRecordingQuality.hd1080.rawValue
        log.runs = [.init(startSec: 0, endSec: strayRecordingSec, endReasonRaw: nil)]
        log.endedAt = recordingStart.addingTimeInterval(strayRecordingSec)
        func game(_ end: Date, _ duration: Double) -> SetLog {
            var g = SetLog(completedAt: end, durationSec: duration)
            g.scoreFor = 9; g.scoreAgainst = 11
            return g
        }
        var sets = [game(recordingStart.addingTimeInterval(-300), 6.4)]
        var parts: [RacketVideoPart] = []
        var rallies: [RacketRally] = []
        for (kind, a, b) in strayParts {
            var p = RacketVideoPart(kind: kind, startSec: a, endSec: b)
            if kind == .game {
                p.setIndex = sets.count
                // The stop-sheet game (the last) carries the whole recording.
                let last = b == 751
                sets.append(game(recordingStart.addingTimeInterval(last ? strayRecordingSec : b), last ? strayRecordingSec : b - a))
                for (k, w) in [RacketRallyWinner.us, .them, .them].enumerated() {
                    let t = a + 30 + Double(k) * 60
                    rallies.append(RacketRally(startSec: t, endSec: t + 8, winner: w))
                }
            }
            parts.append(p)
        }
        log.split = RacketSplit(parts: parts, appliedAt: recordingStart.addingTimeInterval(strayRecordingSec + 60))
        log.rallies = rallies
        return (log, sets)
    }

    /// With the seed (prompt 262): `-uiTestRacketMixedSession strength|timed` — the session holds the recorded match
    /// and, instead of the drill, two lifts × 3 sets (`strength`: strength dominant, workout type strength) or two
    /// planks × 3 holds (`timed`: timed dominant, workout type timed), plus a synthetic heart-rate series.
    static let mixedSessionArgument = "-uiTestRacketMixedSession"

    static func mixedExtras(variant: String, start: Date) -> [SessionExercise] {
        func entity(_ id: String, _ name: String, _ d: WorkoutDiscipline, at base: Double) -> SessionExercise {
            var ex = SessionExercise(exerciseId: id, targetSets: 3, targetReps: d == .strength ? "8" : "",
                                     targetRestSeconds: 90, sets: [], displayName: name,
                                     kindRaw: d.defaultSetKind.rawValue)
            ex.disciplineRaw = d.rawValue
            for k in 0..<3 {
                let at = start.addingTimeInterval(base + Double(k) * 180)
                ex.sets.append(d == .strength
                               ? SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg, completedAt: at)
                               : SetLog(completedAt: at, durationSec: 45))
            }
            return ex
        }
        if variant == "timed" {
            return [entity("timed.uitest:plank", "Plank", .timed, at: 4600),
                    entity("timed.uitest:sideplank", "Side plank", .timed, at: 5200)]
        }
        return [entity("Barbell_Bench_Press_-_Medium_Grip", "Bench press", .strength, at: 4600),
                entity("Pullups", "Pull-ups", .strength, at: 5200)]
    }

    /// With the seed (prompt 263): the session is still running (no `completedAt`), so the live player shows it. Every
    /// other seed argument keeps its meaning.
    static let liveArgument = "-uiTestRacketLive"
    /// With `-uiTestRacketLive` (prompt 263): the app was killed mid-recording. Nothing is logged yet (no exercise has a
    /// set; the drill keeps its finished recording) and the match's record-everything log is still open: one 10-minute
    /// part saved per run, the second run never closed, no `endedAt`. Recovery closes it at 20:00 recorded.
    static let liveCrashArgument = "-uiTestRacketLiveCrash"

    static func crashedLog(startedAt: Date) -> RacketRecordingLog {
        var log = matchLog(startedAt: startedAt)
        log.runs = [.init(startSec: 0, endSec: 600, endReasonRaw: RacketInterruption.appLeft.rawValue),
                    .init(startSec: 600, endSec: nil, endReasonRaw: nil)]
        log.assets = [.init(localIdentifier: "uitest-crash-part-1", startSec: 0, durationSec: 600),
                      .init(localIdentifier: "uitest-crash-part-2", startSec: 600, durationSec: 600)]
        log.endedAt = nil
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
        if let variant = UserDefaults.standard.string(forKey: String(playerArgument.dropFirst())) {
            match.racketRecordingRaw = nil
            match.racketRecordingLog = playerLog(startedAt: start, variant: variant)
            // `-uiTestRacketTurns 1` (prompt 259): the recording already turned with Rotate.
            let turns = UserDefaults.standard.integer(forKey: "uiTestRacketTurns")
            if turns != 0 { match.racketRecordingLog?.quarterTurns = RacketVideoTurn.stored(turns) }
            match.sets = [match.sets[0]]   // game 1 won 11–9 on the Watch; game 2 has no score yet
        } else if ProcessInfo.processInfo.arguments.contains(splitTimeoutArgument) {
            let m = splitTimeoutMatch(startedAt: start, scored: ProcessInfo.processInfo.arguments.contains(splitTimeoutScoredArgument))
            match.racketBestOf = 7
            match.racketRecordingLog = m.log
            match.sets = m.sets
            if ProcessInfo.processInfo.arguments.contains("-uiTestRacketSplitTimeoutJoined"), var log = match.racketRecordingLog,
               let parts = log.split?.parts {
                // Already joined (the player test): the break between Game 4 and Game 5 saved as a timeout.
                let draft = RacketSplitEditor.setKind(parts, id: parts[6].id, kind: .timeout)
                let out = RacketSplitCommit.apply(parts: draft, sets: match.sets, base: 0, startedAt: start,
                                                  duration: log.timelineSec, rallies: log.allRallies)
                log.split = RacketSplit(parts: out.parts, appliedAt: start.addingTimeInterval(4100))
                match.racketRecordingLog = log
                match.sets = out.sets
            }
        } else if ProcessInfo.processInfo.arguments.contains(editMatchArgument) {
            let m = strayGameMatch(recordingStart: start.addingTimeInterval(600))
            match.racketBestOf = 5
            match.racketRecordingLog = m.log
            match.sets = m.sets
        } else if ProcessInfo.processInfo.arguments.contains(taggedGamesArgument) {
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
        if ProcessInfo.processInfo.arguments.contains(editMatchArgument) {
            // A second recorded match: Your videos ids stay unique per match (prompt 260).
            var sam = match
            sam.id = UUID()
            sam.opponent = "Sam"
            sam.racketBestOf = 3
            sam.racketRecordingRaw = nil
            let samStart = start.addingTimeInterval(2000)
            var slog = RacketRecordingLog(startedAt: samStart)
            slog.baseSetIndex = 0
            slog.modeRaw = RacketRecordingMode.byUnit.rawValue
            slog.runs = [.init(startSec: 0, endSec: 120, endReasonRaw: nil)]
            slog.marks = [.init(kindRaw: RacketRecordingLog.MarkKind.game.rawValue, index: 0, startSec: 0, endSec: 120)]
            slog.endedAt = samStart.addingTimeInterval(120)
            slog.split = RacketGameByGameSplit.split(slog, now: samStart.addingTimeInterval(120))
            sam.racketRecordingLog = slog
            var g = SetLog(completedAt: samStart.addingTimeInterval(120), durationSec: 120)
            g.scoreFor = 11; g.scoreAgainst = 5
            sam.sets = [g]
            exercises.insert(sam, at: 1)
        }
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
        let mixed = UserDefaults.standard.string(forKey: String(mixedSessionArgument.dropFirst()))
        if let mixed {
            // Prompt 262: the recorded match (no drill) plus other work that outweighs it, so racket isn't dominant.
            exercises = [match] + mixedExtras(variant: mixed, start: start)
        }
        let live = ProcessInfo.processInfo.arguments.contains(liveArgument)
        if live, ProcessInfo.processInfo.arguments.contains(liveCrashArgument), let i = exercises.firstIndex(where: \.isRacketMatch) {
            // Nothing logged yet anywhere (the recordings are all the session holds), so Finish has to ask.
            for k in exercises.indices { exercises[k].sets = [] }
            exercises[i].racketRecordingRaw = RacketRecordingMode.everything.rawValue
            exercises[i].racketRecordingLog = crashedLog(startedAt: start)
        }
        let session = WorkoutSession(routineID: nil, routineName: "Racket videos", exercises: exercises)
        session.startedAt = start
        session.completedAt = live ? nil : start.addingTimeInterval(5700)
        if mixed != nil {
            // A steady synthetic series, so each game has a heart-rate row on the racket card.
            session.maxHR = 190
            session.hrSeries = stride(from: 0.0, through: 5700, by: 5).map { HRPoint(t: $0, bpm: 130 + ($0.truncatingRemainder(dividingBy: 600)) / 30) }
        }
        context.insert(session)
        try? context.save()
    }
}
