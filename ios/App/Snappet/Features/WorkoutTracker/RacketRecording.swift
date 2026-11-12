import Foundation

// MARK: - Racket recording core (prompt 244, issue #438 step 1) — pure
//
// How a match or a drill is filmed, and the state machine behind "record everything": the mode chosen per match /
// drill (never per session), the Settings defaults, the storage estimate, the drill's countdown → block → rest
// timers, interruptions and the "Still playing?" check. No AVFoundation / Photos / UIKit / SwiftUI here: the
// capture edge is `Services/RacketRecorder.swift`, the screens are `RacketRecordingViews.swift`. Everything below
// runs in `SnappetTests` with no device (`RacketRecordingTests`).

// MARK: - Mode

/// How one match or drill is filmed. Chosen in the setup sheet (and defaulted from Settings → Recording defaults);
/// the session hub has no recording choice (#438 product decision).
enum RacketRecordingMode: String, Codable, CaseIterable, Sendable {
    /// Each game / block is its own video (prompt 203's "Record = film the game"). Nothing records between them.
    case byUnit
    /// One long recording. A match is split into games afterwards (step 3); a drill's blocks and rests are marked
    /// from its timers as time ranges on the one recording, so there is nothing to split.
    case everything
    /// Nothing is filmed: score / counts only.
    case off

    /// The choice's label. Drills never say "split later" (review5 M1): their blocks are marked from the timers.
    func label(for mode: RacketMode, unit: RacketUnit = .game) -> String {
        switch (self, mode) {
        case (.byUnit, .match): return unit == .set ? "Set by set" : "Game by game"
        case (.byUnit, .drill): return "Block by block"
        case (.everything, .match): return "Everything, split later"
        case (.everything, .drill): return "Everything, rests included"
        case (.off, _): return "Don’t film"
        }
    }

    /// The one-line helper under the choice.
    func helper(for mode: RacketMode, unit: RacketUnit = .game) -> String {
        switch (self, mode) {
        case (.byUnit, .match):
            return "Each \(unit.noun) is its own video. Nothing records between \(unit.noun)s."
        case (.byUnit, .drill):
            return "Each block is its own video. Recording pauses during rest."
        case (.everything, .match):
            return "One recording, warmup and breaks included. You split it into \(unit.noun)s afterwards. Checks space first."
        case (.everything, .drill):
            return "One recording, rests included. Blocks and rests are marked from your timers, so there’s nothing to split by hand. Checks space first."
        case (.off, .match):
            return "Score only. Nothing is filmed."
        case (.off, .drill):
            return "Timers and counts only. Nothing is filmed."
        }
    }
}

extension SessionExercise {
    /// This match's / drill's recording mode; `nil` ⇒ `.byUnit` (every match before prompt 244 filmed game by game).
    var racketRecording: RacketRecordingMode {
        racketRecordingRaw.flatMap(RacketRecordingMode.init(rawValue:)) ?? .byUnit
    }
}

// MARK: - Quality, capture config + storage

enum RacketRecordingQuality: String, Codable, CaseIterable, Sendable {
    case uhd4k, hd1080

    var label: String { self == .uhd4k ? "4K" : "1080p" }
}

enum RacketVideoCodec: String, Codable, Sendable {
    case hevc, h264
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}

/// What the camera will actually write: resolution, frame rate and codec. The recorder reports the codec it
/// configured (HEVC on every iOS 18 device; H.264 only where HEVC isn't offered).
struct RacketCaptureConfig: Equatable, Sendable {
    var quality: RacketRecordingQuality
    var fps: Int = 30
    var codec: RacketVideoCodec = .hevc
}

/// The best up-front estimate of how fast a recording fills the phone, from its capture config. Rates are Apple's
/// published per-minute sizes for the Camera app's formats (Settings → Camera → Record Video), which use the same
/// encoders as `AVCaptureMovieFileOutput`, plus AAC audio. Once recording, `RacketWriteRateMeter` replaces this with
/// the measured rate.
enum RacketBitrate {
    /// Video megabytes per minute at 30 fps, by quality and codec.
    private static func videoMBPerMin30(_ q: RacketRecordingQuality, _ c: RacketVideoCodec) -> Double {
        switch (q, c) {
        case (.hd1080, .hevc): return 60
        case (.hd1080, .h264): return 130
        case (.uhd4k, .hevc): return 170
        case (.uhd4k, .h264): return 350
        }
    }

    /// Video megabytes per minute at 60 fps (not double: the encoder reuses more between frames).
    private static func videoMBPerMin60(_ q: RacketRecordingQuality, _ c: RacketVideoCodec) -> Double {
        switch (q, c) {
        case (.hd1080, .hevc): return 90
        case (.hd1080, .h264): return 200
        case (.uhd4k, .hevc): return 400
        case (.uhd4k, .h264): return 400
        }
    }

    /// AAC stereo audio, about 1 MB a minute.
    static let audioMBPerMin: Double = 1

    /// Bytes per second for `config`; other frame rates interpolate between 30 and 60 (and scale outside it).
    static func bytesPerSecond(_ config: RacketCaptureConfig) -> Double {
        let r30 = videoMBPerMin30(config.quality, config.codec)
        let r60 = videoMBPerMin60(config.quality, config.codec)
        let fps = Double(max(1, config.fps))
        let video: Double
        if fps <= 30 { video = r30 * fps / 30 }
        else if fps <= 60 { video = r30 + (r60 - r30) * (fps - 30) / 30 }
        else { video = r60 * fps / 60 }
        return (video + audioMBPerMin) * 1e6 / 60
    }
}

/// The measured write rate while recording: an exponentially smoothed bytes-per-second from (time, total bytes
/// written) samples, so "space left" follows what the encoder actually produces (a busy scene writes more than an
/// empty court). Pure; the recorder supplies the samples.
struct RacketWriteRateMeter: Equatable, Sendable {
    /// How much each new interval moves the estimate (0…1).
    var smoothing: Double
    /// The measured rate isn't trusted until this much recording has been sampled.
    var warmUpSec: TimeInterval
    private(set) var rate: Double?
    private(set) var measuredSec: TimeInterval = 0
    private var lastAt: Date?
    private var lastBytes: Int64 = 0

    init(smoothing: Double = 0.3, warmUpSec: TimeInterval = 20) {
        self.smoothing = smoothing
        self.warmUpSec = warmUpSec
    }

    /// Feed a sample. A drop in total bytes or an interval under a second is skipped (the next one measures).
    mutating func sample(at now: Date, totalBytes: Int64) {
        defer { lastAt = now; lastBytes = totalBytes }
        guard let lastAt else { return }
        let dt = now.timeIntervalSince(lastAt)
        let db = totalBytes - lastBytes
        guard dt >= 1, db >= 0 else { return }
        let r = Double(db) / dt
        rate = rate.map { $0 + smoothing * (r - $0) } ?? r
        measuredSec += dt
    }

