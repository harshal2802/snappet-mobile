import Foundation

// MARK: - Racket pro camera, while recording (prompt 256, issue #448 part 2) — pure
//
// Boards ProCameraRecording → ProCameraLandscape: what the camera shows while it records, and when something goes
// wrong. Which banner shows for which thermal / interruption / space / battery / Watch inputs, the status line, the
// timer, the break and drill headers, the "HD · 30 from next game" switch and the low-space stop are plain values here,
// tested in `RacketProCameraRecordingTests`. Screens: `RacketProCameraViews.swift` (the `live` chrome) and the three
// recording covers.

// MARK: - Timer and headers

enum RacketCameraRecordingCopy {
    /// The red timer: "00:09:41" (hours always shown, as the Camera app's video timer).
    static func timer(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// A drill block's red timer: "01:48 left".
    static func left(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec.rounded(.up)))
        return String(format: "%02d:%02d left", s / 60, s % 60)
    }

    /// "Game 1 · 4 – 3" (the game and the live score), or just "Game 1" before a point.
    static func gameTitle(_ unitTitle: String, score: String?) -> String {
        guard let score, !score.isEmpty else { return unitTitle }
        return "\(unitTitle) · \(score)"
    }

    /// Record everything's top line: "Match · saved just now" from the real save state.
    static func everythingStatus(savingParts: Int, lastSavedAt: Date?, now: Date) -> String {
        if savingParts > 0 { return "Match · saving a part" }
        guard let at = lastSavedAt else { return "Match · saves every 10 min" }
        let min = Int(now.timeIntervalSince(at) / 60)
        return min < 1 ? "Match · saved just now" : "Match · saved \(min) min ago"
    }

    /// The break's top line: "Game 1 saved · 11–9" (no score: "Game 1 saved").
    static func breakSaved(_ unitTitle: String, score: String?) -> String {
        guard let score else { return "\(unitTitle) saved" }
        return "\(unitTitle) saved · \(score)"
    }

    /// The break's amber centre: "Game 2 in 0:45", "Game 2 · break paused 0:45", "Game 2 ready".
    static func breakCentre(next unitTitle: String, phase: RacketGameFlow.Phase, now: Date) -> String {
        switch phase {
        case .breakTime(let endsAt): return "\(unitTitle) in \(RacketClock.mmss(max(0, endsAt.timeIntervalSince(now))))"
        case .breakPaused(let left): return "\(unitTitle) · paused \(RacketClock.mmss(left))"
        case .breakDone: return "\(unitTitle) ready"
        default: return unitTitle
        }
    }

    static let breakNotice = "Not recording. Lens and quality are unlocked."

    /// "Stopped at 24:18" (too hot) — the saved-up-to time.
    static func stoppedAt(_ sec: Double) -> String { "Stopped at \(RacketClock.recordingHeader(sec))" }
}

// MARK: - What goes wrong, and what the screen says

/// What the screen knows about the phone while it records.
struct RacketCameraConditions: Equatable, Sendable {
    var thermal: RacketThermalLevel = .ok
    /// The thermal state has dropped back below serious (so filming may resume after a heat stop).
    var cooled: Bool { thermal == .ok }
    var interruption: RacketInterruption?
    /// Seconds of recording that fit in free space at the current rate.
    var roomSec: TimeInterval?
    var batteryPercent: Int?
    /// The phone is charging (low battery isn't trouble then).
    var charging = false
    /// The Watch was linked for this match and has stopped answering (or was switched off in Options).
    var watchOff = false
    var format: RacketCameraFormat = .hd30
}

/// The one banner the camera shows. Priority: a stop (too hot, storage full) over an interruption over warm over low
/// space: a stop is the only thing that matters then, and warm is the more urgent of the two warnings.
enum RacketCameraBanner: Equatable, Sendable {
    case none
    /// ProCameraWarm: "▲ Warm at 4K · 60. Recording continues."
    case warm(RacketCameraFormat)
    /// ProCameraHot: recording stopped; resume when cool.
    case hot(savedUpToSec: Double, canResume: Bool)
    /// Storage full: recording stopped; no resume until space is freed.
    case full(savedUpToSec: Double)
    /// ProCameraInterrupted.
    case interrupted(RacketInterruption, savedUpToSec: Double)
    /// ProCameraSpace: "About 12 min of space left".
    case lowSpace(roomSec: TimeInterval)

    static func decide(_ c: RacketCameraConditions, savedUpToSec: Double) -> RacketCameraBanner {
        if let i = c.interruption {
            switch i {
            case .tooHot: return .hot(savedUpToSec: savedUpToSec, canResume: c.cooled)
            case .storageFull: return .full(savedUpToSec: savedUpToSec)
            default: return .interrupted(i, savedUpToSec: savedUpToSec)
            }
        }
        if c.thermal == .warm { return .warm(c.format) }
        if let room = c.roomSec, room < RacketSpaceGuard.lowSec { return .lowSpace(roomSec: room) }
        return .none
    }

    /// The warm line: "▲ Warm at 4K · 60. Recording continues."
    static func warmLine(_ f: RacketCameraFormat) -> String { "▲ Warm at \(f.label). Recording continues." }

    /// "About 12 min of space left".
    static func spaceLine(_ room: TimeInterval) -> String { "About \(RacketCameraStatus.room(room)) of space left" }
}

/// The interrupted banner's copy, by reason, and whether it starts again by itself.
enum RacketInterruptionCopy {
    static func title(_ r: RacketInterruption) -> String {
        switch r {
        case .call: return "Recording paused by a phone call"
        case .cameraBusy: return "Recording paused: another app is using the camera"
        case .appLeft: return "Recording paused: Snappet left the screen"
        case .cameraError: return "The camera stopped unexpectedly"
        case .storageFull: return "Storage is full"
        case .tooHot: return "The phone got too hot to film"
        }
    }

