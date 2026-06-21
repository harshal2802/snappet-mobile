import Foundation
import SwiftData

// MARK: - Recap Feed — append-only activity writers (F0b)
//
// The store edge for the FeedActivity log. Hooked into Kilter per-send-log, Kilter
// session-finish, and workout-complete. Append-only + IDEMPOTENT via `foreignId`
// ("\(verb):\(contentId)") — re-running (e.g. session recovery) never duplicates.
// Reaction / SaveItem / ShareEvent writers exist; their UI callers arrive in F2/F4.

enum FeedActivityWriter {

    /// Insert one activity unless an identical `foreignId` already exists. Returns true if inserted.
    @discardableResult
    static func record(verb: String, contentId: String, objectRef: String, objectKind: String,
                       published: Date, targetRef: String? = nil, in context: ModelContext) -> Bool {
        let fid = "\(verb):\(contentId)"
        var probe = FetchDescriptor<FeedActivity>(predicate: #Predicate { $0.foreignId == fid })
        probe.fetchLimit = 1
        if let found = try? context.fetch(probe), !found.isEmpty { return false }   // idempotent
        context.insert(FeedActivity(
            contentId: contentId, verb: verb, objectRef: objectRef, objectKind: objectKind,
            targetRef: targetRef, published: published, foreignId: fid,
            aggregationKey: aggregationKey(targetRef: targetRef, verb: verb, objectKind: objectKind, date: published)))
        return true
    }

    /// Per-climb-log write (the per-send seam). Sends carry verb `sent`/`flashed`.
    static func recordKilterLog(climbUUID: String, difficulty: Double, status: KilterAscentStatus,
                                gradeLabel: String, date: Date, sessionId: UUID?, in context: ModelContext) {
        let verb: String
        switch status {
        case .flash: verb = "flashed"
        case .sent: verb = "sent"
        case .project, .attempt: verb = "loggedSession"
        }
        let cid = FeedContentIdentity.kilterSend(climbUUID: climbUUID, difficulty: difficulty,
                                                 statusRaw: status.rawValue, date: date,
                                                 sessionId: sessionId?.uuidString)
        record(verb: verb, contentId: cid, objectRef: climbUUID, objectKind: "climb",
               published: date, targetRef: gradeLabel, in: context)
    }

    /// Kilter session-finish write.
    static func recordKilterSessionFinish(_ session: KilterSession, in context: ModelContext) {
        let cid = FeedContentIdentity.kilterSession(id: session.id.uuidString)
        record(verb: "loggedSession", contentId: cid, objectRef: session.id.uuidString,
               objectKind: "kilterSession", published: session.endedAt ?? .now,
               targetRef: session.layoutId.map(String.init), in: context)
    }

    /// Workout session-complete write.
    static func recordWorkoutFinish(_ session: WorkoutSession, in context: ModelContext) {
        let cid = FeedContentIdentity.workoutSession(id: session.id.uuidString)
        record(verb: "loggedSession", contentId: cid, objectRef: session.id.uuidString,
               objectKind: "workoutSession", published: session.completedAt ?? .now, in: context)
    }

    private static func aggregationKey(targetRef: String?, verb: String, objectKind: String, date: Date) -> String {
        "\(targetRef ?? "none"):\(verb):\(objectKind):\(FeedContentIdentity.dayBucket(date))"
    }
}