    /// Recording paused / interrupted: forget the last sample, keep the learned rate.
    mutating func pause() { lastAt = nil }

    var isMeasured: Bool { (rate ?? 0) > 0 && measuredSec >= warmUpSec }

    /// The rate to plan with: measured once warmed up, else the config estimate.
    func effectiveRate(estimate: Double) -> Double { isMeasured ? rate! : estimate }
}

/// The storage check before recording everything (`TtStorage`), and "space left" while recording.
enum RacketStorageCheck {
    /// A modest margin iOS keeps for itself: 500 MB or 2 % of free space, whichever is more.
    static func marginBytes(freeBytes: Int64) -> Double { max(5e8, Double(freeBytes) * 0.02) }
    /// Below this, Continue is disabled (red).
    static let minimumSec: TimeInterval = 15 * 60
    /// Below this, the room line is amber.
    static let comfortableSec: TimeInterval = 2 * 3600
    /// Each Photos video part is at most this long, so a crash or full storage loses minutes, not the recording.
    static let partSec: TimeInterval = 10 * 60

    enum Verdict: Equatable, Sendable { case plenty, tight, notEnough }

    /// Seconds of video that fit in `freeBytes` at `bytesPerSec`, after the margin.
    static func roomSec(freeBytes: Int64, bytesPerSec: Double) -> TimeInterval {
        let usable = max(0, Double(freeBytes) - marginBytes(freeBytes: freeBytes))
        return bytesPerSec > 0 ? usable / bytesPerSec : 0
    }

    static func roomSec(freeBytes: Int64, config: RacketCaptureConfig) -> TimeInterval {
        roomSec(freeBytes: freeBytes, bytesPerSec: RacketBitrate.bytesPerSecond(config))
    }

    static func verdict(freeBytes: Int64, config: RacketCaptureConfig) -> Verdict {
        let room = roomSec(freeBytes: freeBytes, config: config)
        if room < minimumSec { return .notEnough }
        if room < comfortableSec { return .tight }
        return .plenty
    }

    /// "Room for about 9 h at 1080p".
    static func roomLine(freeBytes: Int64, config: RacketCaptureConfig) -> String {
        let room = roomSec(freeBytes: freeBytes, config: config)
        if room < minimumSec { return "Not enough room to record everything at \(config.quality.label)" }
        return "Room for about \(roughDuration(room)) at \(config.quality.label)"
    }

    /// "5 h", "1 h 50 min", "40 min" — rounded down to 10 min above an hour, 5 min below.
    static func roughDuration(_ sec: TimeInterval) -> String {
        let minutes = Int(max(0, sec) / 60)
        if minutes >= 60 {
            let h = minutes / 60
            let m = (minutes % 60) / 10 * 10
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        return "\(max(0, minutes / 5 * 5)) min"
    }

    /// "41 GB".
    static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        return gb >= 10 ? "\(Int(gb.rounded(.down))) GB" : String(format: "%.1f GB", gb)
    }
}

// MARK: - Settings → Recording defaults

/// Settings → Workout → Racket recording. Applies to all racket sports; any match or drill can still change it.
/// Stored as one JSON blob under `storageKey`; decoding tolerates missing keys so adding a field never resets it.
struct RacketRecordingDefaults: Codable, Equatable, Sendable {
    static let storageKey = "racket.recordingDefaults"

    var matchMode: RacketRecordingMode = .byUnit
    var drillMode: RacketRecordingMode = .byUnit
    var quality: RacketRecordingQuality = .hd1080
    /// Rest between drill blocks.
    var restSec: Int = 60
    /// Start the next block when the rest timer ends.
    var autoStartNextBlock: Bool = true
    /// Countdown before a block starts.
    var countdownSec: Int = 5
    /// Drill plan: blocks × length.
    var blocks: Int = 3
    var blockSec: Int = 300
    /// "Still playing?" after this many minutes with no activity; `nil` ⇒ off. Game by game / block by block.
    var stillPlayingByUnitMin: Int? = 30
    /// The same, when recording everything (a long recording is expected to be quiet for longer).
    var stillPlayingEverythingMin: Int? = 60

    static let restOptions = [30, 60, 90, 120]
    static let countdownOptions = [3, 5, 10]
    static let blockLengthOptions = [60, 120, 180, 300, 420, 600]
    static let stillByUnitOptions = [15, 30, 60]
    static let stillEverythingOptions = [30, 60, 90]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RacketRecordingDefaults()
        func mode(_ k: CodingKeys) -> RacketRecordingMode? {
            (try? c.decodeIfPresent(String.self, forKey: k)).flatMap { $0 }.flatMap(RacketRecordingMode.init(rawValue:))
        }
        matchMode = mode(.matchMode) ?? d.matchMode
        drillMode = mode(.drillMode) ?? d.drillMode
        quality = (try? c.decodeIfPresent(String.self, forKey: .quality)).flatMap { $0 }
            .flatMap(RacketRecordingQuality.init(rawValue:)) ?? d.quality
        restSec = (try? c.decodeIfPresent(Int.self, forKey: .restSec)).flatMap { $0 } ?? d.restSec
        autoStartNextBlock = (try? c.decodeIfPresent(Bool.self, forKey: .autoStartNextBlock)).flatMap { $0 } ?? d.autoStartNextBlock
        countdownSec = (try? c.decodeIfPresent(Int.self, forKey: .countdownSec)).flatMap { $0 } ?? d.countdownSec
        blocks = (try? c.decodeIfPresent(Int.self, forKey: .blocks)).flatMap { $0 } ?? d.blocks
        blockSec = (try? c.decodeIfPresent(Int.self, forKey: .blockSec)).flatMap { $0 } ?? d.blockSec
        // A present-but-null threshold means "off"; an absent key means the default.
        stillPlayingByUnitMin = c.contains(.stillPlayingByUnitMin)
            ? (try? c.decodeIfPresent(Int.self, forKey: .stillPlayingByUnitMin)).flatMap { $0 } : d.stillPlayingByUnitMin
        stillPlayingEverythingMin = c.contains(.stillPlayingEverythingMin)
            ? (try? c.decodeIfPresent(Int.self, forKey: .stillPlayingEverythingMin)).flatMap { $0 } : d.stillPlayingEverythingMin
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(matchMode.rawValue, forKey: .matchMode)
        try c.encode(drillMode.rawValue, forKey: .drillMode)
        try c.encode(quality.rawValue, forKey: .quality)
        try c.encode(restSec, forKey: .restSec)
        try c.encode(autoStartNextBlock, forKey: .autoStartNextBlock)
        try c.encode(countdownSec, forKey: .countdownSec)
        try c.encode(blocks, forKey: .blocks)
        try c.encode(blockSec, forKey: .blockSec)
        // Encode nil explicitly so "off" survives a round trip (absent ⇒ default).
        try c.encode(stillPlayingByUnitMin, forKey: .stillPlayingByUnitMin)
        try c.encode(stillPlayingEverythingMin, forKey: .stillPlayingEverythingMin)
    }

    private enum CodingKeys: String, CodingKey {
        case matchMode, drillMode, quality, restSec, autoStartNextBlock, countdownSec, blocks, blockSec,
             stillPlayingByUnitMin, stillPlayingEverythingMin
    }

    static func load(from data: Data?) -> RacketRecordingDefaults {
        guard let data, let d = try? JSONDecoder().decode(RacketRecordingDefaults.self, from: data) else { return .init() }
        return d
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }

    func mode(for racketMode: RacketMode) -> RacketRecordingMode {
        racketMode == .match ? matchMode : drillMode
    }

    /// The configured "Still playing?" threshold for a recording mode, in minutes; `nil` ⇒ off (and never for
    /// "don't film" — there's no recording to stop). One source for every screen that quotes it (review5 M4).
    func stillPlayingMinutes(for recording: RacketRecordingMode) -> Int? {
        switch recording {
        case .byUnit: return stillPlayingByUnitMin
        case .everything: return stillPlayingEverythingMin
        case .off: return nil
        }
    }
}

