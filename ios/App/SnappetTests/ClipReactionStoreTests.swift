import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the Clips favorites (prompt 88, made durable in prompt 162): toggle semantics over
/// `FeedReaction` rows keyed by CLIP, survival across a regroup and a backup round-trip, and the one-time
/// move of prompt-88 UserDefaults post-id hearts. In-memory store + a throwaway defaults suite.
@MainActor
final class ClipReactionStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema(SnappetSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "ClipReactionStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }   // don't leak the throwaway suite
        return d
    }

    private func store(_ ctx: ModelContext, _ defaults: UserDefaults? = nil) -> ClipReactionStore {
        let s = ClipReactionStore(defaults: defaults ?? freshDefaults())
        s.attach(ctx)
        return s
    }

    private func item(_ id: UUID = UUID()) -> ClipFeedItem {
        ClipFeedItem(media: MediaInput(id: id, kind: "video", offsetSec: 0, durationSec: 5,
                                       exerciseId: nil, setIndex: nil, climbUUID: nil,
                                       localIdentifier: id.uuidString),
                     attemptLabel: nil)
    }

    private func post(_ id: String, _ clips: [ClipFeedItem]) -> ClipFeedPost {
        ClipFeedPost(id: id, sessionID: UUID(), kind: .gym, moduleID: "workout-log", discipline: .strength,
                     title: id, subtitle: "", overlayDetail: "", climbUUID: nil, exerciseID: nil,
                     captureAt: .now, sessionStartedAt: .now, sessionEndedAt: nil, isFromAppleWatch: false,
                     clips: clips, aspect: ClipFeedComposer.defaultAspect)
    }

    // MARK: toggle

    func testToggleHeartsEveryClipAndUnheartsThemAll() throws {
        let ctx = try makeContext()
        let s = store(ctx)
        let p = post("p1", [item(), item()])
        XCTAssertFalse(s.isFavorite(p))
        s.toggle(p)
        XCTAssertTrue(s.isFavorite(p))
        XCTAssertEqual(s.favoriteCount, 2)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FeedReaction>()).count, 2)
        s.toggle(p)
        XCTAssertFalse(s.isFavorite(p))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FeedReaction>()).count, 0)
    }

    /// The heart follows the CLIP: re-tagging regroups it into a post with a different id, and it stays
    /// hearted — the prompt-88 post-id key lost it.
    func testFavoriteSurvivesRegroupingIntoANewPost() throws {
        let ctx = try makeContext()
        let s = store(ctx)
        let clip = item()
        s.toggle(post("bench@s1", [clip]))
        XCTAssertTrue(s.isFavorite(post("fest-set@s1", [clip, item()])))
    }

    /// Un-hearting a post whose clips are only PARTLY hearted (a clip joined it later) clears them all.
    func testUnheartingAPartlyHeartedPostClearsIt() throws {
        let ctx = try makeContext()
        let s = store(ctx)
        let a = item()
        s.toggle(post("p", [a]))
        let grown = post("p", [a, item()])
        XCTAssertTrue(s.isFavorite(grown))
        s.toggle(grown)
        XCTAssertFalse(s.isFavorite(grown))
        XCTAssertEqual(s.favoriteCount, 0)
    }

    func testFavoritesPersistAcrossStoresAndIgnoreRecapReactions() throws {
        let ctx = try makeContext()
        ctx.insert(FeedReaction(activityContentId: "recap-card-1", typeRaw: "emoji", value: "❤️"))
        let p = post("p", [item()])
        store(ctx).toggle(p)
        let reloaded = store(ctx)
        XCTAssertTrue(reloaded.isFavorite(p))
        XCTAssertEqual(reloaded.favoriteCount, 1)   // the Recap heart isn't a clip favorite
    }

    /// The point of the move: favorites ride the backup envelope now.
    func testFavoritesSurviveABackupRoundTrip() throws {
        let ctx = try makeContext()
        let p = post("p", [item()])
        store(ctx).toggle(p)
        let file = try SnappetBackup.decode(SnappetBackup.encode(SnappetBackup.snapshot(of: ctx)))
        let restored = try makeContext()
        try SnappetBackup.restore(file, into: restored)
        XCTAssertTrue(store(restored).isFavorite(p))
    }

    // MARK: legacy migration

    func testLegacyPostIDHeartsMoveOntoTheirClipsOnce() throws {
        let ctx = try makeContext()
        let defaults = freshDefaults()
        let hearted = post("bench@s1", [item(), item()])
        let other = post("squat@s1", [item()])
        defaults.set(["bench@s1", "gone@s0"], forKey: ClipFavorites.legacyDefaultsKey)
        let s = store(ctx, defaults)

        s.migrateLegacy(posts: [])                      // an empty first compose must not drop them
        XCTAssertNotNil(defaults.stringArray(forKey: ClipFavorites.legacyDefaultsKey))

        s.migrateLegacy(posts: [hearted, other])
        XCTAssertTrue(s.isFavorite(hearted))
        XCTAssertFalse(s.isFavorite(other))
        XCTAssertEqual(s.favoriteCount, 2)
        XCTAssertNil(defaults.stringArray(forKey: ClipFavorites.legacyDefaultsKey))
        s.migrateLegacy(posts: [hearted, other])        // idempotent: nothing left to move
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FeedReaction>()).count, 2)
    }

    func testContentIdRoundTrip() {
        let id = UUID()
        XCTAssertEqual(ClipFavorites.mediaID(fromContentId: ClipFavorites.contentId(for: id)), id)
        XCTAssertNil(ClipFavorites.mediaID(fromContentId: "recap-card-1"))
    }

    // MARK: Hide from Clips (prompt 164)

    func testHideUnhideIsBackedUpAndSeparateFromFavorites() throws {
        let ctx = try makeContext()
        let s = store(ctx)
        let a = UUID(), b = UUID()
        s.toggle(post("p", [item(a)]))                       // a favorite on the same clip
        s.hide([a, b])
        XCTAssertTrue(s.isHidden(a) && s.isHidden(b))
        XCTAssertEqual(s.favoriteCount, 1, "hiding doesn't touch favorites")

        let file = try SnappetBackup.decode(SnappetBackup.encode(SnappetBackup.snapshot(of: ctx)))
        let restored = try makeContext()
        try SnappetBackup.restore(file, into: restored)
        XCTAssertEqual(store(restored).hiddenIDs, [a, b])

        s.unhide([a])
        XCTAssertFalse(s.isHidden(a))
        XCTAssertEqual(store(ctx).hiddenIDs, [b], "persisted")
        XCTAssertEqual(store(ctx).favoriteCount, 1)
    }
}
