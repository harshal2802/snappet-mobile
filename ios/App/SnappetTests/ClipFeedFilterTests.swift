import XCTest
@testable import Snappet

/// Pure tests for the Clips search + filter (prompt 107): query matching (case/diacritic-insensitive,
/// title + subtitle), the mutually-exclusive discipline / media-kind chips, favorites, stacking, and
/// the zero-cost inactive fast path.
final class ClipFeedFilterTests: XCTestCase {

    // MARK: helpers

    private func clip(_ kind: String) -> ClipFeedItem {
        ClipFeedItem(media: MediaInput(id: UUID(), kind: kind, offsetSec: 0, durationSec: kind == "video" ? 10 : nil,
                                       exerciseId: nil, setIndex: nil, climbUUID: nil,
                                       localIdentifier: UUID().uuidString),
                     attemptLabel: nil)
    }

    private func post(id: String, kind: ClipFeedKind, title: String, subtitle: String,
                      clipKinds: [String] = ["video"]) -> ClipFeedPost {
        ClipFeedPost(id: id, sessionID: UUID(), kind: kind,
                     moduleID: kind == .kilter ? "kilter" : "workout-log",
                     discipline: kind == .kilter ? .climbing : .strength,
                     title: title, subtitle: subtitle, overlayDetail: "",
                     climbUUID: nil, exerciseID: nil,
                     captureAt: .now, sessionStartedAt: .now, sessionEndedAt: nil,
                     isFromAppleWatch: false,
                     clips: clipKinds.map(clip), aspect: ClipFeedComposer.defaultAspect)
    }

    private var sample: [ClipFeedPost] {
        [post(id: "a", kind: .kilter, title: "Black v6", subtitle: "Tuesday Session · 40°"),
         post(id: "b", kind: .kilter, title: "Orange V5", subtitle: "Comp Night · 45°", clipKinds: ["photo"]),
         post(id: "c", kind: .gym, title: "Bench Press", subtitle: "Push Day A", clipKinds: ["video", "photo"]),
         post(id: "d", kind: .gym, title: "Séance légère", subtitle: "Deload", clipKinds: ["photo"])]
    }

    private func ids(_ posts: [ClipFeedPost]) -> [String] { posts.map(\.id) }

    // MARK: inactive fast path

    func testInactiveFilterReturnsInputUntouchedAndNeverReadsFavorites() {
        let posts = sample
        var favoriteReads = 0
        let out = ClipFeedFilter().apply(posts) { _ in favoriteReads += 1; return true }
        XCTAssertEqual(ids(out), ids(posts))
        XCTAssertEqual(favoriteReads, 0, "inactive filter must not consult the reaction store")
        XCTAssertFalse(ClipFeedFilter().isActive)
    }

    func testWhitespaceOnlyQueryStaysInactive() {
        var f = ClipFeedFilter(); f.query = "   "
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(ids(f.apply(sample) { _ in false }), ids(sample))
    }

    // MARK: query

    func testQueryMatchesTitleCaseInsensitive() {
        var f = ClipFeedFilter(); f.query = "black"
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["a"])
    }

    func testQueryMatchesSessionSubtitle() {
        var f = ClipFeedFilter(); f.query = "push day"
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["c"])
    }

    func testQueryIsDiacriticInsensitive() {
        var f = ClipFeedFilter(); f.query = "seance"
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["d"])
    }

    func testQueryTrimsEdgeWhitespace() {
        var f = ClipFeedFilter(); f.query = "  bench  "
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["c"])
    }

    func testNoMatchReturnsEmpty() {
        var f = ClipFeedFilter(); f.query = "deadlift"
        XCTAssertTrue(f.apply(sample) { _ in true }.isEmpty)
    }

    // MARK: chips

    func testDisciplineClimbs() {
        var f = ClipFeedFilter(); f.discipline = .climbs
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["a", "b"])
    }

    func testDisciplineGym() {
        var f = ClipFeedFilter(); f.discipline = .gym
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["c", "d"])
    }

    func testKindVideosMatchesAnyVideoClip() {
        var f = ClipFeedFilter(); f.kind = .videos
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["a", "c"], "mixed post c counts as video")
    }

    func testKindPhotos() {
        var f = ClipFeedFilter(); f.kind = .photos
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["b", "c", "d"])
    }

    func testFavoritesOnly() {
        var f = ClipFeedFilter(); f.favoritesOnly = true
        XCTAssertEqual(ids(f.apply(sample) { $0 == "b" || $0 == "c" }), ["b", "c"])
    }

    // MARK: stacking + reset

    func testFiltersStack() {
        var f = ClipFeedFilter()
        f.favoritesOnly = true
        f.discipline = .gym
        f.kind = .videos
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["c"])
    }

    func testQueryStacksWithChips() {
        var f = ClipFeedFilter()
        f.discipline = .climbs
        f.query = "orange"
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["b"])
    }

    func testClearedResetsEverything() {
        var f = ClipFeedFilter()
        f.query = "x"; f.discipline = .gym; f.kind = .photos; f.favoritesOnly = true
        XCTAssertTrue(f.isActive)
        f = .cleared
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(ids(f.apply(sample) { _ in false }), ids(sample))
    }
}
