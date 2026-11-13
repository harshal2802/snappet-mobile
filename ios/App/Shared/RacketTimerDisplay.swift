import Foundation

// Racket timer word + ring (prompt 244, moved to Shared/ in prompt 245). Pure, compiled into every target via the
// project.yml Shared glob, so the phone's recording screen and the Watch draw the same phase the same way.

/// The phase word and ring tone: Work in the accent, Rest / Break / Interval in grey, Paused in grey at 0.55, Done in
/// green (#438 design).
enum RacketTimerTone: String, Codable, Equatable, Sendable { case work, rest, restPaused, done }

struct RacketTimerDisplay: Codable, Equatable, Sendable {
    var word: String
    var tone: RacketTimerTone
    /// Seconds left (counting down) or elapsed (a match recording).
    var seconds: TimeInterval
    /// Ring fill, 0…1 (the part of the phase still to go).
    var progress: Double
}

enum RacketClock {
    /// "4:05", "1:02:04".
    static func mmss(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec.rounded(.up)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The phone ring's clock (prompt 251): Block and Paused read zero-padded like their boards ("01:48"); rest,
    /// break, interval and countdown rings keep "0:45".
    static func ring(_ d: RacketTimerDisplay) -> String {
        guard d.word == "Block" || d.word == "Paused" else { return mmss(d.seconds) }
        let s = max(0, Int(d.seconds.rounded(.up)))
        if s >= 3600 { return mmss(d.seconds) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Elapsed clocks floor rather than round up.
    static func elapsed(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
