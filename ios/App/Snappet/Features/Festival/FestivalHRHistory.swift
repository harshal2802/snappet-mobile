import Foundation

/// Your per-artist heart-rate history — the strongest signal the `SetRecommender` ranks by
/// (festival prompt 04). The raw material is prompt 02's `FestivalAttendance` stretches, which
/// already record *which artist you danced to, when, and on which dance `WorkoutSession`*. The thin
/// edge (`FestivalHistoryService`) slices each stretch's HR out of the session series and hands this
/// type plain value `Sample`s; aggregation is pure Foundation so the ranking unit-tests without a
/// simulator (the repo's pure-logic-at-a-thin-edge rule).
///
/// Deliberately re-derived from prompt 02's data rather than depending on prompt 03's
/// `FestivalSetStats` (which computes per-set HR but isn't on `main` yet) — attendance + session HR
/// is all the recommender needs, and it works cross-festival (an artist you danced to at one
/// festival informs a suggestion at another, keyed by normalized artist name).
struct FestivalHRHistory: Sendable, Equatable {

    /// One danced set from your past: an artist you were on the floor for, and the HR you hit.
    struct Sample: Sendable, Equatable {
        var artist: String
        var festivalName: String
        var date: Date
        var peakBPM: Int
        var avgBPM: Int
        var dancedSeconds: TimeInterval
    }

    /// Aggregated affinity for one artist across every festival you danced to them.
    struct Affinity: Sendable, Equatable {
        /// Display spelling (the most recent sample's).
        var artist: String
        /// Best peak across all your sessions to this artist.
        var peakBPM: Int
        /// Danced-seconds-weighted average BPM.
        var avgBPM: Int
        var dancedSeconds: TimeInterval
        var sessionCount: Int
        /// Most recent festival you danced to them at (the "at Coachella '26" clause).
        var lastFestival: String
        var lastDate: Date
    }

    /// Normalized-artist → affinity.
    private(set) var byArtist: [String: Affinity]
    /// The strongest peak you've ever hit dancing — the festival-wide prior for artists you've
    /// never logged (a mild "you dance hard" signal, never as strong as a real match).
    let overallPeakBPM: Int
    /// Danced-seconds-weighted average BPM across all history.
    let overallAvgBPM: Int

    init(samples: [Sample]) {
        var groups: [String: [Sample]] = [:]
        for s in samples where !s.artist.trimmingCharacters(in: .whitespaces).isEmpty {
            groups[Self.normalize(s.artist), default: []].append(s)
        }
        byArtist = groups.mapValues { group in
            let latest = group.max { $0.date < $1.date }!
            return Affinity(artist: latest.artist,
                            peakBPM: group.map(\.peakBPM).max() ?? 0,
                            avgBPM: Self.weightedAverage(group),
                            dancedSeconds: group.reduce(0) { $0 + $1.dancedSeconds },
                            sessionCount: group.count,
                            lastFestival: latest.festivalName,
                            lastDate: latest.date)
        }
        overallPeakBPM = samples.map(\.peakBPM).max() ?? 0
        overallAvgBPM = Self.weightedAverage(samples)
    }

    /// Your affinity for `artist` (case / whitespace-insensitive), or nil if you've never logged
    /// dancing to them.
    func affinity(for artist: String) -> Affinity? { byArtist[Self.normalize(artist)] }

    var isEmpty: Bool { byArtist.isEmpty }

    // MARK: Pure slicing (the thin edge feeds raw HR; this stays testable)

    /// Build one `Sample` from a session's HR series and an attendance window. `hrPoints` are
    /// `(t, bpm)` where `t` is the offset in seconds from `sessionStart` (the `HRPoint` shape); only
    /// points whose absolute instant falls inside `window` count. Returns nil when no HR landed in
    /// the window (a claimed set the watch wasn't on for), so no-signal stretches don't dilute an
    /// average with zeros.
    static func sample(artist: String, festivalName: String, window: DateInterval,
                       sessionStart: Date, hrPoints: [(t: Double, bpm: Double)]) -> Sample? {
        let inside = hrPoints.filter {
            let at = sessionStart.addingTimeInterval($0.t)
            return window.contains(at)
        }
        guard !inside.isEmpty else { return nil }
        let peak = Int(inside.map(\.bpm).max()!.rounded())
        let avg = Int((inside.map(\.bpm).reduce(0, +) / Double(inside.count)).rounded())
        return Sample(artist: artist, festivalName: festivalName, date: window.start,
                      peakBPM: peak, avgBPM: avg, dancedSeconds: window.duration)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func weightedAverage(_ samples: [Sample]) -> Int {
        let totalWeight = samples.reduce(0.0) { $0 + max(1, $1.dancedSeconds) }
        guard totalWeight > 0 else { return 0 }
        let weighted = samples.reduce(0.0) { $0 + Double($1.avgBPM) * max(1, $1.dancedSeconds) }
        return Int((weighted / totalWeight).rounded())
    }
}
