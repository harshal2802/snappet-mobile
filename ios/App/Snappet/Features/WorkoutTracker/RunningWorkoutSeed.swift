import Foundation
import SwiftData

/// Test-only seed (prompt 279): a workout that was already running when the app starts — what the store
/// holds after iOS closed the app behind a session. `-uiTestSeedRunningWorkout` implies the fresh
/// in-memory store; zero production impact. `-uiTestSeedRunningWorkoutOld` starts it hours ago instead.
enum RunningWorkoutSeed {
    static let argument = "-uiTestSeedRunningWorkout"
    static let oldArgument = "-uiTestSeedRunningWorkoutOld"

    @MainActor
    static func seedIfRequested(into context: ModelContext, now: Date = .now) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(argument) || args.contains(oldArgument) else { return }
        let ago: TimeInterval = args.contains(oldArgument) ? 9 * 3600 : 25 * 60
        context.insert(WorkoutSession(routineName: "Quick Session", startedAt: now.addingTimeInterval(-ago)))
        try? context.save()
    }
}
