import XCTest
import SwiftData
@testable import Snappet

/// F2: deep-link target mapping + reaction/save toggling (append-only F0b rows).
final class FeedInteractionTests: XCTestCase {

    func testDeepLinkMapping() {
        let id = UUID()
        XCTAssertEqual(FeedDeepLink.target(objectKind: "kilterSession", objectRef: id.uuidString), .kilterSession(id))
        XCTAssertEqual(FeedDeepLink.target(objectKind: "workoutSession", objectRef: id.uuidString), .workoutSession(id))
        XCTAssertEqual(FeedDeepLink.target(objectKind: "climb", objectRef: "not-a-uuid"), .none)
        XCTAssertEqual(FeedDeepLink.target(objectKind: "aggregate", objectRef: id.uuidString), .none)
    }

    @MainActor func testReactionAndSaveToggle() throws {
        let container = try ModelContainer(for: Schema(SnappetSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        XCTAssertTrue(FeedInteractionWriter.toggleReaction(contentId: "C", in: ctx))
        XCTAssertTrue(FeedInteractionWriter.isReacted(contentId: "C", in: ctx))
        XCTAssertFalse(FeedInteractionWriter.toggleReaction(contentId: "C", in: ctx), "second toggle removes it")
        XCTAssertFalse(FeedInteractionWriter.isReacted(contentId: "C", in: ctx))

        XCTAssertTrue(FeedInteractionWriter.toggleSave(contentId: "C", in: ctx))
        XCTAssertTrue(FeedInteractionWriter.isSaved(contentId: "C", in: ctx))

        XCTAssertFalse(FeedInteractionWriter.toggleReaction(contentId: "", in: ctx), "empty contentId is a no-op")
    }
}
