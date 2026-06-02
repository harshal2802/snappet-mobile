import Foundation
import HighlightEngine

/// The **pure** WorkoutTracker → `HighlightEngine` bridge (B4): turns a finished session's
/// data — its live HR series (B2 `hrSeries`), its tagged video/photo clips (B1 `SessionMedia`),
/// and the routine's sport/category — into a platform-free engine `Workout`, plus the user's
/// clip selection into engine `pinnedIds`.
///
/// This is *the* connection from the set-logger to the proven flagship algorithm. It is kept a
/// pure value-mapping (plain values in / plain values out, no SwiftData `@Model`, no AVFoundation,
/// no Photos) so it is unit-testable with **no device** — exactly the layering rule that keeps
/// `HighlightEngine` platform-free (conventions.md). The engine itself is reused **UNCHANGED**:
/// `AppModel.engine` runs the existing `HighlightSelector` pipeline → `[Highlight]`, then
/// `ReelPlanner.plan(…pinnedIds:)` builds the `ReelPlan` that `ReelExporter` renders.
///
/// Mapping rules (decisions.md 2026-06-01, B4):
/// - **HR**: `HRPoint` → `HRSample` 1:1 (same `t`/`bpm`, same `startedAt`-relative timeline).
/// - **Media**: each `SessionMedia` → `MediaItem` (`id = localIdentifier`, `startOffset =
///   offsetSec`). A **video** maps to `.video` with its `durationSec`; a clip with no resolvable
///   duration is **skipped** gracefully (the engine can't window a zero-length video). A **photo**
///   maps to `.photo` with duration `0` (the engine/`ReelExporter` render photo stills via
///   Ken-Burns).
/// - **Activity**: the routine's `SportTag` (stronger signal) then dominant `ExerciseCategory` →
///   the engine's coarse `Activity`, defaulting to `.strength` for a generic gym routine. (Mirrors
///   the *direction* of the live `WorkoutActivityMapping`, but targets the engine's `Activity`
///   rather than `HKWorkoutActivityType` — the engine stays platform-free.)
/// - **Selection** → **`pinnedIds`**: the user's explicitly-selected clip ids become the planner's
///   budget-exempt pins (the 2026-05-30 pin decision), so a hand-picked clip is always kept.
enum SessionHighlightInput {

    /// Default seconds to assume for a tagged video whose `durationSec` is `nil` but present
    /// (rare — auto-discovery records it; a manual add without metadata may not). Kept small so a
    /// guessed clip can't dominate the reel budget. A clip with neither a duration nor a default
    /// would be windowless, so callers that want strict behavior can pass `nil` to skip instead.
    static let defaultVideoDuration: Double = 6

    /// A plain-value description of one tagged clip — the bridge input, decoupled from the
    /// `SessionMedia` `@Model` so this type never touches SwiftData and is trivially testable.
    /// Built on the `@MainActor` caller from a `SessionMedia` via `init(_:)`.
    struct Clip: Sendable, Equatable {
        let localIdentifier: String
        let isVideo: Bool
        let offsetSec: Double
        /// Source duration in seconds; `nil` for photos or an unresolved video.
        let durationSec: Double?

        init(localIdentifier: String, isVideo: Bool, offsetSec: Double, durationSec: Double?) {
            self.localIdentifier = localIdentifier
            self.isVideo = isVideo
            self.offsetSec = offsetSec
            self.durationSec = durationSec
        }
    }

    // MARK: - HR mapping

    /// `HRPoint`s → engine `HRSample`s, 1:1 on the same `startedAt`-relative timeline.
    static func hrSamples(from series: [HRPoint]) -> [HRSample] {
        series.map { HRSample(t: $0.t, bpm: $0.bpm) }
    }

    // MARK: - Media mapping

    /// One `Clip` → an engine `MediaItem`, or `nil` when a video has no resolvable duration and
    /// `defaultVideoDuration` is `nil` (a windowless clip the engine can't use — skip it).
    /// Photos map to `.photo` with duration `0` (Ken-Burns still). `startOffset` is clamped ≥ 0.
    static func mediaItem(from clip: Clip,
                          defaultDuration: Double? = defaultVideoDuration) -> MediaItem? {
        let start = max(0, clip.offsetSec)
        if clip.isVideo {
            guard let dur = clip.durationSec ?? defaultDuration, dur > 0 else { return nil }
            return MediaItem(id: clip.localIdentifier, kind: .video,
                             startOffset: start, duration: dur)
        } else {
            return MediaItem(id: clip.localIdentifier, kind: .photo,
                             startOffset: start, duration: 0)
        }
    }

    /// Map a set of tagged clips to engine media, dropping the ones with no resolvable duration.
    static func mediaItems(from clips: [Clip],
                           defaultDuration: Double? = defaultVideoDuration) -> [MediaItem] {
        clips.compactMap { mediaItem(from: $0, defaultDuration: defaultDuration) }
    }

    // MARK: - Activity mapping

    /// Routine sport/category → the engine's coarse `Activity`. Sport is the stronger signal (an
    /// explicit per-routine label); a `.general` sport falls through to the dominant category;
    /// a routine with neither is a generic gym session → `.strength`.
    static func activity(sport: SportTag?, category: ExerciseCategory?) -> Activity {
        if let sport {
            switch sport {
            case .climbing: return .climbing
            case .calisthenics: return .strength
            case .general: break   // fall through to category
            }
        }
        if let category {
            switch category {
            case .strength, .powerlifting, .olympicWeightlifting, .strongman: return .strength
            case .cardio: return .running   // closest engine bucket for a cardio routine
            case .plyometrics: return .other
            case .stretching: return .other
            }
        }
        return .strength
    }

    // MARK: - Workout assembly

    /// Build the engine `Workout` from a session's HR + tagged clips + routine activity. Pure:
    /// the caller snapshots the `@Model`s into `[HRPoint]` / `[Clip]` on the `@MainActor` first.
    /// `duration` is the session duration in seconds. Clips with no resolvable duration are
    /// dropped (see `mediaItem`).
    static func makeWorkout(hrSeries: [HRPoint], clips: [Clip], duration: Double,
                            sport: SportTag?, category: ExerciseCategory?,
                            defaultDuration: Double? = defaultVideoDuration) -> Workout {
        Workout(
            activity: activity(sport: sport, category: category),
            duration: max(0, duration),
            hr: hrSamples(from: hrSeries),
            media: mediaItems(from: clips, defaultDuration: defaultDuration)
        )
    }

    // MARK: - Selection → pinnedIds

    /// The user's selected clips → planner `pinnedIds` (their PHAsset `localIdentifier`s, which are
    /// the engine `MediaItem.id`s). A selected clip that was dropped for having no duration is
    /// silently absent from the media, so a stray pin id is harmless to the planner.
    static func pinnedIds(forSelected selected: [Clip]) -> Set<String> {
        Set(selected.map(\.localIdentifier))
    }
}
