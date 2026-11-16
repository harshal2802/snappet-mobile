import Foundation

// MARK: - The rally's video controls (prompt 257) — pure
//
// Device feedback on the tag sheet: "video look so small on this page and there are no controls". The rally's video
// (`RacketRallyVideo`) now loops a stretch with a scrub bar, speed, replay, "−3 s" / "+3 s" to see what led to the rally
// (or what came after), a full-screen view and Rotate. The decisions are here so they run in SnappetTests; the views in
// `RacketTagViews.swift` only draw them. The Watch player's own pieces (`RacketPlayerZoom`, `RacketPlayerText`) are reused.

/// The stretch the rally's video loops: the rally padded `pad` seconds each side (as before), widened by "−3 s" /
/// "+3 s", always inside the part.
struct RacketRallyLoop: Equatable, Sendable {
    static let pad: Double = 1
    static let step: Double = 3

    let rally: ClosedRange<Double>
    let partStart: Double
    let partEnd: Double
    /// Seconds added before / after by "−3 s" / "+3 s".
    private(set) var earlier: Double = 0
    private(set) var later: Double = 0

    init(rally: ClosedRange<Double>, partStart: Double, partEnd: Double) {
        self.rally = rally
        self.partStart = partStart
        self.partEnd = max(partStart, partEnd)
    }

    var window: ClosedRange<Double> {
        let lo = min(partEnd, max(partStart, rally.lowerBound - Self.pad - earlier))
        let hi = max(lo, min(partEnd, rally.upperBound + Self.pad + later))
        return lo...hi
    }

    var length: Double { window.upperBound - window.lowerBound }

    /// "−3 s" still reaches further back (not yet at the part's start).
    var canWidenEarlier: Bool { rally.lowerBound - Self.pad - earlier > partStart + 0.01 }
    /// "+3 s" still reaches further on (not yet at the part's end).
    var canWidenLater: Bool { rally.upperBound + Self.pad + later < partEnd - 0.01 }

    mutating func widenEarlier() { if canWidenEarlier { earlier += Self.step } }
    mutating func widenLater() { if canWidenLater { later += Self.step } }

    /// Where `t` sits along the scrub bar (0…1).
    func fraction(of t: Double) -> Double {
        guard length > 0 else { return 0 }
        return min(1, max(0, (t - window.lowerBound) / length))
    }

    /// The time at `f` (0…1) along the scrub bar.
    func time(atFraction f: Double) -> Double {
        window.lowerBound + min(1, max(0, f)) * length
    }

    /// The rally itself along the bar (highlighted).
    var rallyFractions: (from: Double, to: Double) {
        (fraction(of: rally.lowerBound), fraction(of: rally.upperBound))
    }

    /// "0:03 / 0:12": the playhead in the loop and the loop's length.
    func timeLine(_ position: Double) -> String {
        "\(RacketVideoTime.clock(min(length, max(0, position - window.lowerBound)))) / \(RacketVideoTime.clock(length))"
    }

    /// While looping: playback stopped at the loop's end (or has left the loop) ⇒ start it again from the loop's start.
    func shouldRestart(position: Double, playing: Bool) -> Bool {
        guard !playing else { return false }
        return position >= window.upperBound - 0.15 || position < window.lowerBound - 0.05
    }
}

/// The rally video's speed button: 1× → 0.5× → 0.25× → 1× (slow motion for reading a rally; faster isn't needed).
enum RacketRallyVideoSpeed {
    static let options: [Float] = [1, 0.5, 0.25]

    static func next(_ rate: Float) -> Float {
        guard let i = options.firstIndex(of: rate) else { return 1 }
        return options[(i + 1) % options.count]
    }
}

/// What a tap on the rally's picture does: toggle playing, and which glyph flashes in the centre.
enum RacketRallyVideoTap {
    /// Playing ⇒ pause (shows the pause glyph); paused ⇒ play (shows the play glyph).
    static func toggle(playing: Bool) -> (play: Bool, glyph: String) {
        playing ? (false, "pause.fill") : (true, "play.fill")
    }
}