    /// The reasons iOS tells us have ended (`interruptionEnded`), so recording restarts as a new part by itself.
    static func autoResumes(_ r: RacketInterruption) -> Bool {
        switch r {
        case .call, .cameraBusy, .appLeft: return true
        case .cameraError, .storageFull, .tooHot: return false
        }
    }

    /// "Saved up to 09:41. It starts again by itself when the call ends."
    static func line(_ r: RacketInterruption, savedUpToSec: Double) -> String {
        let saved = "Saved up to \(RacketClock.recordingHeader(savedUpToSec))."
        switch r {
        case .call: return "\(saved) It starts again by itself when the call ends."
        case .cameraBusy: return "\(saved) It starts again by itself when the camera is free."
        case .appLeft: return "\(saved) It starts again by itself when you’re back in Snappet."
        case .cameraError: return "\(saved) Resume starts a new part of the same game."
        case .storageFull: return "\(saved) Free some space to record again."
        case .tooHot: return "\(saved) Resume when the phone has cooled."
        }
    }

    /// ProCameraHot's body.
    static func hotLine(savedUpToSec: Double) -> String {
        "Everything up to \(RacketClock.recordingHeader(savedUpToSec)) is saved. Scoring carries on from your Watch or the buttons below."
    }
}

// MARK: - The status pill while recording (ProCameraSpace)

enum RacketCameraTrouble {
    /// Battery at or under this is trouble (unless charging).
    static let lowBatteryPercent = 20

    /// "12 min left · 9% · Watch off": only the troubles, in that order; nil when there are none (the pill then shows
    /// the game and score).
    static func pill(_ c: RacketCameraConditions) -> String? {
        var parts: [String] = []
        if let room = c.roomSec, room < RacketSpaceGuard.lowSec { parts.append("\(RacketCameraStatus.room(room)) left") }
        if let b = c.batteryPercent, !c.charging, b <= lowBatteryPercent { parts.append("\(b)%") }
        if c.watchOff { parts.append("Watch off") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Low space: when to warn and when to stop before the disk is full.
enum RacketSpaceGuard {
    /// Under 30 min of room the camera warns (ProCameraSpace).
    static let lowSec: TimeInterval = 30 * 60
    /// Under 1 min of room it stops the recording cleanly. The room already leaves iOS its margin (500 MB or 2 % of free
    /// space, `RacketStorageCheck.marginBytes`), so the file closes with that much still free — never a disk-full error.
    static let stopSec: TimeInterval = 60

    static func mustStop(roomSec: TimeInterval?) -> Bool { (roomSec ?? .infinity) < stopSec }
}

// MARK: - "HD · 30 from next game"

/// A lighter quality chosen while recording. It never changes the file being written: it applies when the next game,
/// block or recording starts (a whole recording keeps one size so its split plays without rescaling).
struct RacketPendingFormat: Equatable, Sendable {
    private(set) var pending: RacketCameraFormat?

    init() {}

    /// The relief quality: HD · 30.
    static let relief = RacketCameraFormat.hd30

    /// Offer the switch only when it changes something.
    static func offers(current: RacketCameraFormat, pending: RacketCameraFormat?) -> Bool {
        current != relief && pending != relief
    }

    mutating func choose(_ f: RacketCameraFormat) { pending = f }

    /// At a boundary (a new game / block / recording): the format to switch to, once.
    mutating func takeAtBoundary() -> RacketCameraFormat? {
        defer { pending = nil }
        return pending
    }

    /// "HD · 30 from next game" / "… next block" / "… next recording"; once chosen, "HD · 30 next game ✓".
    static func label(_ f: RacketCameraFormat = relief, boundary: Boundary, chosen: Bool) -> String {
        chosen ? "\(f.label) next \(boundary.noun) ✓" : "\(f.label) from next \(boundary.noun)"
    }

    enum Boundary: Equatable, Sendable {
        case game, set, block, recording
        var noun: String {
            switch self {
            case .game: return "game"
            case .set: return "set"
            case .block: return "block"
            case .recording: return "recording"
            }
        }
    }
}

// MARK: - Sideways (ProCameraLandscape)

/// How the camera screen lays out and how a tap maps to the sensor, by the interface orientation.
enum RacketCameraOrientation: Equatable, Sendable {
    case portrait, landscapeLeft, landscapeRight

    var isLandscape: Bool { self != .portrait }

    /// The preview connection's rotation for the back camera (the sensor is landscape-right).
    var previewRotation: Double {
        switch self {
        case .portrait: return 90
        case .landscapeRight: return 0
        case .landscapeLeft: return 180
        }
    }

    /// The shown picture's width / height from the portrait-mapped aspect the recorder reports.
    func shownAspect(portraitAspect: Double?) -> Double? {
        guard let a = portraitAspect, a > 0 else { return nil }
        return isLandscape ? 1 / a : a
    }

    /// A point on the picture (u, v in 0…1, top-left origin as shown) → the sensor's point of interest.
    func devicePoint(u: Double, v: Double) -> (x: Double, y: Double) {
        switch self {
        case .portrait: return (v, 1 - u)
        case .landscapeRight: return (u, v)
        case .landscapeLeft: return (1 - u, 1 - v)
        }
    }

    /// The inverse, to draw the square at a carried point.
    func viewPoint(x: Double, y: Double) -> (u: Double, v: Double) {
        switch self {
        case .portrait: return (1 - y, x)
        case .landscapeRight: return (x, y)
        case .landscapeLeft: return (1 - x, 1 - y)
        }
    }
}
