import Foundation

// MARK: - Device feedback round 1 (issue #438; prompts 244 and 246)
//
// Pure pieces for two things found on a real iPhone:
// - the record-everything screen showed no camera view, so the shot couldn't be framed (`RacketRecordingShow`);
// - the split review / "Fix one part" had no video (`RacketSplitTimeline`, `RacketScrub`, `RacketVideoLoad`).
// Foundation only, so they run in SnappetTests with no device.

// MARK: - What the recording screen shows (TtRecordAll · CameraView · Dim boards)

/// The Dim · Camera · Stats switcher at the bottom of the recording screen.
/// Camera = the live preview with compact numbers under it (the CameraView boards); Dim = a black, low-power screen
/// that is still recording (the controls stay, faint); Stats = the numbers view (TtRecordAll as built in step 1).
enum RacketRecordingShow: String, CaseIterable, Sendable {
    case dim, camera, stats

    var label: String {
        switch self {
        case .dim: return "Dim"
        case .camera: return "Camera"
        case .stats: return "Stats"
        }
    }

    /// Device feedback: the screen opens on the camera, so the shot can be framed.
    static let initial: RacketRecordingShow = .camera

    /// The drill's camera step before block 1 is for framing: it always shows the preview.
    static func showsPreview(_ show: RacketRecordingShow, phase: RacketRecordingMachine.Phase) -> Bool {
        if phase == .ready { return true }
        if case .ended = phase { return false }
        return show == .camera
    }

    /// The switcher shows while recording (or counting down to a block); not on the camera step or once ended.
    static func showsSwitcher(phase: RacketRecordingMachine.Phase) -> Bool {
        switch phase {
        case .ready, .ended: return false
        default: return true
        }
    }

    /// Smaller numbers and no explanatory lines, so the preview gets the room. Dim is the full TtRecordAll layout
    /// (the board shows Dim selected), on black.
    static func compact(_ show: RacketRecordingShow, phase: RacketRecordingMachine.Phase) -> Bool {
        if case .ended = phase { return false }
        return showsPreview(show, phase: phase)
    }
}

// MARK: - The numbers while recording a whole match (TtRecordAll · LiveStatsOff)

enum RacketRecordStats {
    /// TtRecordAll's big number: the current game's points from the Watch ("4 – 3 · Score from Watch"). Before the
    /// Watch has tallied a point (or with no Watch) it is the match so far in games / sets, labelled so.
    static func bigScore(live: RacketLiveScore?, won: Int, lost: Int, unit: RacketUnit) -> (value: String, caption: String) {
        if let live, !live.isEmpty { return (live.display, "Score from Watch") }
        return ("\(won) – \(lost)", "\(unit.noun.capitalized)s")
    }

    /// Points played in the game the Watch is tallying (LiveStatsOff "Points played"); nil with no tally.
    static func pointsPlayed(_ live: RacketLiveScore?) -> Int? {
        guard let live, !live.isEmpty else { return nil }
        let t = live.tally
        if let r = t.result, live.rules.kind == .rally { return r.scoreFor + r.scoreAgainst }
        return t.pointsFor + t.pointsAgainst
    }

    /// "Game time": since the last "New game starts" mark (or the recording's start), on the recording's clock.
    static func gameSec(_ log: RacketRecordingLog, now: Date) -> Double {
        let t = log.offset(now)
        let lastNew = log.marks.filter { $0.kind == .newGame && $0.startSec <= t }.map(\.startSec).max() ?? 0
        return max(0, t - lastNew)
    }

    /// "You 4 · Alex 3" from your tags.
    static func tagsLine(_ summary: RacketTagSummary, sides: (us: String, them: String)) -> String {
        "\(sides.us) \(summary.wonUs) · \(sides.them) \(summary.wonThem)"
    }
}

// MARK: - The split review's segmented timeline (TtSplitReview)

enum RacketSplitTimeline {
    /// Game accent; warmup / break / rest / not play / practice grey; an unsure stretch amber.
    enum Tone: Equatable, Sendable { case game, grey, unsure }

    struct Segment: Equatable, Sendable {
        var id: UUID
        var index: Int
        /// Leading edge and width in points.
        var x: Double
        var width: Double
        var tone: Tone
    }

    static func tone(_ p: RacketVideoPart) -> Tone {
        switch RacketSplitReview.status(p) {
        case .matched: return .game
        case .unsure: return .unsure
        case .notCounted: return .grey
        }
    }

    /// One segment per part, laid out on `width` points with `gap` between neighbours. A segment is never thinner
    /// than `minWidth` (a 5 s break on a 75 min recording stays visible and tappable).
    static func layout(_ parts: [RacketVideoPart], total: Double, width: Double, gap: Double = 2,
                       minWidth: Double = 3) -> [Segment] {
        guard !parts.isEmpty, width > 0 else { return [] }
        let span = max(0.001, total)
        return parts.enumerated().map { k, p in
            let a = x(at: p.startSec, total: span, width: width)
            let b = x(at: p.endSec, total: span, width: width)
            let inset = k == parts.count - 1 ? 0 : gap
            return Segment(id: p.id, index: k, x: a, width: max(minWidth, b - a - inset), tone: tone(p))
        }
    }

    /// Recording time → x on a bar `width` wide (clamped).
    static func x(at t: Double, total: Double, width: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(max(0, t), total) / total * width
    }

    /// x → recording time (clamped).
    static func time(atX x: Double, total: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, x), width) / width * max(0, total)
    }

    /// The part holding `t` (the last part also holds the very end).
    static func partIndex(at t: Double, in parts: [RacketVideoPart]) -> Int? {
        if let i = parts.firstIndex(where: { $0.contains(t) }) { return i }
        if let last = parts.last, abs(t - last.endSec) < 0.001 { return parts.count - 1 }
        return nil
    }
}

