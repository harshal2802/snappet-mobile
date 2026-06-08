import Foundation
import HighlightEngine

/// Builds a `HighlightEngine.Workout` from a Kilter climbing session + its tagged media, so the
/// **same** highlight pipeline that powers WorkoutTracker reels can score a climbing session's video
/// (HR-driven, `Activity.climbing` preset). Pure value-mapping — no SwiftData, no platform I/O — so
/// it is unit-testable in `SnappetTests` with synthetic inputs (mirrors `AppModel.buildWorkout`, but
/// fed from a `KilterSession` instead of a `WorkoutSummary`).
enum KilterWorkoutBuilder {

    /// A plain-value view of a tagged clip, so the mapping doesn't touch the `SessionMedia` @Model.
    struct Clip: Sendable, Equatable {
        var localIdentifier: String
        var isVideo: Bool
        var offsetSec: Double
        var durationSec: Double?
    }

    /// Assemble the engine input. `hr` is the session's persisted `HRPoint` series (already on the
    /// session timeline); `media` is the tagged clips. `duration` is the session length. Photos get a
    /// zero duration (the engine treats a photo as an instant at its `offsetSec`), like the workout
    /// media path.
    static func workout(hr: [HRPoint], duration: TimeInterval,
                        maxHR: Double?, restHR: Double?, clips: [Clip]) -> Workout {
        Workout(
            activity: .climbing,
            duration: max(0, duration),
            hr: hr.map { HRSample(t: $0.t, bpm: $0.bpm) },
            restBpm: restHR,
            maxBpm: maxHR,
            media: clips.map {
                MediaItem(id: $0.localIdentifier,
                          kind: $0.isVideo ? .video : .photo,
                          startOffset: max(0, $0.offsetSec),
                          duration: $0.isVideo ? ($0.durationSec ?? 0) : 0)
            })
    }
}

extension KilterWorkoutBuilder.Clip {
    /// Map a `SessionMedia` row (keyed to a `KilterSession`) to a builder clip.
    static func from(_ media: SessionMedia) -> KilterWorkoutBuilder.Clip {
        KilterWorkoutBuilder.Clip(
            localIdentifier: media.localIdentifier,
            isVideo: media.kind == .video,
            offsetSec: media.offsetSec,
            durationSec: media.durationSec)
    }
}

extension KilterWorkoutBuilder {
    /// Convenience: build directly from a session + its media rows.
    static func workout(for session: KilterSession, media: [SessionMedia]) -> Workout {
        workout(hr: session.hrSeries, duration: session.duration,
                maxHR: session.maxHR, restHR: session.restHR,
                clips: media.map(Clip.from))
    }
}

extension ReelSource {
    /// A reel source for a Kilter climbing session — feeds the shared `ReelView` (preview / pin /
    /// remove / reorder / export) the same way a workout does, built from the session + its tagged
    /// media via `KilterWorkoutBuilder`. The workout is a pure snapshot, so `makeWorkout` ignores the
    /// `AppModel` and manual-media args.
    static func kilterSession(_ session: KilterSession, media: [SessionMedia],
                              logs: [KilterClimbLog] = []) -> ReelSource {
        // Snapshot Sendable values now — the @Model `session`/`media` aren't Sendable and must not be
        // captured into `makeWorkout` (a `@MainActor` escaping closure → Swift-6 data-race error).
        let hr = session.hrSeries, duration = session.duration
        let maxHR = session.maxHR, restHR = session.restHR
        let baseClips = media.map(KilterWorkoutBuilder.Clip.from)
        // Boost sent-climb windows so the auto-reel features the SENDS, not just raw HR peaks (Phase 4).
        let sentWindows = KilterSessionStats.sentClimbWindows(from: logs, start: session.startedAt)
        var source = ReelSource(id: session.id.uuidString, activity: .climbing,
                          title: "Climbing reel", start: session.startedAt,
                          makeWorkout: { _, manual in
                              // `manual` (the limited-Photos picker) overrides the auto-tagged media so
                              // "Select clips" actually works for a Kilter reel; otherwise the session's clips.
                              let clips = manual.map { items in
                                  items.map { item in
                                      KilterWorkoutBuilder.Clip(
                                          localIdentifier: item.id, isVideo: item.kind == .video,
                                          offsetSec: item.startOffset,
                                          durationSec: item.kind == .video ? item.duration : nil)
                                  }
                              } ?? baseClips
                              return KilterWorkoutBuilder.workout(
                                  hr: hr, duration: duration, maxHR: maxHR, restHR: restHR, clips: clips)
                          })
        source.boostWindows = sentWindows
        return source
    }
}

/// Pure grouping of a session's tagged media by climb — the data behind the per-climb galleries.
/// Pure (plain values in/out) so it is unit-testable without SwiftData.
enum KilterMediaGrouping {
    /// Clips assigned to a given climb, in capture order.
    static func clips<M>(for climbUUID: String, in media: [M], climbUUIDOf: (M) -> String?,
                         offsetOf: (M) -> Double) -> [M] {
        media.filter { climbUUIDOf($0) == climbUUID }.sorted { offsetOf($0) < offsetOf($1) }
    }
    /// Clips not assigned to any climb (the General bucket), in capture order.
    static func unassigned<M>(in media: [M], climbUUIDOf: (M) -> String?,
                              offsetOf: (M) -> Double) -> [M] {
        media.filter { climbUUIDOf($0) == nil }.sorted { offsetOf($0) < offsetOf($1) }
    }
}

/// Pure clip→climb assignment: map a clip's session-relative offset to the climb whose in-session
/// time window contains it (the climbing analogue of `SessionMediaAssignment`'s set windows).
/// Unit-testable without SwiftData/Photos.
enum KilterMediaAssignment {
    /// A climb's `[startOffset, endOffset]` window, in seconds from the session start.
    struct ClimbWindow: Sendable, Equatable {
        var climbUUID: String
        var startOffset: Double
        var endOffset: Double
    }

    /// The climb whose window contains `offsetSec`. When windows overlap, the **last** (most recent)
    /// match wins; `nil` when the clip falls in no climb's window — it lands in the General bucket.
    static func climbUUID(forOffset offsetSec: Double, windows: [ClimbWindow]) -> String? {
        windows.last { offsetSec >= $0.startOffset && offsetSec <= $0.endOffset }?.climbUUID
    }
}
