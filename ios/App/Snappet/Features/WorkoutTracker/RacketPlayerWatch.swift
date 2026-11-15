import Foundation
import CoreGraphics

// MARK: - Racket player, Watch mode (prompt 253, issue #448 part 1 "Watch")
//
// Boards Main → PlayerLandscapeChrome: Apple Photos' video viewer with YouTube's gestures. Video only by default (a
// score pill and a thin progress line with rally segments); a tap shows the controls (back, title, Share, Edit, a
// filmstrip with rally bands under a fixed centre playhead, play/pause, mute, previous / next rally, speed); double-tap
// a side skips 10 s; touch and hold plays at 2×; pinch zooms. Everything here is pure (Foundation + CoreGraphics
// value types only) so it runs in SnappetTests with no device; `RacketWatchPlayerViews.swift` renders it and
// `RacketPlayback` (Services/RacketVideoLibrary.swift) drives AVFoundation.

// MARK: - Copy and formatting

enum RacketPlayerText {
    /// "08:14", "18:32", "1:02:03" — the player's clock (two-digit minutes, as the boards show).
    static func clock(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
    }

    /// "08:14 / 18:32": the position in the part and the part's length.
    static func timeLine(_ position: Double, of duration: Double) -> String {
        "\(clock(min(max(0, position), max(0, duration)))) / \(clock(duration))"
    }

    /// "6.2 s" — a rally's length to a tenth.
    static func seconds(_ d: Double) -> String {
        String(format: "%.1f s", max(0, d))
    }

    /// "7 – 5" — the score pill (spaced en dash, as the boards).
    static func score(_ us: Int, _ them: Int) -> String { "\(us) – \(them)" }

    /// "0.25×", "0.5×", "1×", "1.5×", "2×".
    static func speed(_ rate: Float) -> String {
        let r = Double(rate)
        if r == r.rounded() { return "\(Int(r))×" }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s + "×"
    }

    /// "2.4×" — the zoom label.
    static func zoom(_ scale: Double) -> String { String(format: "%.1f×", scale) }

    /// "+10 s" / "−10 s" (a real minus sign) — the double-tap ripple; repeated taps add up ("+20 s").
    static func skip(_ sec: Double) -> String {
        let n = Int(abs(sec).rounded())
        return sec < 0 ? "−\(n) s" : "+\(n) s"
    }

    static let holdLabel = "2× · release for normal speed"
    static let turnHint = "Turn the phone for full screen"
    static let noRallies = "No rallies marked yet"
    static let noScore = "No score yet"
    static let videoMissing = "Video missing"
    static let missingTitle = "This video is no longer in Photos"
    static let missingBody = "Your rallies, tags and score are kept. Without the video you can’t play, share or find more rallies."
    /// PlayerOpening says "Scrubbing works on thumbnails meanwhile", but Photos hands over no frames of an iCloud-only
    /// video until it has downloaded (only its poster), so the line says what really happens (decision, prompt 253).
    static let openingLine = "The video plays when the download finishes"

    /// "Downloading from iCloud · 42%" (PlayerOpening).
    static func downloading(_ fraction: Double) -> String {
        "Downloading from iCloud · \(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// The part's title without " video": "Game 1 video" → "Game 1".
    static func title(_ refTitle: String) -> String {
        refTitle.hasSuffix(" video") ? String(refTitle.dropLast(6)) : refTitle
    }
}

// MARK: - The part's rallies, in order

/// A part's rallies sorted by start, with the questions the player asks of them.
struct RacketPlayerRallies: Equatable, Sendable {
    let rallies: [RacketRally]

    init(_ all: [RacketRally]) {
        rallies = all.filter(\.isRally).sorted { $0.startSec < $1.startSec }
    }

    var count: Int { rallies.count }
    var isEmpty: Bool { rallies.isEmpty }
    var anyTagged: Bool { rallies.contains { $0.winner != nil } }

    /// The rally playing at `t` (0-based), if any.
    func index(at t: Double) -> Int? {
        rallies.firstIndex { t >= $0.startSec && t < $0.endSec }
    }