// MARK: - Seeking and scrubbing (TtSplitReview · TtSplitEdit)

enum RacketScrub {
    /// Where to start playing a part: its start, or — when it starts in a gap with no video (an interruption) — the
    /// first moment inside it that has video. With no video at all, its start (the stand-in clock runs from there).
    static func seekTarget(_ p: RacketVideoPart, sources: [RacketVideoMap.Source]) -> Double {
        let covered = sources.filter { $0.endSec > p.startSec && $0.startSec < p.endSec }
        guard !covered.isEmpty else { return p.startSec }
        if covered.contains(where: { $0.startSec <= p.startSec }) { return p.startSec }
        return covered.map(\.startSec).min() ?? p.startSec
    }

    /// Where a paused player opens (device bug, prompt 251): the split prompt, split review and the player opened at
    /// recording time 0, but a recording's first video starts a moment later (the camera starting up, 0.7 s on the
    /// phone) — an empty stretch of the composition, so the video area stayed black until a seek. A start inside a
    /// gap moves to the first moment with video after it (within `end`); a start that has video stays.
    static func firstFrame(at t: Double, segments: [RacketVideoSegment], end: Double) -> Double {
        if segments.contains(where: { t >= $0.timelineStart - 0.001 && t < $0.timelineStart + $0.durationSec }) { return t }
        return segments.map(\.timelineStart).filter { $0 > t && $0 < end }.min() ?? t
    }

    /// Seek tolerance while dragging: about one point's worth of time on the strip (clamped to 0.04…2 s), so a
    /// drag lands near the frame under the finger without asking for an exact frame on every move.
    static func tolerance(windowSec: Double, widthPoints: Double) -> Double {
        guard widthPoints > 0 else { return 0.5 }
        return min(2, max(0.04, windowSec / widthPoints))
    }

    /// A new drag position is worth a seek when it moved at least half the tolerance from the last one asked for.
    static func shouldSeek(last: Double?, to t: Double, tolerance: Double) -> Bool {
        guard let last else { return true }
        return abs(t - last) >= tolerance / 2
    }

    /// The film strip's frames: `count` evenly spaced times across `[start, end]`, each at the centre of its tile.
    static func thumbnailTimes(start: Double, end: Double, count: Int) -> [Double] {
        guard count > 0, end > start else { return [] }
        let step = (end - start) / Double(count)
        return (0..<count).map { start + step * (Double($0) + 0.5) }
    }

    /// How many 16:9 tiles fill a strip `width` × `height` (at least 1, at most 12).
    static func thumbnailCount(width: Double, height: Double) -> Int {
        guard width > 0, height > 0 else { return 1 }
        return min(12, max(1, Int((width / (height * 16 / 9)).rounded(.up))))
    }

    /// "Split here" at the playhead: the playhead, when it leaves both halves at least `RacketSplitEditor.minPartSec`;
    /// otherwise nil (the button explains why).
    static func splitPoint(playhead: Double, part: RacketVideoPart) -> Double? {
        let m = RacketSplitEditor.minPartSec
        guard playhead - part.startSec >= m, part.endSec - playhead >= m else { return nil }
        return playhead
    }
}

// MARK: - Loading the original (iCloud-only / missing)

/// What the player can show for a recording, before and while it loads.
enum RacketVideoLoad: Equatable, Sendable {
    /// Checking Photos.
    case checking
    /// Some originals are only in iCloud: downloading (0…1).
    case downloading(Double)
    /// Ready to play (some stretches may be missing: `missing` of `needed`).
    case ready(missing: Int)
    /// Nothing was saved for this recording (the simulator's stand-in camera, the UI seed).
    case noVideo
    /// None of the originals are on this phone or in iCloud (deleted).
    case missing(count: Int)
    /// iCloud didn't send them (offline, or turned off).
    case downloadFailed

    /// Before downloading: what Photos says about the needed ids.
    static func initial(needed: [String], found: Set<String>, cloudOnly: Set<String>) -> RacketVideoLoad {
        guard !needed.isEmpty else { return .noVideo }
        let present = needed.filter { found.contains($0) }
        if present.isEmpty { return .missing(count: needed.count) }
        if present.contains(where: { cloudOnly.contains($0) }) { return .downloading(0) }
        return .ready(missing: needed.count - present.count)
    }

    /// The overall download fraction from per-video fractions (videos not reported yet count as 0).
    static func overall(_ progress: [String: Double], ids: Set<String>) -> Double {
        guard !ids.isEmpty else { return 1 }
        let sum = ids.reduce(0.0) { $0 + min(1, max(0, progress[$1] ?? 0)) }
        return sum / Double(ids.count)
    }

    /// The line on the video area ("Downloading from iCloud… 40 %"), nil when the video shows.
    var line: String? {
        switch self {
        case .checking: return "Loading video…"
        case .downloading(let f): return "Downloading from iCloud… \(Int((f * 100).rounded())) %"
        case .ready(let missing):
            if missing == 0 { return nil }
            return missing == 1 ? "1 part of the original isn’t on this phone; that stretch stays black"
                                : "\(missing) parts of the original aren’t on this phone; those stretches stay black"
        case .noVideo: return "No video saved for this recording"
        case .missing: return "The original isn’t on this phone. You can still split it by time."
        case .downloadFailed: return "Couldn’t download from iCloud. Check the connection and try again."
        }
    }

    var canRetry: Bool { self == .downloadFailed }

    /// Waiting on iCloud (the video area shows a download symbol).
    var isCloud: Bool {
        switch self {
        case .downloading, .downloadFailed: return true
        default: return false
        }
    }
}
