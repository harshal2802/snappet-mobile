import Foundation
import HighlightEngine

// MARK: - Festival reels through the ONE shared ReelView (festival prompt 03)
//
// A festival set — or the whole festival — becomes a reel seed exactly the way gym and Kilter
// sessions do (highlights convergence): snapshot Sendable values up front, build the engine
// `Workout` in `makeWorkout`, hand `ReelView` the source. No new player/editor surface.

extension ReelSource {

    /// A reel of ONE set (frame 6's "✦ Make a reel of this set"): the dance session's HR + the
    /// set's TAGGED clips, with the set's window as the boost window so the engine favors moments
    /// at the drop. Posts back into Clips titled "Artist · Stage" — the same title the set's
    /// clip post carries, so search matches the artist on the reel too.
    static func festivalSet(_ set: FestivalSet,
                            session: FestivalSessionSnapshot,
                            clips: [SessionHighlightInput.Clip],
                            now: Date = .now) -> ReelSource {
        let hr = session.hrSeries
        let duration = session.interval(now: now).duration
        let boost = boostWindow(for: set, session: session, now: now)
        var source = ReelSource(
            id: "festival-set-\(set.id.uuidString)",
            activity: .dance,
            title: "Set reel",
            start: session.startedAt,
            makeWorkout: { _, manual in
                let effective = manual.map { items in
                    items.map { item in
                        SessionHighlightInput.Clip(localIdentifier: item.id,
                                                   isVideo: item.kind == .video,
                                                   offsetSec: item.startOffset,
                                                   durationSec: item.kind == .video ? item.duration : nil)
                    }
                } ?? clips
                return Workout(activity: .dance,
                               duration: max(0, duration),
                               hr: SessionHighlightInput.hrSamples(from: hr),
                               restBpm: session.restHR, maxBpm: session.maxHR,
                               media: SessionHighlightInput.mediaItems(from: effective))
            })
        if let boost { source.boostWindows = [boost] }
        source.postSessionID = session.id
        source.postTitle = "\(set.artist) · \(set.stage)"
        return source
    }

    /// The whole weekend as ONE montage ("✦ Make my festival reel", frame 11): every dance session
    /// of the pack stitched onto one timeline via the Weekly-Highlights machinery (reused, not
    /// re-implemented), cut with trimmed highlight windows, attended-set windows boosted. Posts
    /// under the latest session as "<Festival> — Highlights". `nil` when nothing usable was filmed.
    static func festival(named name: String, packID: String,
                         sessions: [FestivalSessionSnapshot],
                         clipsBySession: [UUID: [SessionHighlightInput.Clip]],
                         attendance: [FestivalAttendanceSnapshot],
                         pack: FestivalPack,
                         now: Date = .now) -> ReelSource? {
        let inputs: [WeeklyHighlights.SessionInput] = sessions.compactMap { session in
            guard let clips = clipsBySession[session.id], !clips.isEmpty else { return nil }
            let boosts = attendance
                .filter { $0.sessionID == session.id }
                .compactMap { row -> ClosedRange<Double>? in
                    guard let set = pack.setsByID[row.setID] else { return nil }
                    return boostWindow(for: set, session: session, now: now)
                }
            return WeeklyHighlights.SessionInput(
                id: session.id, title: name, startedAt: session.startedAt,
                duration: session.interval(now: now).duration,
                hrSeries: session.hrSeries, maxHR: session.maxHR, restHR: session.restHR,
                clips: clips, isClimbing: false, boostWindows: boosts)
        }
        guard let stitched = WeeklyHighlights.stitchedWorkout(sessions: inputs),
              let latest = inputs.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        var source = ReelSource(
            id: "festival-\(packID)",
            activity: .dance,
            title: "Festival reel",
            start: inputs.map(\.startedAt).min() ?? now,
            // The stitched snapshot IS the input — manual picks don't apply to a weekend cut.
            makeWorkout: { _, _ in
                Workout(activity: .dance, duration: stitched.workout.duration,
                        hr: stitched.workout.hr, restBpm: stitched.workout.restBpm,
                        maxBpm: stitched.workout.maxBpm, media: stitched.workout.media)
            })
        source.boostWindows = stitched.boostWindows
        source.trimToHighlights = true
        source.postSessionID = latest.id
        source.postTitle = "\(name) — Highlights"
        return source
    }

    /// The set's absolute window ∩ the session's coverage, in session-relative seconds — what the
    /// planner boosts. `nil` when they never overlapped (a set tagged from footage alone).
    private static func boostWindow(for set: FestivalSet, session: FestivalSessionSnapshot,
                                    now: Date) -> ClosedRange<Double>? {
        guard let overlap = session.interval(now: now).intersection(with: set.window),
              overlap.duration > 0 else { return nil }
        let start = overlap.start.timeIntervalSince(session.startedAt)
        return start...(start + overlap.duration)
    }
}