    /// The rally at `t`, else the last one that started before `t` (0-based); nil before the first.
    func lastStarted(at t: Double) -> Int? {
        rallies.lastIndex { $0.startSec <= t }
    }

    /// The score from your tags through the rally at (or last before) `t`; nil when nothing is tagged.
    func runningScore(at t: Double) -> (us: Int, them: Int)? {
        guard anyTagged else { return nil }
        guard let i = lastStarted(at: t) else { return (0, 0) }
        let rs = rallies.prefix(i + 1)
        return (rs.filter { $0.winner == .us }.count, rs.filter { $0.winner == .them }.count)
    }

    /// Previous rally (the transport's |◀): inside a rally more than `restartAfter` seconds in, its own start
    /// (like a music player's back); otherwise the rally before. nil when there is none.
    func previousStart(from t: Double, restartAfter: Double = 1.5) -> Double? {
        if let i = lastStarted(at: t) {
            if t - rallies[i].startSec > restartAfter { return rallies[i].startSec }
            return i > 0 ? rallies[i - 1].startSec : nil
        }
        return nil
    }

    /// Next rally (▶|): the first rally starting after `t`; nil after the last.
    func nextStart(from t: Double) -> Double? {
        rallies.first { $0.startSec > t + 0.05 }?.startSec
    }

    /// The rally to loop ("Loop this rally"): the one playing, else the next one, else the last one.
    func loopTarget(at t: Double) -> (number: Int, range: ClosedRange<Double>)? {
        let i = index(at: t) ?? rallies.firstIndex { $0.startSec > t } ?? (rallies.isEmpty ? nil : rallies.count - 1)
        guard let i else { return nil }
        return (i + 1, rallies[i].startSec...rallies[i].endSec)
    }
}

// MARK: - Lines on the player

enum RacketPlayerCopy {
    /// The top bar's second line: "7 – 5 · Rally 12 of 21". No rallies: the logged score, else "No score yet".
    static func subtitle(_ rs: RacketPlayerRallies, at t: Double, loggedScore: String? = nil, missing: Bool = false) -> String {
        if missing { return RacketPlayerText.videoMissing }
        guard !rs.isEmpty else { return loggedScore ?? RacketPlayerText.noScore }
        var parts: [String] = []
        if let s = rs.runningScore(at: t) { parts.append(RacketPlayerText.score(s.us, s.them)) }
        if let i = rs.lastStarted(at: t) {
            parts.append("Rally \(i + 1) of \(rs.count)")
        } else {
            parts.append("\(rs.count) \(rs.count == 1 ? "rally" : "rallies")")
        }
        return parts.joined(separator: " · ")
    }

    /// Landscape's one-line title: "Game 1 · 7 – 5 · Rally 12 of 21".
    static func landscapeTitle(_ title: String, _ rs: RacketPlayerRallies, at t: Double, loggedScore: String? = nil,
                               missing: Bool = false) -> String {
        "\(title) · \(subtitle(rs, at: t, loggedScore: loggedScore, missing: missing))"
    }

    /// The controls' label line: "Rally 12 · You won · 6.2 s"; "Rally 13 · untagged · 5.0 s"; "Between rallies";
    /// "No rallies marked yet".
    static func rallyLine(_ rs: RacketPlayerRallies, at t: Double, sides: (us: String, them: String)) -> String {
        guard !rs.isEmpty else { return RacketPlayerText.noRallies }
        guard let i = rs.index(at: t) else { return "Between rallies" }
        let r = rs.rallies[i]
        return "Rally \(i + 1) · \(result(r, sides: sides)) · \(RacketPlayerText.seconds(r.durationSec))"
    }

    /// The scrub readout's rally line: "Rally 13 · untagged" (amber) or "Rally 12 · You won"; nil between rallies.
    static func scrubLine(_ rs: RacketPlayerRallies, at t: Double, sides: (us: String, them: String)) -> (text: String, untagged: Bool)? {
        guard let i = rs.index(at: t) else { return nil }
        let r = rs.rallies[i]
        return ("Rally \(i + 1) · \(result(r, sides: sides))", r.winner == nil)
    }

