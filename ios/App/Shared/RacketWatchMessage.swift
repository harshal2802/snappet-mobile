import Foundation

// MARK: - Racket on the Watch: the phone ↔ Watch wire (prompt 245, issue #438 step 2) — pure, Shared/
//
// The phone is the one place a match or a drill lives. It sends the Watch a snapshot of what to show
// (`RacketWatchState`, with a rising `revision`); the Watch sends back what the player tapped (`RacketWatchCommand`).
// The Watch applies score taps optimistically with the same tally (`RacketLiveScore`) so a tap shows at once, and the
// next snapshot from the phone wins. Like `LiveWorkoutMessage` / `HouseholdWatchMessage`, each message is a
// property-list dictionary; its discriminator key is `racketKind`, so neither relay mistakes it for one of theirs.
// Household owns `updateApplicationContext` (one dictionary per app), so racket messages ride `sendMessage` with a
// `transferUserInfo` fallback, and the revision makes a late, queued snapshot harmless.

/// Why recording stopped, as the Watch says it ("Your Watch tells you it stopped", TtInterrupted / TtInterruptedStop).
enum RacketWatchStopReason: String, Codable, Equatable, Sendable {
    case call, appLeft, cameraBusy, cameraError, storageFull, tooHot, stillPlayingTimeout

    /// The short wrist headline.
    var headline: String {
        switch self {
        case .call: return "A call stopped the recording"
        case .appLeft: return "Snappet left the phone’s screen"
        case .cameraBusy: return "Another app took the camera"
        case .cameraError: return "The camera stopped"
        case .storageFull: return "The phone’s storage is full"
        case .tooHot: return "The phone got too hot"
        case .stillPlayingTimeout: return "No answer to Still playing?"
        }
    }
}

/// A clock the Watch runs on its own between snapshots: `base` seconds as of `asOf`, counting up while `running`.
struct RacketWatchClock: Codable, Equatable, Sendable {
    var base: TimeInterval
    var asOf: Date
    var running: Bool

    func seconds(now: Date) -> TimeInterval { base + (running ? max(0, now.timeIntervalSince(asOf)) : 0) }
}

/// What the Watch shows for one match or drill, sent by the phone.
struct RacketWatchState: Codable, Equatable, Sendable {
    /// The match / drill entity (`SessionExercise.id`). Commands carry it back; a different id is another session.
    var sessionID: UUID
    /// Rises with every snapshot the phone sends. The Watch ignores an older one (a queued `transferUserInfo`).
    var revision: Int
    /// "Table tennis".
    var sport: String
    /// "game" / "set".
    var unitNoun: String
    /// The two sides' button names: "You" / "Alex", "Us" / "Them".
    var sideUs: String
    var sideThem: String
    /// The sport's line under the score ("The rally winner serves next").
    var note: String?
    var surface: Surface
    /// "Still playing?" is asking (the configured threshold, review5 M4).
    var stillPlaying: StillPlaying?
    /// Recording stopped by itself: storage full, too hot, a call, no answer to Still playing?.
    var notice: Notice?

    struct StillPlaying: Codable, Equatable, Sendable {
        var askedAt: Date
        /// The configured threshold, in minutes.
        var minutes: Int
        var answerWindowSec: TimeInterval

        /// "No taps or marks for 60 min".
        var reason: String { "No taps or marks for \(minutes) min" }
        func secondsLeft(now: Date) -> TimeInterval { max(0, answerWindowSec - now.timeIntervalSince(askedAt)) }
        /// "Stops in 2:00".
        func stopsLine(now: Date) -> String { "Stops in \(RacketClock.mmss(secondsLeft(now: now)))" }
    }

    struct Notice: Codable, Equatable, Sendable {
        var reason: RacketWatchStopReason
        /// A call / leaving the app can resume (on the phone); full storage, heat and a timeout can't.
        var canResume: Bool
        /// "Everything up to 31:04 is saved."
        var savedUpToSec: TimeInterval?

        var title: String { canResume ? "Recording paused" : "Recording stopped" }
        var line: String {
            let saved = savedUpToSec.map { "Everything up to \(RacketClock.elapsed($0)) is saved. " } ?? ""
            return saved + (canResume ? "Resume on the phone: it starts a new part." : "Start a new recording on the phone.")
        }
    }

    // MARK: Surfaces (one per board)

    enum Surface: Codable, Equatable, Sendable {
        /// XxWatchStart: "Start block 1?" / "Start game 2?" (Start / Not yet).
        case start(Start)
        /// Watch / XxWatch: game-by-game scoring.
        case scoring(Scoring)
        /// XxWatchMark: a match recording everything (marks + score taps).
        case marks(Marks)
        /// The countdown before a block.
        case countdown(Countdown)
        /// XxWatchBlock.
        case block(Block)
        /// WatchDrill / XxWatchRest.
        case rest(Rest)
        /// WatchBreak / XxWatchBreak: between games of a game-by-game match.
        case matchBreak(Break)
        /// Recording saved / drill done / match over.
        case ended(Ended)
    }