// MARK: - Drill plan (PracticeSetup)

/// A drill's plan and recording, chosen in the setup sheet before it starts.
struct RacketDrillPlan: Equatable, Sendable {
    var blocks: Int
    var blockSec: Int
    var restSec: Int
    var autoStart: Bool
    var countdownSec: Int
    var recording: RacketRecordingMode
    /// Drill details (Customize, prompt 250): practising, focus, pattern, goal.
    var details = RacketDrillDetails()

    init(blocks: Int = 3, blockSec: Int = 300, restSec: Int = 60, autoStart: Bool = true, countdownSec: Int = 5,
         recording: RacketRecordingMode = .byUnit, details: RacketDrillDetails = RacketDrillDetails()) {
        self.blocks = blocks
        self.blockSec = blockSec
        self.restSec = restSec
        self.autoStart = autoStart
        self.countdownSec = countdownSec
        self.recording = recording
        self.details = details
    }

    init(defaults d: RacketRecordingDefaults) {
        self.init(blocks: d.blocks, blockSec: d.blockSec, restSec: d.restSec, autoStart: d.autoStartNextBlock,
                  countdownSec: d.countdownSec, recording: d.drillMode)
    }

    /// The plan stored on a drill entity (missing fields fall back to `defaults`).
    init(from ex: SessionExercise, defaults d: RacketRecordingDefaults) {
        self.init(blocks: max(1, ex.plannedSets ?? d.blocks),
                  blockSec: ex.drillBlockSec ?? d.blockSec,
                  restSec: ex.targetRestSeconds > 0 ? ex.targetRestSeconds : d.restSec,
                  autoStart: ex.drillAutoStart ?? d.autoStartNextBlock,
                  countdownSec: ex.drillCountdownSec ?? d.countdownSec,
                  recording: ex.racketRecording, details: RacketDrillDetails(from: ex))
    }

    func apply(to ex: inout SessionExercise) {
        ex.plannedSets = max(1, blocks)
        ex.drillBlockSec = blockSec
        ex.targetRestSeconds = restSec
        ex.drillAutoStart = autoStart
        ex.drillCountdownSec = countdownSec
        ex.racketRecordingRaw = recording == .byUnit ? nil : recording.rawValue
        details.apply(to: &ex)
    }

    /// "3 blocks × 5:00".
    var summary: String { "\(blocks) \(blocks == 1 ? "block" : "blocks") × \(RacketClock.mmss(TimeInterval(blockSec)))" }
}

// MARK: - The recording log (persisted on the entity)

/// One record-everything recording, on the match / drill it belongs to. Times are seconds from `startedAt`, so a
/// block, a rest or a game is a time range on the one recording, and an interruption is a gap between two parts.
/// Splitting (step 3) only ever reads these ranges; the Photos originals are never changed.
struct RacketRecordingLog: Codable, Hashable, Sendable {
    /// One saved Photos video (a part is cut every `RacketStorageCheck.partSec`, and at every interruption).
    struct Asset: Codable, Hashable, Sendable {
        var localIdentifier: String
        var startSec: Double
        var durationSec: Double?
    }
    /// A continuous capture run, between a start / resume and a stop / interruption.
    struct Run: Codable, Hashable, Sendable {
        var startSec: Double
        var endSec: Double?
        /// `RacketInterruption.rawValue` when this run ended because of one.
        var endReasonRaw: String?
    }
    /// `breakStart`: "Break starts" from the Watch (XxWatchMark, prompt 245) — a break between games, for the split.
    /// `firstPoint`: the first point of a game tapped on the Watch (prompt 246) — play has started, so the split can
    /// tell a warmup or a break from the game after it. Not a user mark.
    /// `point`: a point tapped on the Watch (prompt 248), `index` 0 = you won it, 1 = they did — the anchors a rally
    /// scan uses. Not a user mark.
    /// `game`: one game of a game-by-game recording, `index` its set index (prompt 249); `interval`: badminton's
    /// interval at 11 inside a game. Both are time ranges, not user marks.
    enum MarkKind: String, Codable, Sendable { case block, rest, moment, newGame, breakStart, firstPoint, point, game, interval }
    struct Mark: Codable, Hashable, Sendable {
        var kindRaw: String
        /// The block's / rest's 0-based block index; nil for a moment.
        var index: Int?
        var startSec: Double
        var endSec: Double?
        var kind: MarkKind? { MarkKind(rawValue: kindRaw) }
    }

    var startedAt: Date
    var runs: [Run] = []
    var assets: [Asset] = []
    var marks: [Mark] = []
    var endedAt: Date?