    /// Landscape without controls: "Rally 12 · 6.2 s"; nil between rallies.
    static func compactRally(_ rs: RacketPlayerRallies, at t: Double) -> String? {
        guard let i = rs.index(at: t) else { return nil }
        return "Rally \(i + 1) · \(RacketPlayerText.seconds(rs.rallies[i].durationSec))"
    }

    /// "You won" / "Alex won" / "untagged".
    static func result(_ r: RacketRally, sides: (us: String, them: String)) -> String {
        switch r.winner {
        case .us: return "\(sides.us) won"
        case .them: return "\(sides.them) won"
        case nil: return "untagged"
        }
    }

    /// PlayerEnd: "Game 1 ended · Won 11–9" (the logged score), "Game 1 ended · Lost 9–11", or "Game 1 ended".
    static func endLine(_ title: String, score: RacketUnitScore?) -> String {
        guard let score, let won = score.won else { return "\(title) ended" }
        return "\(title) ended · \(won ? "Won" : "Lost") \(score.label)"
    }

    /// The small labels shown while the controls are hidden (PlayerModes): "Loop · rally 12", "Rallies only", "0.5×".
    static func modeBadges(loopNumber: Int?, ralliesOnly: Bool, rate: Float) -> [String] {
        var out: [String] = []
        if let n = loopNumber { out.append("Loop · rally \(n)") }
        if ralliesOnly && loopNumber == nil { out.append("Rallies only") }
        if rate != 1 { out.append(RacketPlayerText.speed(rate)) }
        return out
    }
}

// MARK: - The controls: show on tap, hide by themselves while playing

enum RacketPlayerChrome {
    /// Photos / YouTube: about 3 s without a touch.
    static let hideAfter: Double = 3

    /// Hide the controls now? Only while playing (paused, they stay), never mid-drag or with the speed menu open.
    static func shouldHide(visible: Bool, playing: Bool, idleSec: Double, dragging: Bool, menuOpen: Bool) -> Bool {
        visible && playing && !dragging && !menuOpen && idleSec >= hideAfter
    }
}

// MARK: - Taps: single toggles at once, a second tap on a side skips

/// The video's tap state machine. A single tap toggles the controls **at once** (no waiting to see if a second tap
/// comes, so it never feels late). A second tap within `doubleWindow` turns the pair into a skip: it toggles back
/// (undoing the first tap's change) and skips 10 s on the side of the second tap. Further taps on the same side within
/// `streakWindow` of the last add 10 s each (YouTube's "+20 s, +30 s").
struct RacketPlayerTaps: Equatable, Sendable {
    static let doubleWindow: Double = 0.3
    static let streakWindow: Double = 0.7
    static let skipSec: Double = 10

    enum Side: Equatable, Sendable { case back, forward }

    enum Action: Equatable, Sendable {
        case toggleControls
        /// Seek by this many seconds.
        case skip(Double)
        /// Show the ripple on `side` with the running total ("+20 s").
        case ripple(Side, total: Double)
    }

    private var lastTap: Double?
    private var streak: (side: Side, total: Double, at: Double)?

    static func == (a: RacketPlayerTaps, b: RacketPlayerTaps) -> Bool {
        a.lastTap == b.lastTap && a.streak?.side == b.streak?.side && a.streak?.total == b.streak?.total
            && a.streak?.at == b.streak?.at
    }

    static func side(x: Double, width: Double) -> Side { x < width / 2 ? .back : .forward }

    mutating func tap(x: Double, width: Double, at time: Double) -> [Action] {
        let side = Self.side(x: x, width: width)
        let step = side == .back ? -Self.skipSec : Self.skipSec
        if let s = streak, s.side == side, time - s.at <= Self.streakWindow {
            let total = s.total + step
            streak = (side, total, time)
            lastTap = nil
            return [.skip(step), .ripple(side, total: total)]
        }
        streak = nil
        if let last = lastTap, time - last <= Self.doubleWindow {
            lastTap = nil
            streak = (side, step, time)
            return [.toggleControls, .skip(step), .ripple(side, total: step)]
        }
        lastTap = time
        return [.toggleControls]
    }

