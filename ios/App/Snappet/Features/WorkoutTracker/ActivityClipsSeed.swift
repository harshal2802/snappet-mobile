import Foundation
import SwiftData

/// Test-only seed for activity progress (prompt 178): `-uiTestSeedActivityClips` layers tagged clips onto the
/// `RoutineHistorySeed` fixture (which it implies) — bench-press clips on four of the past Push Day sessions,
/// one untagged clip, and a clip on the newest Bouldering session. The identifiers are fake, so the tiles show
/// the placeholder gradient (the simulator has no library) while the chip / sheet / dashboard structure renders.
/// Strictly launch-arg guarded, fresh in-memory store — zero production impact.
enum ActivityClipsSeed {
    static let argument = "-uiTestSeedActivityClips"

    @MainActor
    static func seedIfRequested(into context: ModelContext, now: Date = .now) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        RoutineHistorySeed.seed(into: context, now: now)
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)])))
            ?? []
        let push = sessions.filter { $0.routineID == RoutineHistorySeed.pushDayID }
        // Sessions 0, 2, 4, 6 (oldest first) — never the newest, so "today" can be the live one.
        for (n, session) in push.enumerated() where n % 2 == 0 && n < push.count - 1 {
            guard let bench = session.exercises.first, let set = bench.sets.indices.last,
                  let done = bench.sets[set].completedAt else { continue }
            let offset = done.timeIntervalSince(session.startedAt) - 20
            context.insert(SessionMedia(sessionID: session.id, localIdentifier: "seed-activity-\(n)",
                                        kind: .video, offsetSec: offset, durationSec: 12,
                                        assignedExerciseID: bench.id, assignedSetIndex: set, source: .manual))
            if n == 0 {
                context.insert(SessionMedia(sessionID: session.id, localIdentifier: "seed-activity-untagged",
                                            kind: .photo, offsetSec: 30, source: .general))
            }
        }
        if let climb = sessions.last(where: { $0.routineName == "Bouldering" }), let v5 = climb.exercises.last {
            context.insert(SessionMedia(sessionID: climb.id, localIdentifier: "seed-activity-climb",
                                        kind: .video, offsetSec: 1_190, durationSec: 20,
                                        assignedExerciseID: v5.id, assignedSetIndex: 0, source: .manual))
        }
        try? context.save()
    }
}