    // Step 3 (prompt 246) — additive Optionals: old logs decode with nil.
    /// How many units / blocks the entity had logged when this recording began; the recording's own games / blocks
    /// are `sets[baseSetIndex...]`. `nil` ⇒ 0.
    var baseSetIndex: Int?
    /// `RacketRecordingQuality.rawValue` it was recorded at (the space estimates).
    var qualityRaw: String?
    /// The split into games, breaks and so on: time ranges on this recording (`RacketVideoSplit.swift`).
    var split: RacketSplit?
    /// "Keep as one video" on the split prompt: don't offer the split again (it stays in Your videos).
    var keptAsOne: Bool?
    /// Rallies marked and tagged on this recording, as time ranges on it (`RacketRallyTags.swift`).
    var rallies: [RacketRally]?
    /// New Photos videos made from this recording: one per part when the original was deleted, or one per kept
    /// rally stretch ("Keep rallies only"). Times are on this recording's timeline.
    var derived: [RacketDerivedVideo]?
    /// The original parts were deleted from Photos (only after the derived videos were saved).
    var originalDeleted: Bool?

    // Step 4 (prompt 247) — additive Optionals.
    /// Parts sent to another AI app (what, to which app, and the clip's pieces for mapping the reply's times back).
    var aiRequests: [RacketAIRequest]?
    /// Replies brought back: suggestions until compared, then reviewed (`RacketAIRoundTrip.swift`).
    var aiImports: [RacketAIImport]?

    // Step 5 (prompt 248) — additive Optional.
    /// Rally scans per part: model, progress, results (`RacketModelHooks.swift`).
    var scans: [RacketScanRecord]?
    /// Your videos already acted on "After a session" for this recording (started, asked, or waiting for a charger).
    var scanOffered: Bool?

    // Prompt 249 — additive Optional.
    /// `RacketRecordingMode.rawValue` this recording was made in; `nil` ⇒ everything (the only mode with a log before).
    var modeRaw: String?

    init(startedAt: Date) { self.startedAt = startedAt }

    func offset(_ date: Date) -> Double { max(0, date.timeIntervalSince(startedAt)) }

    /// Seconds actually recorded (gaps excluded), up to `now` for an open run.
    func recordedSec(now: Date) -> Double {
        runs.reduce(0) { $0 + max(0, ($1.endSec ?? offset(now)) - $1.startSec) }
    }

    /// The end of the last closed run — "Everything up to 31:04 is saved".
    var savedUpToSec: Double { runs.compactMap(\.endSec).max() ?? 0 }

    var blockMarks: [Mark] { marks.filter { $0.kind == .block } }
    var userMarkCount: Int { marks.filter { $0.kind == .moment || $0.kind == .newGame || $0.kind == .breakStart }.count }

    /// "1 recording · 3 block parts" (review5 M2): what a drill recorded with everything ends as. Block by block
    /// (prompt 250): "3 blocks · 3 clips" (PracticeReview) — every run is its own Photos clip.
    var drillSummaryLine: String {
        let n = blockMarks.filter { $0.endSec != nil }.count
        if modeRaw == RacketRecordingMode.byUnit.rawValue {
            let clips = runs.filter { r in r.endSec.map { $0 > r.startSec } ?? true }.count
            return "\(n) \(n == 1 ? "block" : "blocks") · \(clips) \(clips == 1 ? "clip" : "clips")"
        }
        return "1 recording · \(n) block \(n == 1 ? "part" : "parts")"
    }
}

extension RacketRecordingLog {
    var newGameMarkCount: Int { marks.filter { $0.kind == .newGame }.count }

    /// How many games to ask scores for after a whole-match recording: one per "New game starts" mark plus the game
    /// before the first, at least one, and never more than `maxRemaining` (the format's games still to play).
    func suggestedGameCount(maxRemaining: Int?) -> Int {
        let n = max(1, newGameMarkCount + 1)
        guard let maxRemaining else { return n }
        return max(1, min(n, maxRemaining))
    }
}

/// The games still to ask after a recording: the format's most units minus those already logged; `nil` ⇒ open play.
enum RacketRecordedGames {
    static func maxRemaining(format: RacketFormat, loggedUnits: Int) -> Int? {
        guard let bestOf = format.bestOf else { return nil }
        return max(1, bestOf - loggedUnits)
    }
}

// MARK: - Remembered drill plans

/// A drill's plan step opens on the plan you used last time for that drill (same sport, same name), else the
/// Settings defaults — so one tap starts it. Remembered from history, not a new store: racket drills aren't
/// routine rows (prompt 203 keeps routines racket-free), so "last time" is the routine memory for a drill.
enum RacketDrillPlanMemory {
    /// `candidates` newest first. Only drills set up with a plan (prompt 244 or later) count.
    static func lastPlan(sport: RacketSport, name: String, candidates: [SessionExercise],
                         defaults: RacketRecordingDefaults) -> RacketDrillPlan? {
        let key = RacketStats.normalize(name)
        guard let ex = candidates.first(where: {
            $0.isRacketDrill && $0.racketSport == sport && $0.drillBlockSec != nil
                && RacketStats.normalize($0.displayName ?? "") == key
        }) else { return nil }
        return RacketDrillPlan(from: ex, defaults: defaults)
    }

    static func plan(sport: RacketSport, name: String, candidates: [SessionExercise],
                     defaults: RacketRecordingDefaults) -> RacketDrillPlan {
        lastPlan(sport: sport, name: name, candidates: candidates, defaults: defaults) ?? RacketDrillPlan(defaults: defaults)
    }
}

// MARK: - Interruptions

/// Why recording stopped mid-way. Calls and leaving the app can resume (a new part of the same recording); full
/// storage and overheating can't (`TtInterrupted` / `TtInterruptedStop`).
enum RacketInterruption: String, Codable, Sendable {
    case call, appLeft, cameraBusy, storageFull, tooHot, cameraError

    var canResume: Bool {
        switch self {
        case .call, .appLeft, .cameraBusy, .cameraError: return true
        case .storageFull, .tooHot: return false
        }
    }

    var headline: String {
        switch self {
        case .call: return "A phone call stopped the recording"
        case .appLeft: return "Snappet left the screen, so the recording stopped"
        case .cameraBusy: return "Another app took the camera"
        case .cameraError: return "The camera stopped unexpectedly"
        case .storageFull: return "Storage is full"
        case .tooHot: return "The phone got too hot"
        }
    }

    var advice: String {
        switch self {
        case .storageFull: return "Free some space to record again."
        case .tooHot: return "iOS stops the camera to protect the phone. Let it cool in the shade, then start a new recording."
        default: return "This also happens when Snappet leaves the screen or the phone locks. Full storage or overheating can’t resume."
        }
    }

    /// `AVCaptureSession.InterruptionReason` raw values (stable, documented): 1 background, 2 audio device in use
    /// (a call), 3 video device in use, 4 multiple foreground apps, 5 system pressure (heat).
    static func fromCaptureInterruption(reasonRaw: Int) -> RacketInterruption {
        switch reasonRaw {
        case 1, 4: return .appLeft
        case 2: return .call
        case 3: return .cameraBusy
        case 5: return .tooHot
        default: return .cameraError
        }
    }