    /// VoiceOver's "Skip back / forward 10 seconds" actions.
    static func accessibilitySkip(_ side: Side) -> Double { side == .back ? -skipSec : skipSec }
}

// MARK: - Touch and hold: 2× until release

struct RacketPlayerHold: Equatable, Sendable {
    static let rate: Float = 2
    private(set) var saved: Float?
    private(set) var wasPlaying = false

    var isHolding: Bool { saved != nil }

    /// Start holding: play at 2× (playing even if paused), remembering the speed to go back to.
    mutating func begin(rate: Float, playing: Bool) -> (rate: Float, play: Bool) {
        if saved == nil { saved = rate; wasPlaying = playing }
        return (Self.rate, true)
    }

    /// Release: the speed from before, and pause again if it was paused. nil when not holding.
    mutating func end() -> (rate: Float, pause: Bool)? {
        guard let r = saved else { return nil }
        saved = nil
        return (r, !wasPlaying)
    }
}

// MARK: - Speed menu, loop and rallies only

enum RacketPlayerSpeed {
    static let options: [Float] = [0.25, 0.5, 1, 1.5, 2]
    /// The identifier suffix for an option: "0.25", "0.5", "1", "1.5", "2".
    static func id(_ rate: Float) -> String { String(RacketPlayerText.speed(rate).dropLast()) }
}

enum RacketPlayerLoop {
    enum Jump: Equatable, Sendable { case to(Double), clear }

    /// While looping a rally: just past its end ⇒ back to its start; well outside it (the viewer skipped or scrubbed
    /// away) ⇒ the loop ends; inside ⇒ nothing.
    static func jump(at t: Double, loop: ClosedRange<Double>, slack: Double = 1) -> Jump? {
        if t >= loop.lowerBound - 0.05 && t < loop.upperBound { return nil }
        if t >= loop.upperBound && t <= loop.upperBound + slack { return .to(loop.lowerBound) }
        return .clear
    }
}

// MARK: - Pinch to zoom, drag to pan

enum RacketPlayerZoom {
    static let minScale: Double = 1
    static let maxScale: Double = 5

    static func clamp(_ scale: Double) -> Double { min(maxScale, max(minScale, scale)) }

    static func isZoomed(_ scale: Double) -> Bool { scale > 1.01 }

