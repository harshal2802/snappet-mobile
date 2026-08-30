import Foundation
import SwiftData

/// The ONE way a live `WorkoutSession` becomes a completed one (prompt 125).
///
/// This block used to exist twice, line for line: the gym tracker's `finishWorkout` and the
/// festival schedule's `endNight` (a dance session is a `WorkoutSession` too). Two copies of
/// flush-HR / stamp-bounds / kcal / stop-services / feed-the-recap is exactly how the two
/// surfaces drift; either caller adds its own module logging after this returns.
@MainActor
enum WorkoutSessionFinisher {

    /// Flush the live HR buffer into the session BEFORE `stop()` (which stops both sources),
    /// stamp the profile-derived bounds + source label from the actually-captured data, estimate
    /// calories (BLE only — the Apple-Watch path measures real active energy on the wrist), end
    /// the live services, stamp `completedAt`, feed the Recap log, save.
    static func finish(_ session: WorkoutSession, app: AppModel, context: ModelContext,
                       at now: Date = .now) {
        session.hrSeries = WorkoutHRStats.points(from: app.liveWorkout.samples)
        if !session.hrSeries.isEmpty {
            let profile = app.userProfile.profile
            session.metricsSourceRaw = app.liveWorkout.activeKind.rawValue
            session.maxHR = profile.resolvedMaxHR
            session.restHR = profile.restingBound
            if app.liveWorkout.activeKind == .ble {
                session.kcalEstimate = profile.estimatedKcal(forSeries: session.hrSeries,
                                                             durationSec: session.duration)
            }
        }
        app.liveWorkout.stop()
        app.liveActivity.end()
        session.completedAt = now
        FeedActivityWriter.recordWorkoutFinish(session, in: context)
        try? context.save()
    }
}