    /// An `AVError` code that ended a movie file. `nil` ⇒ not an interruption (finished normally / the part limit).
    /// -11807 disk full, -11810 maximum duration reached (the part limit), -11811 max file size, -11818 session
    /// was interrupted, -11819 media services reset.
    static func fromRecordingError(code: Int?) -> RacketInterruption? {
        switch code {
        case nil, -11810: return nil
        case -11807, -11811: return .storageFull
        case -11818: return .appLeft
        default: return .cameraError
        }
    }
}

// MARK: - End routing (review5 H1)

/// Where "End" goes from Interrupted / InterruptedStop and from the recording screen.
enum RacketRecordingEndRoute: Equatable, Sendable {
    /// Game by game: confirm the game's score.
    case score
    /// A drill (any mode): the drill review.
    case drillReview
    /// A whole-match recording: the split prompt (prompt 246, `RacketVideoViews.swift`).
    case splitPrompt
}

enum RacketRecordingRoutes {
    static func endRoute(mode: RacketMode, recording: RacketRecordingMode) -> RacketRecordingEndRoute {
        if mode == .drill { return .drillReview }
        return recording == .everything ? .splitPrompt : .score
    }

    static func endLabel(_ route: RacketRecordingEndRoute) -> String {
        switch route {
        case .score: return "End and confirm the score"
        case .drillReview: return "End drill"
        case .splitPrompt: return "End and split"
        }
    }

    /// "Keep scoring without video" is a match-only exit — a drill has no score to keep (H1).
    static func allowsScoringWithoutVideo(mode: RacketMode) -> Bool { mode == .match }

    /// The interruption header, by mode (never a hard-coded "Game 2").
    static func header(mode: RacketMode, recording: RacketRecordingMode, unit: RacketUnit,
                       unitNumber: Int, block: Int?, blocks: Int) -> String {
        switch (mode, recording) {
        case (.match, .everything): return "Match, recording everything"
        case (.match, _): return "\(unit.noun.capitalized) \(unitNumber)"
        case (.drill, _):
            guard let block else { return "Drill" }
            return "Block \(block + 1) of \(blocks)"
        }
    }
}

// MARK: - "Still playing?"

enum RacketStillPlaying {
    /// How long the prompt waits for an answer before it stops the recording.
    static let answerWindowSec: TimeInterval = 120

    /// "No score taps or marks for 30 minutes." — always the configured threshold (review5 M4).
    static func reason(minutes: Int) -> String { "No score taps or marks for \(minutes) minutes." }
    static func again(minutes: Int) -> String { "Keep recording asks again in \(minutes) minutes." }
    /// Game by game (StillPlaying board): "Keep recording asks again in 30 minutes. When you record everything, it waits 60."
    static func again(minutes: Int, everythingMinutes: Int?) -> String {
        guard let everythingMinutes else { return again(minutes: minutes) }
        return again(minutes: minutes) + " When you record everything, it waits \(everythingMinutes)."
    }
    static let stopsLine = "Recording stops in 2:00 if there’s no answer. Everything so far stays saved."

    /// The line on the record-everything screen.
    static func recordAllFooter(minutes: Int?) -> String {
        guard let minutes else { return "No break timers or game prompts. Still playing? is off in Settings." }
        return "No break timers or game prompts. Still playing? asks only after \(minutes) min with no activity."
    }
}

// MARK: - Timer display (word + ring)

// `RacketTimerTone`, `RacketTimerDisplay` and `RacketClock` live in `Shared/RacketTimerDisplay.swift` (prompt 245) so the
// phone and the Watch draw the same rings from one source.

// MARK: - The state machine

