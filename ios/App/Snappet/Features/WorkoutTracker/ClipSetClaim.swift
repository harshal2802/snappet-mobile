import Foundation

/// **Which set a clip was filmed for** (prompt 191). A clip recorded from an exercise's page — or left behind when a
/// timed set / attempt was closed without logging it — attaches to the exercise with no set yet: the set it shows
/// usually gets logged *after* you stop filming. When the next set of that exercise is logged, it claims the clips
/// filmed since the previous set: a clip belongs to set *k* when it started after set *k−1* was completed (or the
/// session began) and no later than set *k* was. Pure, on session-relative seconds.
enum ClipSetClaim {

    struct Clip: Equatable, Sendable {
        let id: UUID
        /// Seconds from the session's start to when the clip started.
        let offsetSec: Double
    }

    /// The clips set `setIndex` claims, given every completion time (session-relative seconds) of the exercise's
    /// sets in order. Clips filmed before an earlier set are left alone (they were that set's, or the exercise's).
    static func claims(_ clips: [Clip], completions: [Double?], setIndex: Int) -> [UUID] {
        guard completions.indices.contains(setIndex), let done = completions[setIndex] else { return [] }
        let previous = completions[..<setIndex].compactMap { $0 }.max() ?? -.infinity
        let grace = 5.0   // a clip started a moment before the previous set's tap still belongs to the next set
        return clips.filter { $0.offsetSec > previous - grace && $0.offsetSec <= done + grace }.map(\.id)
    }
}