    struct Start: Codable, Equatable, Sendable {
        /// "Start block 1?".
        var title: String
        /// The phone's camera screen is open (a drill waiting on its camera).
        var cameraReady: Bool
        var footnote: String
    }

    struct Scoring: Codable, Equatable, Sendable {
        var unitNumber: Int
        var score: RacketLiveScore
        /// The unit's clock ("● 09:41").
        var clock: RacketWatchClock
        /// "Games 1–0" (the match so far), nil before the first unit ends.
        var matchLine: String?
    }

    struct Marks: Codable, Equatable, Sendable {
        /// Recorded time ("● 1:02:04"); stops while the recording is interrupted.
        var clock: RacketWatchClock
        var unitNumber: Int
        var score: RacketLiveScore
        var matchLine: String?
        var markCount: Int
    }

    struct Countdown: Codable, Equatable, Sendable {
        var block: Int
        var blocks: Int
        var endsAt: Date
        var totalSec: TimeInterval
        /// A game-by-game match's next unit ("Game 2", prompt 249); `nil` ⇒ a drill block.
        var title: String? = nil
    }

    struct Block: Codable, Equatable, Sendable {
        var index: Int
        var blocks: Int
        var startedAt: Date
        var totalSec: TimeInterval
        var recording: Bool
    }

    struct Rest: Codable, Equatable, Sendable {
        /// The block just finished (0-based).
        var after: Int
        var blocks: Int
        /// Running: when it ends. `nil` while paused / done.
        var endsAt: Date?
        /// Paused: what's left.
        var remainingSec: TimeInterval
        var totalSec: TimeInterval
        var paused: Bool
        /// The rest ran out and auto-start is off: the player starts the next block.
        var done: Bool
        var autoStart: Bool

        func secondsLeft(now: Date) -> TimeInterval {
            if done { return 0 }
            if paused { return remainingSec }
            return max(0, (endsAt ?? now).timeIntervalSince(now))
        }
    }

    struct Break: Codable, Equatable, Sendable {
        /// The unit just played (1-based) and its score ("Game 1: 11–9").
        var unitNumber: Int
        var unitScore: String
        var endsAt: Date?
        var remainingSec: TimeInterval
        var totalSec: TimeInterval
        var paused: Bool

        func secondsLeft(now: Date) -> TimeInterval {
            paused ? remainingSec : max(0, (endsAt ?? now).timeIntervalSince(now))
        }
    }

    struct Ended: Codable, Equatable, Sendable {
        var title: String
        var line: String
    }
}

// MARK: - Rings (review5: "Watch timers have no ring")

extension RacketWatchState.Surface {
    /// The ring for a timed surface, on the phone's tones: Work accent, Rest / Break grey, Paused grey 0.55, Done
    /// green. `nil` for the surfaces without a timer.
    func ring(now: Date) -> RacketTimerDisplay? {
        switch self {
        case .countdown(let c):
            let left = max(0, c.endsAt.timeIntervalSince(now))
            return .init(word: "\(c.title ?? "Block \(c.block + 1)") starts", tone: .work, seconds: left,
                         progress: min(1, left / max(1, c.totalSec)))
        case .block(let b):
            let left = max(0, b.totalSec - now.timeIntervalSince(b.startedAt))
            return .init(word: "Block", tone: .work, seconds: left, progress: min(1, left / max(1, b.totalSec)))
        case .rest(let r):
            let left = r.secondsLeft(now: now)
            if r.done { return .init(word: "Rest done", tone: .rest, seconds: 0, progress: 0) }
            return .init(word: r.paused ? "Rest, paused" : "Rest", tone: r.paused ? .restPaused : .rest,
                         seconds: left, progress: min(1, left / max(1, r.totalSec)))
        case .matchBreak(let b):
            let left = b.secondsLeft(now: now)
            return .init(word: b.paused ? "Break, paused" : "Break", tone: b.paused ? .restPaused : .rest,
                         seconds: left, progress: min(1, left / max(1, b.totalSec)))
        case .ended:
            return .init(word: "Done", tone: .done, seconds: 0, progress: 1)
        case .start, .scoring, .marks:
            return nil
        }
    }

    /// A stable name per board, for haptic cues and tests.
    var kind: String {
        switch self {
        case .start: return "start"
        case .scoring: return "scoring"
        case .marks: return "marks"
        case .countdown: return "countdown"
        case .block: return "block"
        case .rest: return "rest"
        case .matchBreak: return "break"
        case .ended: return "ended"
        }
    }
}

// MARK: - Commands (Watch → phone)

enum RacketWatchCommand: String, Codable, CaseIterable, Sendable {
    // XxWatchStart
    case start, notYet
    // Scoring (game by game) and marks (everything)
    case pointUs, pointThem, undo
    /// "End game" / "End set".
    case endUnit
    /// "Hold to end match".
    case endMatch
    // XxWatchMark
    case mark, newUnit, breakStarts, stopAndSplit
    // XxWatchBlock
    case endBlock, stopDrill
    // Rest / break timers
    case pauseTimer, resumeTimer, add30, add60, skip, finishDrill
    // Still playing?
    case keepPlaying, stopRecording
}

