import Foundation
import SwiftData

// MARK: - Recap Feed — persisted social-ready backbone (F0b)
//
// An append-only, AS2-shaped activity log + first-class interaction rows + an (empty)
// outbox. Social columns (`actorRef`, `visibility`, `audienceTo`) are provisioned but
// DORMANT — nothing reads them in v1. This is what lets "personal-now" become
// "social-ready" later with zero card-view rewrite: flip `actorRef` to a real userId,
// drain the outbox, apply the `visibility` filter. `FeedCard` stays derive-on-read —
// there is NO card table here. Field names/defaults match the Kotlin FA0b 1:1.

/// One append-only activity. Idempotent via `foreignId` (the writer never duplicates).
@Model
final class FeedActivity {
    /// The repeatable activity-row id (v4). NOT the dedup key.
    var id: UUID
    /// Stable UUIDv5 content identity for cross-device dedup (see `FeedContentIdentity`).
    var contentId: String
    /// THE social flip point: "self" today, a real userId tomorrow.
    var actorRef: String
    /// sent | flashed | loggedSession | hitPR | extendedStreak | recap | createdClimb | litBoard | sharedClip | correctedSend
    var verb: String
    /// FK → KilterSession.id / WorkoutSession.id / climbUUID.
    var objectRef: String
    /// kilterSession | workoutSession | climb | clip | litEvent | aggregate
    var objectKind: String
    var targetRef: String?
    /// Ordering + dedup + keyset cursor key.
    var published: Date
    /// Dormant social column.
    var visibility: String
    /// Dormant structured people-tag refs.
    var audienceTo: [String]
    /// Idempotency key: "\(verb):\(contentId)".
    var foreignId: String
    /// "X & 3 others" aggregation later.
    var aggregationKey: String
    /// Last-writer-wins conflict field.
    var updatedAt: Date
    var version: Int
    var schemaVersion: Int

    init(id: UUID = UUID(), contentId: String, actorRef: String = "self", verb: String,
         objectRef: String, objectKind: String, targetRef: String? = nil, published: Date,
         visibility: String = "private", audienceTo: [String] = [],
         foreignId: String, aggregationKey: String = "", updatedAt: Date = .now,
         version: Int = 1, schemaVersion: Int = 1) {
        self.id = id; self.contentId = contentId; self.actorRef = actorRef; self.verb = verb
        self.objectRef = objectRef; self.objectKind = objectKind; self.targetRef = targetRef
        self.published = published; self.visibility = visibility; self.audienceTo = audienceTo
        self.foreignId = foreignId; self.aggregationKey = aggregationKey; self.updatedAt = updatedAt
        self.version = version; self.schemaVersion = schemaVersion
    }
}

/// A private reaction/note on an activity (memory/curation — NOT a social like in v1).
@Model
final class FeedReaction {
    var id: UUID
    var activityContentId: String
    var actorRef: String
    /// "emoji" | "note"
    var typeRaw: String
    var value: String?
    var createdAt: Date

    init(id: UUID = UUID(), activityContentId: String, actorRef: String = "self",
         typeRaw: String, value: String? = nil, createdAt: Date = .now) {
        self.id = id; self.activityContentId = activityContentId; self.actorRef = actorRef
        self.typeRaw = typeRaw; self.value = value; self.createdAt = createdAt
    }
}

/// Saving an activity to a collection.
@Model
final class FeedSaveItem {
    var id: UUID
    var activityContentId: String
    var collectionId: String
    var createdAt: Date

    init(id: UUID = UUID(), activityContentId: String, collectionId: String, createdAt: Date = .now) {
        self.id = id; self.activityContentId = activityContentId
        self.collectionId = collectionId; self.createdAt = createdAt
    }
}

/// A share/export event. `channel` is the seam: "export:*" today, "user:*" tomorrow.
@Model
final class FeedShareEvent {
    var id: UUID
    var activityContentId: String
    /// "export:instagram" | "export:imessage" | "export:photos" | "user:<id>" (later)
    var channel: String
    var createdAt: Date

    init(id: UUID = UUID(), activityContentId: String, channel: String, createdAt: Date = .now) {
        self.id = id; self.activityContentId = activityContentId
        self.channel = channel; self.createdAt = createdAt
    }
}

/// The sync outbox — created EMPTY now, drained by nobody. Retrofitting one onto live data is
/// painful, so we pay the tiny cost up front (the future sync worker drains it).
@Model
final class FeedOutboxEntry {
    var id: UUID
    var activityContentId: String
    /// "create" | "react" | "save" | "share" (the op to fan out later)
    var opRaw: String
    var createdAt: Date
    var attempts: Int

    init(id: UUID = UUID(), activityContentId: String, opRaw: String, createdAt: Date = .now, attempts: Int = 0) {
        self.id = id; self.activityContentId = activityContentId
        self.opRaw = opRaw; self.createdAt = createdAt; self.attempts = attempts
    }
}