/// Record everything, as one value: the phase (countdown · block · rest · recording a match · ended), the capture
/// state, interruptions, "Still playing?", and the log of runs and marks. Every event takes `now` and returns the
/// side effects the host must perform; the host never decides a transition itself.
struct RacketRecordingMachine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case match
        case drill(RacketDrillPlan)
    }

    enum Phase: Equatable, Sendable {
        /// Not started, or a drill waiting before block 1 (after Wait — review5 M3: no rest timer before block 1).
        case ready
        /// Counting down to `block` (0-based).
        case countdown(block: Int, endsAt: Date)
        case block(Int, startedAt: Date)
        /// Pause during a block (Paused / DrillPaused, prompt 250): the block timer stopped after `elapsed` seconds of
        /// play; nothing is recorded or counted until Resume.
        case blockPaused(Int, elapsed: TimeInterval)
        case rest(after: Int, endsAt: Date)
        case restPaused(after: Int, remaining: TimeInterval)
        /// The rest ran out with auto-start off, or Wait on a later countdown: the player starts the next block.
        case restDone(after: Int)
        /// A whole match, recording.
        case recordingMatch
        case ended(RacketRecordingEndRoute)
    }

    enum Effect: Equatable, Sendable {
        case startCapture
        case stopCapture
        /// A drill block finished: log it with its length.
        case logBlock(index: Int, durationSec: TimeInterval)
        case askStillPlaying
        case ended(RacketRecordingEndRoute)
        /// "Keep scoring without video": close the recording screen, the match page carries on.
        case continueWithoutVideo
    }

    /// The drill's plan can change mid-drill (More options: rest length, auto-start, blocks — prompt 250).
    private(set) var kind: Kind
    let racketMode: RacketMode
    let recording: RacketRecordingMode
    /// "Still playing?" threshold in seconds; `nil` ⇒ off.
    let stillPlayingSec: TimeInterval?
    /// Units / blocks already logged when the recording began, and the quality it records at (prompt 246: the split
    /// reads the recording's own games from here; the space estimates use the quality). Stamped on the log.
    var baseSetIndex: Int?
    var quality: RacketRecordingQuality?
    /// A drill's first block in this recording, as an index into the drill's blocks (prompt 250: the drill cover counts
    /// blocks absolutely, so a drill reopened after block 2 starts at block 3). 0 for record everything's old screen.
    var startingBlock = 0

    private(set) var phase: Phase = .ready
    /// The camera is (meant to be) writing.
    private(set) var capturing = false
    private(set) var interruption: RacketInterruption?
    /// When "Still playing?" was asked; `nil` ⇒ not showing.
    private(set) var stillPlayingAskedAt: Date?
    private(set) var lastActivity: Date
    private(set) var log: RacketRecordingLog?
    /// The recording ended because "Still playing?" went unanswered (the Watch says so, prompt 245).
    private(set) var endedByStillPlaying = false

    init(kind: Kind, recording: RacketRecordingMode = .everything, stillPlayingMinutes: Int?, now: Date) {
        self.kind = kind
        if case .match = kind { racketMode = .match } else { racketMode = .drill }
        self.recording = recording
        stillPlayingSec = stillPlayingMinutes.map { TimeInterval($0 * 60) }
        lastActivity = now
    }

    var plan: RacketDrillPlan? { if case .drill(let p) = kind { return p } else { return nil } }
    var endRoute: RacketRecordingEndRoute { RacketRecordingRoutes.endRoute(mode: racketMode, recording: recording) }
    var isEnded: Bool { if case .ended = phase { return true } else { return false } }

    /// The block the screen is about (the current one, the next one during a countdown, the last one during rest).
    var currentBlock: Int? {
        switch phase {
        case .countdown(let b, _), .block(let b, _), .blockPaused(let b, _): return b
        case .rest(let a, _), .restPaused(let a, _), .restDone(let a): return a
        case .ready: return plan == nil ? nil : 0
        case .recordingMatch, .ended: return nil
        }
    }

    // MARK: Start

    /// Match: recording starts now. Drill: the countdown to block 1 (recording starts with the block).
    @discardableResult
    mutating func start(now: Date) -> [Effect] {
        guard phase == .ready else { return [] }
        touch(now)
        switch kind {
        case .match:
            phase = .recordingMatch
            return beginRun(now)
        case .drill(let p):
            let next = max(startingBlock, log?.blockMarks.count ?? 0)
            phase = .countdown(block: next, endsAt: now.addingTimeInterval(TimeInterval(p.countdownSec)))
            return []
        }
    }

    /// Countdown "+30 s".
    mutating func extendCountdown(by sec: TimeInterval, now: Date) {
        guard case .countdown(let b, let endsAt) = phase else { return }
        touch(now)
        phase = .countdown(block: b, endsAt: endsAt.addingTimeInterval(sec))
    }

    /// Countdown "Wait": before block 1 it goes back to ready (the camera / setup — no rest timer, review5 M3); before
    /// a later block it returns to a paused rest timer (the rest mark reopens).
    mutating func wait(now: Date) {
        guard case .countdown(let b, _) = phase else { return }
        touch(now)
        if b <= startingBlock {
            phase = .ready
        } else {
            // DrillCountdown: "Wait returns to a paused rest timer" (+30 s / +1 min add time; Resume continues).
            phase = .restPaused(after: b - 1, remaining: 0)
            reopenRestMark(index: b - 1)
        }
    }

    /// "Start block N" from ready / rest done, or "Skip rest": a fresh countdown.
    @discardableResult
    mutating func startNextBlock(now: Date) -> [Effect] {
        guard let p = plan else { return [] }
        switch phase {
        case .ready:
            return start(now: now)
        case .rest(let a, _), .restPaused(let a, _), .restDone(let a):
            touch(now)
            closeOpenMark(.rest, now: now)
            phase = .countdown(block: a + 1, endsAt: now.addingTimeInterval(TimeInterval(p.countdownSec)))
            return []
        default:
            return []
        }
    }

    // MARK: Rest

    mutating func addRest(_ sec: TimeInterval, now: Date) {
        touch(now)
        switch phase {
        case .rest(let a, let endsAt): phase = .rest(after: a, endsAt: endsAt.addingTimeInterval(sec))
        case .restPaused(let a, let left): phase = .restPaused(after: a, remaining: left + sec)
        default: break
        }
    }

    mutating func pauseRest(now: Date) {
        guard case .rest(let a, let endsAt) = phase else { return }
        touch(now)
        phase = .restPaused(after: a, remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    mutating func resumeRest(now: Date) {
        guard case .restPaused(let a, let left) = phase else { return }
        touch(now)
        phase = .rest(after: a, endsAt: now.addingTimeInterval(left))
    }

    // MARK: Blocks

    /// "End block" (or the block timer running out, via `tick`) — also from Paused.
    @discardableResult
    mutating func endBlock(now: Date) -> [Effect] {
        touch(now)
        return finishBlock(now: now)
    }

    private mutating func finishBlock(now: Date) -> [Effect] {
        guard let p = plan else { return [] }
        let b: Int, played: TimeInterval
        switch phase {
        case .block(let i, let startedAt): b = i; played = now.timeIntervalSince(startedAt)
        case .blockPaused(let i, let elapsed): b = i; played = elapsed
        default: return []
        }
        closeOpenMark(.block, now: now)
        var effects: [Effect] = [.logBlock(index: b, durationSec: played)]
        if b + 1 >= p.blocks {
            effects += finish(now: now)
        } else {
            // Block by block (prompt 250): each block is its own clip, so recording pauses for the rest.
            if recording == .byUnit, capturing {
                endRun(now: now, reason: nil)
                effects.append(.stopCapture)
            }
            phase = .rest(after: b, endsAt: now.addingTimeInterval(TimeInterval(p.restSec)))
            openMark(.rest, index: b, now: now)
        }
        return effects
    }

    // MARK: Pause during a block (Paused / DrillPaused, prompt 250)

    /// "Pause": the block timer stops and recording pauses (in every mode — "Nothing is recorded or counted while
    /// paused"). The run closes without an interruption, so Resume starts a new part.
    @discardableResult
    mutating func pauseBlock(now: Date) -> [Effect] {
        guard case .block(let b, let startedAt) = phase else { return [] }
        touch(now)
        phase = .blockPaused(b, elapsed: max(0, now.timeIntervalSince(startedAt)))
        guard capturing else { return [] }
        endRun(now: now, reason: nil)
        return [.stopCapture]
    }

    /// "Resume" (phone or Watch): the block timer carries on from where it stopped; recording resumes.
    @discardableResult
    mutating func resumeBlock(now: Date) -> [Effect] {
        guard case .blockPaused(let b, let elapsed) = phase else { return [] }
        touch(now)
        phase = .block(b, startedAt: now.addingTimeInterval(-elapsed))
        return interruption == nil ? beginRun(now) : []
    }

    var isBlockPaused: Bool { if case .blockPaused = phase { return true } else { return false } }

    // MARK: More options (RestEverything / Rest, prompt 250)

    /// The rest's Auto-start switch (and More options → Auto-start).
    mutating func setAutoStart(_ on: Bool, now: Date) {
        guard case .drill(var p) = kind else { return }
        touch(now)
        p.autoStart = on
        kind = .drill(p)
        // A rest that already ran out with auto-start off stays "done"; switching it on then starts the countdown.
        if on, case .restDone(let a) = phase {
            closeOpenMark(.rest, now: now)
            phase = .countdown(block: a + 1, endsAt: now.addingTimeInterval(TimeInterval(p.countdownSec)))
        }
    }

    /// More options → Rest length: the running rest restarts from the new length; later rests use it too.
    mutating func setRestSec(_ sec: Int, now: Date) {
        guard case .drill(var p) = kind else { return }
        touch(now)
        p.restSec = max(5, sec)
        kind = .drill(p)
        switch phase {
        case .rest(let a, _): phase = .rest(after: a, endsAt: now.addingTimeInterval(TimeInterval(p.restSec)))
        case .restPaused(let a, _): phase = .restPaused(after: a, remaining: TimeInterval(p.restSec))
        default: break
        }
    }

    /// More options → "End after the next block": the next block is the last one.
    mutating func endAfterNextBlock(now: Date) {
        guard case .drill(var p) = kind, let b = currentBlock else { return }
        touch(now)
        switch phase {
        case .rest, .restPaused, .restDone: p.blocks = b + 2
        default: p.blocks = b + 1
        }
        kind = .drill(p)
    }

    /// More options → "Add a block".
    mutating func addBlock(now: Date) {
        guard case .drill(var p) = kind else { return }
        touch(now)
        p.blocks += 1
        kind = .drill(p)
    }

    // MARK: Match marks

    /// "Mark this moment" / "New game starts" / "Break starts" (the Watch, prompt 245).
    mutating func mark(_ kind: RacketRecordingLog.MarkKind, now: Date) {
        guard phase == .recordingMatch,
              kind == .moment || kind == .newGame || kind == .breakStart || kind == .firstPoint else { return }
        appendMark(kind, index: nil, now: now)
    }

    /// A point tapped on the Watch (prompt 248): `us` won it or not. Anchors the rally scan; Undo drops the last one.
    mutating func markPoint(us: Bool, now: Date) {
        guard phase == .recordingMatch else { return }
        appendMark(.point, index: us ? 0 : 1, now: now)
    }

    /// Undo on the Watch: the last point tapped is gone.
    mutating func dropLastPoint() {
        guard var l = log, let i = l.marks.lastIndex(where: { $0.kind == .point }) else { return }
        l.marks.remove(at: i)
        log = l
    }

    private mutating func appendMark(_ kind: RacketRecordingLog.MarkKind, index: Int?, now: Date) {
        touch(now)
        guard var l = log else { return }
        l.marks.append(.init(kindRaw: kind.rawValue, index: index, startSec: l.offset(now), endSec: nil))
        log = l
    }

    // MARK: End

    /// Stop and split / Finish drill / End (from Interrupted or the still-playing timeout).
    @discardableResult
    mutating func end(now: Date) -> [Effect] {
        guard !isEnded else { return [] }
        var effects: [Effect] = []
        if case .block(let b, let startedAt) = phase {
            // Finishing mid-block logs the block that was played.
            closeOpenMark(.block, now: now)
            effects.append(.logBlock(index: b, durationSec: now.timeIntervalSince(startedAt)))
        } else if case .blockPaused(let b, let elapsed) = phase {
            // Stop drill from Paused: the block played up to the pause.
            closeOpenMark(.block, now: now)
            effects.append(.logBlock(index: b, durationSec: elapsed))
        }
        return effects + finish(now: now)
    }

    private mutating func finish(now: Date) -> [Effect] {
        closeOpenMark(.rest, now: now)
        var effects: [Effect] = []
        if capturing { effects.append(.stopCapture) }
        endRun(now: now, reason: nil)
        stillPlayingAskedAt = nil
        let route = endRoute
        phase = .ended(route)
        if var l = log { l.endedAt = now; log = l }
        effects.append(.ended(route))
        return effects
    }

    // MARK: Interruptions

    /// The capture stopped for `reason` (the file up to here is already saved by the edge).
    /// Ignored before anything was recorded (the preview alone isn't a recording) and once a non-resumable reason
    /// already stands; a resumable one can escalate (a call, then the storage fills).
    mutating func interrupt(_ reason: RacketInterruption, now: Date) {
        guard !isEnded, log != nil, interruption?.canResume != false else { return }
        endRun(now: now, reason: reason)
        interruption = reason
        stillPlayingAskedAt = nil
    }

    /// "Resume recording": a new part of the same recording. Only when the reason allows it.
    @discardableResult
    mutating func resume(now: Date) -> [Effect] {
        guard let i = interruption, i.canResume, !isEnded else { return [] }
        touch(now)
        interruption = nil
        // A drill between blocks keeps recording too (everything includes rests), unless it hasn't started yet. A paused
        // block, and block by block between blocks, stay paused (prompt 250).
        if case .ready = phase { return [] }
        if case .countdown = phase, (log?.runs.isEmpty ?? true) { return [] }
        if case .blockPaused = phase { return [] }
        if racketMode == .drill, recording == .byUnit, !isInBlock { return [] }
        return beginRun(now)
    }

    // MARK: Game by game (prompt 249)

    /// The block timer is running (not paused, not between blocks).
    var isInBlock: Bool { if case .block = phase { return true } else { return false } }

    /// Continue an earlier game-by-game recording of this match (the screen was closed between games): new games
    /// add runs and parts to the same log. Only before anything is recorded here. A block-by-block drill reopened
    /// mid-way continues its log the same way (prompt 250).
    mutating func continueLog(_ l: RacketRecordingLog) {
        guard log == nil, recording == .byUnit else { return }
        log = l
    }

    /// A break or an interval with "Pause recording" on, or between games: the run closes without an interruption.
    @discardableResult
    mutating func pauseCapture(now: Date) -> [Effect] {
        guard capturing, !isEnded else { return [] }
        endRun(now: now, reason: nil)
        return [.stopCapture]
    }

    /// The next game (or a recorded break) starts: a new run, and a new Photos part.
    @discardableResult
    mutating func resumeCapture(now: Date) -> [Effect] {
        guard !isEnded, interruption == nil, phase == .recordingMatch else { return [] }
        touch(now)
        return beginRun(now)
    }

    /// A game starts (its set index) / ends: a time range on the recording (`MarkKind.game`).
    mutating func openGame(index: Int, now: Date) {
        guard phase == .recordingMatch else { return }
        closeOpenMark(.game, now: now)
        openMark(.game, index: index, now: now)
    }

    mutating func closeGame(now: Date) { closeOpenMark(.game, now: now) }

    /// Badminton's interval: a range inside the game.
    mutating func openInterval(now: Date) {
        guard phase == .recordingMatch, let l = log, !l.marks.contains(where: { $0.kind == .interval && $0.endSec == nil }) else { return }
        openMark(.interval, index: nil, now: now)
    }

    mutating func closeInterval(now: Date) { closeOpenMark(.interval, now: now) }

    /// "Keep scoring without video" (a match only): recording is over, the match goes on without the camera.
    @discardableResult
    mutating func continueWithoutVideo(now: Date) -> [Effect] {
        guard RacketRecordingRoutes.allowsScoringWithoutVideo(mode: racketMode), interruption != nil else { return [] }
        interruption = nil
        phase = .ended(.score)
        if var l = log { l.endedAt = now; log = l }
        return [.continueWithoutVideo]
    }

    // MARK: Activity + "Still playing?"

    /// Any tap the player makes counts as activity (score, mark, block, rest).
    mutating func noteActivity(now: Date) { touch(now) }

    /// "Keep recording": asks again after the same threshold.
    mutating func keepPlaying(now: Date) {
        stillPlayingAskedAt = nil
        touch(now)
    }

    // MARK: Clock

    /// Advance the timers. Call about once a second.
    @discardableResult
    mutating func tick(now: Date) -> [Effect] {
        var effects: [Effect] = []
        switch phase {
        case .countdown(let b, let endsAt) where now >= endsAt:
            phase = .block(b, startedAt: endsAt)
            // Recording and the block timer start at zero together (block 1); later blocks are already recording.
            if interruption == nil { effects += beginRun(endsAt) }
            openMark(.block, index: b, now: endsAt)
        case .block(_, let startedAt):
            if let p = plan, now.timeIntervalSince(startedAt) >= TimeInterval(p.blockSec) {
                effects += finishBlock(now: startedAt.addingTimeInterval(TimeInterval(p.blockSec)))
            }
        case .rest(let a, let endsAt) where now >= endsAt:
            if let p = plan, p.autoStart {
                closeOpenMark(.rest, now: endsAt)
                phase = .countdown(block: a + 1, endsAt: endsAt.addingTimeInterval(TimeInterval(p.countdownSec)))
            } else {
                // The rest mark stays open until the player starts the next block.
                phase = .restDone(after: a)
            }
        default:
            break
        }
        effects += checkStillPlaying(now: now)
        return effects
    }

    private mutating func checkStillPlaying(now: Date) -> [Effect] {
        guard let threshold = stillPlayingSec, capturing, !isEnded, interruption == nil else { return [] }
        if let asked = stillPlayingAskedAt {
            if now.timeIntervalSince(asked) >= RacketStillPlaying.answerWindowSec {
                endedByStillPlaying = true
                return end(now: now)
            }
            return []
        }
        if now.timeIntervalSince(lastActivity) >= threshold {
            stillPlayingAskedAt = now
            return [.askStillPlaying]
        }
        return []
    }

    /// The timer word, tone and ring for the current phase.
    func display(now: Date) -> RacketTimerDisplay? {
        switch phase {
        case .countdown(let b, let endsAt):
            let total = TimeInterval(plan?.countdownSec ?? 5)
            let left = max(0, endsAt.timeIntervalSince(now))
            return .init(word: "Block \(b + 1) starts", tone: .work, seconds: left, progress: min(1, left / max(1, total)))
        case .block(_, let startedAt):
            let total = TimeInterval(plan?.blockSec ?? 1)
            let left = max(0, total - now.timeIntervalSince(startedAt))
            return .init(word: "Block", tone: .work, seconds: left, progress: left / max(1, total))
        case .rest(_, let endsAt):
            let total = TimeInterval(plan?.restSec ?? 60)
            let left = max(0, endsAt.timeIntervalSince(now))
            return .init(word: "Rest", tone: .rest, seconds: left, progress: min(1, left / max(1, total)))
        case .restPaused(_, let left):
            let total = TimeInterval(plan?.restSec ?? 60)
            return .init(word: "Rest, paused", tone: .restPaused, seconds: left, progress: min(1, left / max(1, total)))
        case .restDone:
            return .init(word: "Rest done", tone: .rest, seconds: 0, progress: 0)
        case .blockPaused(_, let elapsed):
            let total = TimeInterval(plan?.blockSec ?? 1)
            let left = max(0, total - elapsed)
            return .init(word: "Paused", tone: .restPaused, seconds: left, progress: left / max(1, total))
        case .recordingMatch:
            return .init(word: "Recording", tone: .work, seconds: log?.recordedSec(now: now) ?? 0, progress: 1)
        case .ended:
            return .init(word: "Done", tone: .done, seconds: log?.recordedSec(now: now) ?? 0, progress: 1)
        case .ready:
            return nil
        }
    }

    // MARK: Edge reports

    /// A Photos part was saved by the capture edge.
    mutating func assetSaved(localIdentifier: String, startedAt: Date, durationSec: Double?) {
        guard var l = log else { return }
        l.assets.append(.init(localIdentifier: localIdentifier, startSec: l.offset(startedAt), durationSec: durationSec))
        log = l
    }

    // MARK: Internals

    private mutating func touch(_ now: Date) {
        lastActivity = now
        stillPlayingAskedAt = nil
    }

    private mutating func beginRun(_ now: Date) -> [Effect] {
        // Everything, a match game by game (prompt 249: each game is its own run and part), and a drill block by block
        // (prompt 250: each block is its own run and part). "Don't film" never records.
        guard recording == .everything || recording == .byUnit else { return [] }
        if log == nil {
            var l = RacketRecordingLog(startedAt: now)
            l.baseSetIndex = baseSetIndex
            l.qualityRaw = quality?.rawValue
            if recording == .byUnit { l.modeRaw = recording.rawValue }
            log = l
        }
        guard !capturing, var l = log else { return [] }
        l.runs.append(.init(startSec: l.offset(now), endSec: nil, endReasonRaw: nil))
        log = l
        capturing = true
        return [.startCapture]
    }

    private mutating func endRun(now: Date, reason: RacketInterruption?) {
        guard capturing, var l = log, let i = l.runs.indices.last else { capturing = false; return }
        l.runs[i].endSec = l.offset(now)
        l.runs[i].endReasonRaw = reason?.rawValue
        log = l
        capturing = false
    }

    private mutating func openMark(_ kind: RacketRecordingLog.MarkKind, index: Int?, now: Date) {
        guard var l = log else { return }
        l.marks.append(.init(kindRaw: kind.rawValue, index: index, startSec: l.offset(now), endSec: nil))
        log = l
    }

    private mutating func reopenRestMark(index: Int) {
        guard var l = log, let i = l.marks.lastIndex(where: { $0.kind == .rest && $0.index == index }) else { return }
        l.marks[i].endSec = nil
        log = l
    }

    private mutating func closeOpenMark(_ kind: RacketRecordingLog.MarkKind, now: Date) {
        guard var l = log, let i = l.marks.lastIndex(where: { $0.kind == kind && $0.endSec == nil }) else { return }
        l.marks[i].endSec = max(l.marks[i].startSec, l.offset(now))
        log = l
    }
}