struct RacketWatchCommandEnvelope: Codable, Equatable, Sendable {
    /// Unique per tap, so a re-sent copy (sendMessage failed → transferUserInfo) applies once.
    var id: UUID
    var sessionID: UUID
    var command: RacketWatchCommand
    var at: Date

    init(id: UUID = UUID(), sessionID: UUID, command: RacketWatchCommand, at: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.command = command
        self.at = at
    }
}

// MARK: - The message

enum RacketWatchMessage: Equatable, Sendable {
    /// Phone → Watch: what to show.
    case state(RacketWatchState)
    /// Watch → phone: a tap.
    case command(RacketWatchCommandEnvelope)
    /// Phone → Watch: the match / drill left the phone's screen; the Watch goes back to its usual face.
    case clear(sessionID: UUID)

    static let kindKey = "racketKind"
    private static let dataKey = "data"
    private static let sessionKey = "session"

    var payload: [String: Any] {
        switch self {
        case .state(let s):
            return [Self.kindKey: "state", Self.dataKey: Self.encode(s) ?? Data()]
        case .command(let c):
            return [Self.kindKey: "command", Self.dataKey: Self.encode(c) ?? Data()]
        case .clear(let id):
            return [Self.kindKey: "clear", Self.sessionKey: id.uuidString]
        }
    }

    /// Decode a received payload, or `nil` if it isn't a racket message (or is malformed).
    init?(payload: [String: Any]) {
        switch payload[Self.kindKey] as? String {
        case "state":
            guard let data = payload[Self.dataKey] as? Data,
                  let s = try? Self.decoder.decode(RacketWatchState.self, from: data) else { return nil }
            self = .state(s)
        case "command":
            guard let data = payload[Self.dataKey] as? Data,
                  let c = try? Self.decoder.decode(RacketWatchCommandEnvelope.self, from: data) else { return nil }
            self = .command(c)
        case "clear":
            guard let id = (payload[Self.sessionKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            self = .clear(sessionID: id)
        default:
            return nil
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return try? e.encode(value)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}

// MARK: - Watch-side rules (pure, so they're tested on the phone's test target)

extension RacketWatchState {
    /// Whether `incoming` should replace `current` on the Watch: a newer revision, or another session.
    static func accepts(_ incoming: RacketWatchState, over current: RacketWatchState?) -> Bool {
        guard let current else { return true }
        return incoming.sessionID != current.sessionID || incoming.revision > current.revision
    }

    /// The Watch shows a score tap at once (the phone's next snapshot wins). Only score taps and "Keep" apply locally;
    /// everything else waits for the phone. `nil` ⇒ nothing to show yet.
    func applyingOptimistically(_ command: RacketWatchCommand) -> RacketWatchState? {
        var s = self
        switch command {
        case .pointUs, .pointThem, .undo:
            func apply(_ score: inout RacketLiveScore) -> Bool {
                switch command {
                case .pointUs: return score.point(.us)
                case .pointThem: return score.point(.them)
                default: return score.undo()
                }
            }
            switch s.surface {
            case .scoring(var sc):
                guard apply(&sc.score) else { return nil }
                s.surface = .scoring(sc)
            case .marks(var m):
                guard apply(&m.score) else { return nil }
                s.surface = .marks(m)
            default:
                return nil
            }
            // Any tap answers Still playing? on the phone (it counts as activity).
            s.stillPlaying = nil
            return s
        case .keepPlaying:
            guard s.stillPlaying != nil else { return nil }
            s.stillPlaying = nil
            return s
        default:
            return nil
        }
    }
}

/// The haptic the Watch plays when the phone's state changes ("Your Watch taps you before it starts").
enum RacketWatchCue: Equatable, Sendable {
    /// A block, a countdown or a game starts.
    case start
    /// A rest or break begins.
    case phase
    /// Still playing? is asking.
    case ask
    /// Recording stopped by itself.
    case stopped
    /// The drill / recording is done.
    case done

    static func between(_ old: RacketWatchState?, _ new: RacketWatchState?) -> RacketWatchCue? {
        guard let new else { return nil }
        if new.notice != nil && old?.notice == nil { return .stopped }
        if new.stillPlaying != nil && old?.stillPlaying == nil { return .ask }
        let was = old?.sessionID == new.sessionID ? old?.surface.kind : nil
        let now = new.surface.kind
        guard was != now else {
            // Same board, a new block / game: still a start.
            if case .block(let b) = new.surface, case .block(let a)? = old?.surface, a.index != b.index { return .start }
            if case .scoring(let b) = new.surface, case .scoring(let a)? = old?.surface, a.unitNumber != b.unitNumber {
                return .start
            }
            return nil
        }
        switch now {
        case "countdown", "block", "scoring": return .start
        case "rest", "break": return .phase
        case "ended": return .done
        default: return nil
        }
    }
}
