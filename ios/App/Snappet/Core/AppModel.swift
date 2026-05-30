import Foundation
import Observation
import HighlightEngine

/// App-wide state + the single place the engine and services are wired together.
/// Swapping the selector (HR → fusion) or config is a one-line change here.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case idle, needsPermission, ready, error(String) }

    var phase: Phase = .idle
    var workouts: [WorkoutSummary] = []

    let health = HealthKitService()
    let photos = PhotoLibraryService()
    let feedback = FeedbackStore()      // FeedbackSink → disk (training data)

    /// The active engine. Default = best-guess HR selector + per-activity presets.
    /// Later: `FusionSelector.hrLeaning(scene:)` once a vision pipeline exists.
    private(set) lazy var engine = HighlightEngine(
        selector: HRHighlightSelector(),
        planner: ReelPlanner(targetDuration: 30),
        feedback: feedback
    )

    func bootstrap() async {
        do {
            try await health.requestAuthorization()
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

    /// Build the engine input for a workout: pull its HR series + find media shot
    /// in its time window, aligned onto the workout timeline.
    func buildWorkout(_ summary: WorkoutSummary) async throws -> Workout {
        let hr = try await health.heartRateSamples(for: summary)
        let media = try await photos.media(in: summary.dateInterval, workoutStart: summary.start)
        return Workout(
            activity: summary.activity,
            duration: summary.duration,
            hr: hr,
            restBpm: summary.restingBpm,
            maxBpm: summary.maxBpm,
            media: media
        )
    }
}
