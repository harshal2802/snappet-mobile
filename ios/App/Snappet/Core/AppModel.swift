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
    /// `true` when the on-disk SwiftData store failed to open and the app is running on an empty
    /// in-memory container. Set once in `SnappetApp.init()` before any view renders; never mutated
    /// again. The `FallbackStoreBanner` in `RootShell` reads this to show the persistent warning.
    var isUsingFallbackStore: Bool = false
    /// Current Photo Library access. `.limited` means we can't auto-scan the library
    /// and must fall back to a manual picker (#60 §C).
    var photoAccess: PHAuthorizationStatus = .notDetermined
    var photosLimited: Bool { photoAccess == .limited }

    let health = HealthKitService()
    let photos = PhotoLibraryService()
    /// WorkoutTracker session-scoped media tagging (B1): auto-discovery by capture-time
    /// window + manual PHPicker add. Distinct from `photos`, the flagship reels path.
    let sessionMedia = SessionMediaService()
    /// On-device CapCut-style clip editor render engine (B3): turns a non-destructive
    /// `ClipEdit` + its source PHAsset into a playable/exportable `AVMutableComposition` +
    /// `AVMutableVideoComposition` (trim/split, crop/aspect, text overlays, speed, mute).
    /// Reuses `ReelExporter`'s composition-sharing + PHAsset-resolve patterns.
    let videoStudio = VideoStudio()
    let feedback = FeedbackStore()      // FeedbackSink → disk (training data)

    /// The user's on-device HR profile (age / resting / max / weight / sex), shared by **both** apps
    /// (WorkoutTracker + Kilter) so personalized zones, `%HRR`, effort, and the HR-based calorie
    /// estimate are computed off one source of truth. Empty until the user fills it in Settings →
    /// then `resolvedMaxHR` replaces the fixed `HeartRateZone.defaultMaxHR` (fitness-band Phase 2).
    let userProfile = UserProfileStore()

    /// Live workout metrics for WorkoutTracker, behind a pluggable `MetricsSource` (A3).
    /// The coordinator holds an Apple-Watch source (A1, `WCSession`) **and** a generic BLE
    /// heart-rate-band source (`0x180D`/`0x2A37`, CoreBluetooth) and forwards the active
    /// one — HR can come from either, picked in `WorkoutSettingsView`. The property keeps
    /// its A1 name so A2/A4 call sites don't churn. Distinct from `health`, which is the
    /// post-hoc (completed-workout) path.
    let liveWorkout = LiveMetricsCoordinator()

    /// Drives the WorkoutTracker **Live Activity** (Lock Screen + Dynamic Island): overall
    /// timer + live HR + current exercise. Started/ended alongside `liveWorkout` from the
    /// session lifecycle in `WorkoutHomeView`; updated as HR/exercise change. No-ops where
    /// ActivityKit/Live Activities are unavailable or unauthorized (live-workout-studio A2).
    let liveActivity = LiveActivityController()

    /// Drives the **Kilter climbing-session Live Activity** (Lock Screen + Dynamic Island):
    /// overall timer + live HR + current climb. Started/ended alongside `liveWorkout` from the
    /// Kilter session lifecycle (`KilterSessionManager`). A dedicated controller (not the workout
    /// one) so the two activity types stay separate (decisions.md 2026-06-06). No-ops where
    /// ActivityKit/Live Activities are unavailable or unauthorized.
    let kilterLiveActivity = KilterLiveActivityController()

    /// Tracks the **active Kilter board session** (grouping, per-climb timing, live HR + Live Activity).
    /// Owned here — not as `@State` on `KilterRootView` — so it survives navigating out of and back into
    /// the Kilter module (the root is a `navigationDestination` that SwiftUI destroys on pop); combined
    /// with `recover(in:)` on appear/relaunch, the persisted open session never goes stale. Bound to the
    /// live services once, in `KilterRootView.onAppear`.
    let kilterSessions = KilterSessionManager()

    /// Local notifications for a backgrounded / minimized workout (e.g. "rest complete"), so the
    /// session can still reach the notification bar alongside the Live Activity. No-ops when
    /// unauthorized (live-workout-studio next pass).
    let workoutNotifications = WorkoutNotifications()

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
            // Uncapped: reels keep every featured clip. Paired with the `.fullLength()` config the
            // reel paths pass to `generate`, clips also play in full (no per-clip trim) — the user
            // didn't want a length limit on session videos (decisions.md 2026-06-05).
            planner: ReelPlanner(targetDuration: nil),
            feedback: feedback
        )
    }

    /// The engine variant that **boosts achievement windows** (fitness-band Phase 4): sent-climb
    /// windows (Kilter) / peak-effort set windows (WorkoutTracker), in seconds from session start, so
    /// the auto-reel features the achievement, not just the raw HR peak. Empty `windows` ⇒ the
    /// effort term is 0 everywhere ⇒ identical to `engine` (HR-only) — the gated, no-change default.
    func engine(boosting windows: [ClosedRange<Double>]) -> HighlightEngine {
        HighlightEngine(
            selector: FusionSelector.effortAligned(windows: windows),
            planner: ReelPlanner(targetDuration: nil),
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
