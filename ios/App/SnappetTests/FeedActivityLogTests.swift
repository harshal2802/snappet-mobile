import XCTest
import SwiftData
@testable import Snappet

/// F0b: the append-only FeedActivity log — idempotency, dormant social columns, and SnappetBackup
/// round-trip for the five new @Models. Uses an in-memory store (no device).
@MainActor
final class FeedActivityLogTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testRecordIsIdempotentByForeignId() throws {
        let ctx = try makeContext()
        let first = FeedActivityWriter.record(verb: "sent", contentId: "CID1", objectRef: "climbA",
                                              objectKind: "climb", published: .now, in: ctx)
        let second = FeedActivityWriter.record(verb: "sent", contentId: "CID1", objectRef: "climbA",
                                               objectKind: "climb", published: .now, in: ctx)
        XCTAssertTrue(first); XCTAssertFalse(second)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FeedActivity>()).count, 1, "re-running the same write must not duplicate")
    }

    func testKilterLogWriterCreatesActivityWithDormantSocialColumns() throws {
        let ctx = try makeContext()
        FeedActivityWriter.recordKilterLog(climbUUID: "abc123", difficulty: 19, status: .sent,
                                           gradeLabel: "V6", date: .now, sessionId: UUID(), in: ctx)
        let acts = try ctx.fetch(FetchDescriptor<FeedActivity>())
        XCTAssertEqual(acts.count, 1)
        let a = try XCTUnwrap(acts.first)
        XCTAssertEqual(a.verb, "sent")
        XCTAssertEqual(a.objectKind, "climb")
        XCTAssertEqual(a.foreignId, "sent:\(a.contentId)")
        // dormant social columns present but defaulted
        XCTAssertEqual(a.actorRef, "self")
        XCTAssertEqual(a.visibility, "private")
        XCTAssertEqual(a.audienceTo, [])
    }

    func testFlashLogUsesFlashedVerb() throws {
        let ctx = try makeContext()
        FeedActivityWriter.recordKilterLog(climbUUID: "z", difficulty: 12, status: .flash,
                                           gradeLabel: "V3", date: .now, sessionId: nil, in: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FeedActivity>()).first?.verb, "flashed")
    }

    func testBackupRoundTripIncludesFeedModels() throws {
        let ctx = try makeContext()
        ctx.insert(FeedActivity(contentId: "C", verb: "sent", objectRef: "x", objectKind: "climb",
                                published: .now, foreignId: "sent:C"))
        ctx.insert(FeedReaction(activityContentId: "C", typeRaw: "note", value: "proud"))
        ctx.insert(FeedSaveItem(activityContentId: "C", collectionId: "projects"))
        ctx.insert(FeedShareEvent(activityContentId: "C", channel: "export:instagram"))
        ctx.insert(FeedOutboxEntry(activityContentId: "C", opRaw: "create"))
        try ctx.save()

        let file = try SnappetBackup.snapshot(of: ctx)
        XCTAssertEqual(file.feedActivities.count, 1)
        XCTAssertEqual(file.feedReactions.count, 1)
        XCTAssertEqual(file.feedSaveItems.count, 1)
        XCTAssertEqual(file.feedShareEvents.count, 1)
        XCTAssertEqual(file.feedOutbox.count, 1)

        let decoded = try SnappetBackup.decode(SnappetBackup.encode(file))
        let restored = try makeContext()
        try SnappetBackup.restore(decoded, into: restored)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<FeedActivity>()).count, 1)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<FeedShareEvent>()).first?.channel, "export:instagram")
        XCTAssertEqual(try restored.fetch(FetchDescriptor<FeedReaction>()).first?.value, "proud")
    }
}
