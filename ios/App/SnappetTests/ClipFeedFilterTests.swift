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
        var f = ClipFeedFilter(); f.activity = .climbing
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["a", "b"])
    }

    func testDisciplineGym() {
        var f = ClipFeedFilter(); f.activity = .strength
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
        XCTAssertEqual(ids(f.apply(sample) { $0.id == "b" || $0.id == "c" }), ["b", "c"])
    }

    // MARK: stacking + reset

    func testFiltersStack() {
        var f = ClipFeedFilter()
        f.favoritesOnly = true
        f.activity = .strength
        f.kind = .videos
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["c"])
    }

    func testQueryStacksWithChips() {
        var f = ClipFeedFilter()
        f.activity = .climbing
        f.query = "orange"
        XCTAssertEqual(ids(f.apply(sample) { _ in true }), ["b"])
    }

    func testClearedResetsEverything() {
        var f = ClipFeedFilter()
        f.query = "x"; f.activity = .strength; f.kind = .photos; f.favoritesOnly = true
        f.reelsOnly = true
        XCTAssertTrue(f.isActive)
        f = .cleared
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(ids(f.apply(sample) { _ in false }), ids(sample))
    }

    // MARK: reels chip (highlights P2)

    func testReelsOnlyShowsOnlyReelPosts() {
        var reelPost = post(id: "r", kind: .gym, title: "Push Day — Highlights", subtitle: "Push Day")
        reelPost.isReel = true
        var f = ClipFeedFilter()
        f.reelsOnly = true
        XCTAssertTrue(f.isActive, "the Reels chip alone activates the filter")
        XCTAssertEqual(ids(f.apply(sample + [reelPost]) { _ in true }), ["r"])
    }

    func testReelsChipStacksWithDiscipline() {
        var kilterReel = post(id: "kr", kind: .kilter, title: "Board — Highlights", subtitle: "Board night")
        kilterReel.isReel = true
        var gymReel = post(id: "gr", kind: .gym, title: "Push — Highlights", subtitle: "Push Day")
        gymReel.isReel = true
        var f = ClipFeedFilter()
        f.reelsOnly = true
        f.activity = .climbing
        XCTAssertEqual(ids(f.apply(sample + [kilterReel, gymReel]) { _ in true }), ["kr"])
    }

    // MARK: - 🎪 Festival chip (festival prompt 03)

    /// A festival post rides a GYM-kind dance session with `discipline == .festival`.
    private func festivalPost(id: String, title: String, isReel: Bool = false) -> ClipFeedPost {
        var p = post(id: id, kind: .gym, title: title, subtitle: "Glastonbury 2026 · Saturday")
        p.discipline = .festival
        p.isReel = isReel
        return p
    }

    func testFestivalChipShowsOnlyFestivalPosts() {
        let fred = festivalPost(id: "f1", title: "Fred again.. · Pyramid Stage")
        var f = ClipFeedFilter()
        f.activity = .festival
        XCTAssertEqual(ids(f.apply(sample + [fred]) { _ in true }), ["f1"])
    }

    func testGymChipExcludesFestivalPosts() {
        // The dance session IS a gym-kind WorkoutSession — but a dance set is not a workout post.
        let fred = festivalPost(id: "f1", title: "Fred again.. · Pyramid Stage")
        var f = ClipFeedFilter()
        f.activity = .strength
        XCTAssertEqual(ids(f.apply(sample + [fred]) { _ in true }), ["c", "d"])
    }

    func testArtistSearchMatchesFestivalPostsWithZeroNewCode() {
        // The whole point of artist·stage titles: the EXISTING title search finds "fred".
        let fred = festivalPost(id: "f1", title: "Fred again.. · Pyramid Stage")
        var f = ClipFeedFilter()
        f.query = "fred"
        XCTAssertEqual(ids(f.apply(sample + [fred]) { _ in true }), ["f1"])
    }

    func testFestivalChipStacksWithReels() {
        let clipPost = festivalPost(id: "f1", title: "Fred again.. · Pyramid Stage")
        let reelPost = festivalPost(id: "fr", title: "Fred again.. · Pyramid Stage", isReel: true)
        var f = ClipFeedFilter()
        f.activity = .festival
        f.reelsOnly = true
        XCTAssertEqual(ids(f.apply(sample + [clipPost, reelPost]) { _ in true }), ["fr"])
    }

    // MARK: Sends (prompt 161)

    func testSendsOnlyKeepsFlashesAndSendsAndStacks() {
        var sent = post(id: "s", kind: .kilter, title: "Crux", subtitle: "Tue")
        sent.climbResult = .init(status: .sent, attempts: 3)
        var flash = post(id: "f", kind: .gym, title: "Yellow", subtitle: "Bouldering")
        flash.climbResult = .init(status: .flash, attempts: 1)
        var project = post(id: "p", kind: .kilter, title: "Roof", subtitle: "Tue")
        project.climbResult = .init(status: .project, attempts: 8)
        var f = ClipFeedFilter()
        f.sendsOnly = true
        XCTAssertTrue(f.isActive)
        XCTAssertEqual(ids(f.apply(sample + [sent, flash, project]) { _ in false }), ["s", "f"])
        f.activity = .climbing
        XCTAssertEqual(ids(f.apply(sample + [sent, flash, project]) { _ in false }), ["s"])
    }

    // MARK: Hidden (prompt 164)

    func testHiddenClipsLeaveTheirPostsAndShowHiddenInvertsIt() {
        let a = clip("video"), b = clip("video"), c = clip("photo")
        var two = post(id: "two", kind: .kilter, title: "Crux", subtitle: "Tue")
        two.clips = [a, b]
        var one = post(id: "one", kind: .gym, title: "Bench", subtitle: "Push")
        one.clips = [c]
        let posts = [two, one]
        // Nothing hidden → the input, untouched.
        XCTAssertEqual(ClipFeedFilter.withHidden(posts, hidden: [], showHidden: false), posts)
        // Hide one clip of "two" and the only clip of "one".
        let hidden: Set<UUID> = [a.media.id, c.media.id]
        let normal = ClipFeedFilter.withHidden(posts, hidden: hidden, showHidden: false)
        XCTAssertEqual(ids(normal), ["two"])
        XCTAssertEqual(normal.first?.clips.map(\.media.id), [b.media.id])
        let onlyHidden = ClipFeedFilter.withHidden(posts, hidden: hidden, showHidden: true)
        XCTAssertEqual(ids(onlyHidden), ["two", "one"])
        XCTAssertEqual(onlyHidden.first?.clips.map(\.media.id), [a.media.id])
        var f = ClipFeedFilter(); f.showHidden = true
        XCTAssertTrue(f.isActive)
    }
}
