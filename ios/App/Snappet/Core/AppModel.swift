import Foundation
import Observation
import Photos
import HighlightEngine

/// App-wide state + the single place the engine and services are wired together.
/// Swapping the selector (HR → fusion) or config is a one-line change here.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case onboarding, loading, ready, error(String) }

    var phase: Phase = .loading
    var workouts: [WorkoutSummary] = []
    /// Current Photo Library access. `.limited` means we can't auto-scan the library
    /// and must fall back to a manual picker (#60 §C).
    var photoAccess: PHAuthorizationStatus = .notDetermined
    var photosLimited: Bool { photoAccess == .limited }

    let health = HealthKitService()
    let photos = PhotoLibraryService()
    let feedback = FeedbackStore()      // FeedbackSink → disk (training data)

    /// Live workout metrics relay (Apple Watch companion → phone over WCSession).
    /// The single meeting point for WorkoutTracker's *live* HR path; shaped so A3 can
    /// swap in a BLE source behind a `MetricsSource` protocol without changing call
    /// sites. Distinct from `health`, which is the post-hoc (completed-workout) path.
    let liveWorkout = LiveWorkoutService()

    /// Drives the WorkoutTracker **Live Activity** (Lock Screen + Dynamic Island): overall
    /// timer + live HR + current exercise. Started/ended alongside `liveWorkout` from the
    /// session lifecycle in `WorkoutHomeView`; updated as HR/exercise change. No-ops where
    /// ActivityKit/Live Activities are unavailable or unauthorized (live-workout-studio A2).
    let liveActivity = LiveActivityController()

    /// Value-first onboarding is shown until the user has been through it once.
    /// (HealthKit read-auth status isn't queryable, so we gate on a persisted flag.)
    private let onboardedKey = "snappet.hasOnboarded"
    private var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: onboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardedKey) }
    }

    /// The active engine. Default = best-guess HR selector + per-activity presets.
    /// Later: `FusionSelector.hrLeaning(scene:)` once a vision pipeline exists.
    /// Computed (HighlightEngine is a cheap Sendable value) so callers get a copy —
    /// no stored main-actor property to trip Swift 6 isolation across the view layer.
    var engine: HighlightEngine {
        HighlightEngine(
            selector: HRHighlightSelector(),
            planner: ReelPlanner(targetDuration: 30),
            feedback: feedback
        )
    }

    /// Launch entry point. First-time users see value-first onboarding; returning
    /// users go straight to loading their workouts.
    func start() async {
        photoAccess = photos.currentStatus
        if hasOnboarded {
            await bootstrap()
        } else {
            phase = .onboarding
        }
    }

    /// Called from the onboarding screen's explicit "Connect" tap — value-first,
    /// just-in-time permissions (#60 §C). Requests Health, then Photos, then loads.
    func completeOnboarding() async {
        hasOnboarded = true
        photoAccess = await photos.requestAccess()
        await bootstrap()
    }

    func bootstrap() async {
        phase = .loading
        do {
            try await health.requestAuthorization()
            photoAccess = photos.currentStatus
            phase = .ready
            await refreshWorkouts()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func refreshWorkouts() async {
        do { workouts = try await health.recentWorkouts(limit: 40) }
        catch { phase = .error(error.localizedDescription) }
    }

    /// Build the engine input for a workout: pull its HR series + the media for the
    /// session. By default media is auto-discovered by time window; pass
    /// `manualMedia` (from the `.limited`-access picker) to use a hand-picked set.
    func buildWorkout(_ summary: WorkoutSummary, manualMedia: [MediaItem]? = nil) async throws -> Workout {
        let hr = try await health.heartRateSamples(for: summary)
        let media: [MediaItem]
        if let manualMedia {
            media = manualMedia
        } else {
            media = try await photos.media(in: summary.dateInterval, workoutStart: summary.start)
        }
        return Workout(
            activity: summary.activity,
            duration: summary.duration,
            hr: hr,
            restBpm: summary.restingBpm,
            maxBpm: summary.maxBpm,
            media: media
        )
    }

    /// Map manually-picked asset identifiers (limited-access fallback) to engine media.
    func media(forIdentifiers ids: [String], workoutStart: Date) -> [MediaItem] {
        photos.media(forIdentifiers: ids, workoutStart: workoutStart)
    }

    /// Assemble a reel plan from chosen highlights (keeps engine access on the main actor).
    /// `pinnedIds` force-include user-kept moments; `order` applies a manual reel order.
    func reelPlan(for highlights: [Highlight], media: [MediaItem],
                  pinnedIds: Set<String> = [], order: [String]? = nil) -> ReelPlan {
        engine.planner.plan(highlights: highlights, media: media, pinnedIds: pinnedIds, order: order)
    }
}