    /// Keep the zoomed video covering what it can: the video (`video`, its fitted size in points) scaled by `scale`
    /// about the centre of `view` may move at most until its edge reaches the view's edge, on each axis. A video that
    /// still doesn't fill an axis (letterboxed) stays centred on it.
    static func clampOffset(_ offset: CGSize, scale: Double, video: CGSize, view: CGSize) -> CGSize {
        let maxX = max(0, (video.width * scale - view.width) / 2)
        let maxY = max(0, (video.height * scale - view.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
    }
}

// MARK: - Fitting the video, sideways video on an upright phone

enum RacketPlayerFit {
    /// The aspect-fit rect of a video of `video` size inside `view`.
    static func fitted(video: CGSize, in view: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0, view.width > 0, view.height > 0 else {
            return CGRect(origin: .zero, size: view)
        }
        let s = min(view.width / video.width, view.height / video.height)
        let w = video.width * s, h = video.height * s
        return CGRect(x: (view.width - w) / 2, y: (view.height - h) / 2, width: w, height: h)
    }

    /// PlayerLetterbox: a sideways (landscape) video on an upright phone shows "Turn the phone for full screen".
    static func showsTurnHint(video: CGSize?, view: CGSize) -> Bool {
        guard let video, video.height > 0 else { return false }
        return video.width > video.height * 1.05 && view.height > view.width
    }
}

// MARK: - The filmstrip: a strip under a fixed centre playhead

/// The strip scrolls under a fixed centre playhead: the playhead's time sits at the strip's centre, so the strip's
/// offset is `-(t − start) × pointsPerSec`. Dragging the strip by `dx` moves the time by `−dx / pointsPerSec`.
struct RacketFilmstrip: Equatable, Sendable {
    let start: Double
    let end: Double
    let pointsPerSec: Double

    /// About a minute of video across the visible strip (so a 6 s rally is a band you can see), and never less than
    /// the whole part filling it.
    static func pointsPerSec(duration: Double, visibleWidth: Double, secondsVisible: Double = 60) -> Double {
        guard visibleWidth > 0 else { return 4 }
        let perMinute = visibleWidth / secondsVisible
        return max(perMinute, visibleWidth / max(1, duration))
    }

    init(start: Double, end: Double, visibleWidth: Double) {
        self.start = start
        self.end = max(start, end)
        self.pointsPerSec = Self.pointsPerSec(duration: end - start, visibleWidth: visibleWidth)
    }

    /// Edit's strip (prompt 254): a scale set by pinching.
    init(start: Double, end: Double, pointsPerSec: Double) {
        self.start = start
        self.end = max(start, end)
        self.pointsPerSec = max(0.0001, pointsPerSec)
    }

    var length: Double { (end - start) * pointsPerSec }

    /// x of time `t` along the strip (0 at the part's start).
    func x(at t: Double) -> Double { (min(max(t, start), end) - start) * pointsPerSec }

    /// The strip's leading edge relative to the centre playhead when the playhead is at `t`.
    func offset(at t: Double) -> Double { -x(at: t) }

    /// The time after dragging the strip by `translation` points from a drag that began at `from`.
    func time(dragging translation: Double, from: Double) -> Double {
        min(end, max(start, from - translation / pointsPerSec))
    }

    /// Tiles of `tileWidth` points covering the strip, and the time each tile shows (its centre).
    func tileTimes(tileWidth: Double) -> [Double] {
        guard tileWidth > 0, length > 0 else { return [] }
        let n = max(1, Int((length / tileWidth).rounded(.up)))
        return (0..<n).map { k in min(end, start + (Double(k) + 0.5) * tileWidth / pointsPerSec) }
    }

    /// Which of `count` generated thumbnails a tile (of `tiles`) shows: the strip asks for fewer frames than tiles on
    /// a long game and neighbouring tiles share one.
    static func thumbnailIndex(tile: Int, tiles: Int, count: Int) -> Int {
        guard tiles > 0, count > 0 else { return 0 }
        return min(count - 1, tile * count / tiles)
    }

    /// Seek tolerance while the finger drags: exact frames (zero tolerance) while the finger moves slowly enough to
    /// look at frames; a little slack when it flicks fast (each exact seek takes longer than the finger moves).
    /// `videoSecPerSec` is how fast the playhead moves through the video, in seconds of video per real second.
    static func dragTolerance(videoSecPerSec: Double) -> Double {
        let v = abs(videoSecPerSec)
        return v < 4 ? 0 : min(1, v / 20)
    }
}

// MARK: - Rally bands (strip and progress line)

enum RacketPlayerBand: Equatable, Sendable {
    /// You won the rally: accent.
    case won
    /// You lost it: grey.
    case lost
    /// Not tagged yet: a dashed outline.
    case untagged

    static func of(_ r: RacketRally) -> RacketPlayerBand {
        switch r.winner {
        case .us: return .won
        case .them: return .lost
        case nil: return .untagged
        }
    }

    /// Each rally's band as fractions of the part (0…1), for the thin progress line.
    static func fractions(_ rs: RacketPlayerRallies, start: Double, end: Double) -> [(from: Double, to: Double, band: RacketPlayerBand)] {
        let span = max(0.001, end - start)
        return rs.rallies.compactMap { r in
            let a = (max(start, r.startSec) - start) / span, b = (min(end, r.endSec) - start) / span
            return b > a ? (a, b, of(r)) : nil
        }
    }
}
