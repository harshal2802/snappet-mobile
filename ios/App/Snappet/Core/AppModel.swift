import Foundation
import Observation
import Photos
import OSLog
import HighlightEngine

private let tuningLog = Logger(subsystem: "com.snappet.app", category: "FeedbackReplay")

/// App-wide state + the single place the engine and services are wired together.
/// Swapping the selector (HR → fusion) or config is a one-line change here.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case onboarding, loading, ready, error(String) }

    var phase: Phase = .loading
    var workouts: [WorkoutSummary] = []
    /// True while `refreshWorkouts()` is in flight — the workout list's empty overlay swaps its
    /// "may not have permission" copy for a spinner during a fetch, so an in-flight load never
    /// reads as a permission problem (issue #72 pre-merge review fix).
    private(set) var refreshing = false
    /// Current Photo Library access. `.limited` means we can't auto-scan the library
    /// and must fall back to a manual picker (#60 §C).
    var photoAccess: PHAuthorizationStatus = .notDetermined
    var photosLimited: Bool { photoAccess == .limited }

    let health = HealthKitService()
    let photos = PhotoLibraryService()
    /// WorkoutTracker session-scoped media tagging (B1): auto-discovery by capture-time
    /// window + manual PHPicker add. Distinct from `photos`, the flagship reels path.
    let sessionMedia = SessionMediaService()
    let feedback = FeedbackStore()      // FeedbackSink → disk (training data)
    /// On-device Vision scene scorer (#83 Step 1): saliency + sharpness + face/body presence per sampled
    /// frame → a scalar `visualScore` for the fusion's scene term. Platform I/O lives here; only the
    /// scalar crosses into the engine.
    let sceneScorer = SceneScorer()

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
    /// live services once, in `init` below — NOT in `KilterRootView.onAppear`, because deep links can
    /// land past the root (Home's "Plan tonight's session" → `KilterPlanView`) and a session started
    /// there must never run unbound (no live HR / Live Activity / media) (#71 pre-merge review).
    let kilterSessions = KilterSessionManager()

    /// Local notifications for a backgrounded / minimized workout (e.g. "rest complete"), so the
    /// session can still reach the notification bar alongside the Live Activity. No-ops when
    /// unauthorized (live-workout-studio next pass).
    let workoutNotifications = WorkoutNotifications()

    /// The Pomodoro countdown engine. Owned here — not as `@State` on `PomodoroRootView` —
    /// so popping back to the Apps grid no longer kills a running focus session (the same
    /// stale-on-pop fix as `kilterSessions`, issue #70). The view still wires its
    /// store-dependent `onFocusCompleted` on appear.
    let pomodoro = PomodoroTimer()
    /// Phase-end alerts for a backgrounded / locked phone (scheduled at phase start,
    /// cancelled on pause/reset) + the Lock Screen / Dynamic Island countdown. Driven
    /// entirely off `pomodoro.onScheduleChanged` in `init` so they can't drift from the timer.
    let pomodoroNotifications = PomodoroNotifications()
    let pomodoroLiveActivity = PomodoroLiveActivityController()
    /// Whether `PomodoroRootView` is on screen — hides the App Library's "focus running"
    /// re-entry chip while the user is already looking at the timer.
    var pomodoroScreenVisible = false

    /// Whether any Kilter module screen is on screen (the root stays in the nav stack while deeper
    /// Kilter screens are pushed) — hides the App Library's Kilter "session running" re-entry chip
    /// while the user is already inside Kilter (where the in-module session bar / plan-home own the
    /// lifecycle). Set by `KilterRootView` on appear/disappear, mirroring `pomodoroScreenVisible`.
    var kilterScreenVisible = false

    init() {
        // Wire the Kilter session manager to its sibling live services HERE, where all four are
        // constructed — not in a view's `onAppear` — so binding can't depend on appear order:
        // every path that can start a session (root entry, the Home plan deep link, future QR
        // links) gets live HR + the Live Activity + media discovery (#71 pre-merge review).
        kilterSessions.bind(liveWorkout: liveWorkout,
                            liveActivity: kilterLiveActivity,
                            media: sessionMedia,
                            userProfile: userProfile)

        // Capture the services (not self), and the timer weakly — the closure is stored on
        // the timer itself, so a strong capture would be a retain cycle.
        pomodoro.onScheduleChanged = { [pomodoroNotifications, pomodoroLiveActivity, weak pomodoro] phase, endDate in
            if let endDate, let pomodoro {
                // Two boundaries stay scheduled (this phase's end + the next phase's end):
                // the app can't schedule while suspended, so a phone locked through a whole
                // focus block still gets the "break's over" alert that follows it.
                let nextPhase: PomodoroPhase = phase == .focus ? .breakTime : .focus
                let nextLength = TimeInterval((phase == .focus ? pomodoro.breakMinutes : pomodoro.focusMinutes) * 60)
                pomodoroNotifications.scheduleBoundaries([
                    (phase, endDate),
                    (nextPhase, endDate.addingTimeInterval(nextLength)),
                ])
                pomodoroLiveActivity.sync(isFocus: phase == .focus, endDate: endDate,
                                          phaseSeconds: pomodoro.phaseDuration)
            } else {
                pomodoroNotifications.clear()
                pomodoroLiveActivity.end()
            }
        }

        // Relaunch after termination mid-session: the Lock Screen may still hold a live,
        // correct countdown (the OS owns it). Re-attach and rebuild the timer from its
        // absolute end while the phase is still ahead; past the end, clean up the orphan
        // (the elapsed focus can't be retro-logged — the store isn't reachable here).
        if let orphan = pomodoroLiveActivity.adoptRunning() {
            if orphan.endDate.timeIntervalSinceNow > 0 {
                pomodoro.restore(phase: orphan.isFocus ? .focus : .breakTime, endDate: orphan.endDate)
            } else {
                pomodoroLiveActivity.end()
                pomodoroNotifications.clear()
            }
        }
    }

    /// Value-first onboarding is shown until the user has been through it once.
    /// (HealthKit read-auth status isn't queryable, so we gate on a persisted flag.)
    private let onboardedKey = "snappet.hasOnboarded"
    private var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: onboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardedKey) }
    }

    /// Replay-derived fusion weighting, recomputed on bootstrap from the user's OWN
    /// `highlight-feedback.jsonl` (`FeedbackStore.exportAll()` — its first caller). `nil` until enough
    /// endorsed feedback exists, so the blend changes ONLY from replayed data, never from intuition
    /// (project.md invariant). Consumed by the scene fusion once a real vision signal exists (#83 Step 1).
    private(set) var feedbackTuning: FeedbackReplay.TunedWeighting?

    /// Re-run the offline tuner ON DEVICE over the local feedback log: read every logged event, replay
    /// it into per-config stats, and derive the data-driven weighting. Pure engine logic (`FeedbackReplay`,
    /// parity-tested vs the Python harness); this method is the thin on-device I/O edge.
    func recomputeFeedbackTuning() {
        let stats = FeedbackReplay.replay(feedback.exportAll())
        guard !stats.isEmpty else { return }
        feedbackTuning = FeedbackReplay.tunedWeighting(from: stats)
        tuningLog.info("On-device feedback replay: \(FeedbackReplay.recommend(stats), privacy: .public)")
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
    /// `scene` carries the real Vision visual scores (#83 Step 1). The scene term is added to the fusion
    /// ONLY when `feedbackTuning` exists — i.e. once the user's replayed feedback justifies a weighting
    /// (project.md: weights change only from replayed feedback). Without tuning the blend is exactly
    /// today's HR + effort, so adding the seam is a no-op until the data earns it.
    func engine(boosting windows: [ClosedRange<Double>],
                scene: SceneHighlightSelector = SceneHighlightSelector()) -> HighlightEngine {
        var parts: [(any HighlightSelector, Double)] = [
            (HRHighlightSelector(), feedbackTuning?.hrWeight ?? 0.6),
            (EffortAlignedSelector(windows: windows), 0.4),
        ]
        if let tuning = feedbackTuning {
            parts.append((scene, tuning.sceneWeight))
        }
        return HighlightEngine(
            selector: FusionSelector(parts),
            planner: ReelPlanner(targetDuration: nil),
            feedback: feedback
        )
    }

    /// Build the scene selector for a workout's media. Runs the Vision scorer ONLY when a replay-derived
    /// weighting exists (else the scene term wouldn't be added anyway — skip the cost). The resulting
    /// scalar `visualScore` is the only thing that crosses into the platform-free engine.
    func sceneSelector(for workout: Workout) async -> SceneHighlightSelector {
        guard feedbackTuning != nil else { return SceneHighlightSelector() }
        let scores = await sceneScorer.sceneScores(for: workout.media)
        guard !scores.isEmpty else { return SceneHighlightSelector() }
        return SceneHighlightSelector(visualScore: SceneScorer.visualScore(from: scores))
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
            // `.ready` only AFTER the first fetch lands — flipping early briefly rendered the
            // empty list (and its "may not have permission" overlay) under every cold load
            // (review fix). A failed refresh wins: it sets `.error`, which is preserved here.
            await refreshWorkouts()
            // Re-weight the fusion blend from the user's own highlight feedback (on-device, local JSONL).
            recomputeFeedbackTuning()
            if case .loading = phase { phase = .ready }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func refreshWorkouts() async {
        refreshing = true
        defer { refreshing = false }
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
