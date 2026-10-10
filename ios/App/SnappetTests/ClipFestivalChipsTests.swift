import XCTest
@testable import Snappet

/// Prompt 171 — festival posts name their festival (and artist when matched), and the festival filters are
/// dynamic: one chip per festival you have clips from, then a row of that festival's artists + "Untagged".
final class ClipFestivalChipsTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func video(_ offset: Double) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: 6, exerciseId: nil,
                   setIndex: nil, climbUUID: nil, localIdentifier: "f\(offset)-\(UUID())")
    }

    private func night(_ name: String, pack: String, day: String) -> ClipFeedPostFestival {
        ClipFeedPostFestival(packID: pack, name: name, dayLabel: day, artist: nil)
    }

    /// One festival night: a clip matched to Subtronics' set, one to Excision's, and two unmatched.
    private func lostLands() -> [ClipFeedPost] {
        let meta = ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Dance", startedAt: start)
        let sub = video(10), exc = video(20), loose1 = video(30), loose2 = video(40)
        func tag(_ artist: String, _ set: String) -> ClipFeedFestivalMeta {
            ClipFeedFestivalMeta(setKey: set, artist: artist, stage: "Cyclops", festivalName: "Lost Lands 2026",
                                 dayLabel: "Saturday", packID: "ll26")
        }
        return ClipFeedComposer.posts(
            sessions: [.init(meta: meta, clips: [sub, exc, loose1, loose2], sessionActivity: .festival,
                             festivalNight: night("Lost Lands 2026", pack: "ll26", day: "Saturday"))],
            climbMeta: [:], exerciseName: { _ in "?" },
            festivalMeta: [sub.id: tag("Subtronics", "s1"), exc.id: tag("Excision", "s2")])
    }

    func testPostsNameTheFestivalAndArtist() throws {
        let posts = lostLands()
        let sub = try XCTUnwrap(posts.first { $0.festival?.artist == "Subtronics" })
        XCTAssertEqual(sub.title, "Subtronics · Cyclops")
        XCTAssertEqual(sub.festival?.name, "Lost Lands 2026")
        // The unmatched clips: titled by festival + day (not "Dance"), festival carried, no artist.
        let loose = try XCTUnwrap(posts.first { $0.festival?.artist == nil })
        XCTAssertEqual(loose.title, "Lost Lands 2026 · Saturday")
        XCTAssertEqual(loose.subtitle, "Not matched to an artist yet")
        XCTAssertEqual(loose.clipCount, 2)
        XCTAssertEqual(loose.discipline, .festival)
    }

    func testChipsAreTheFestivalsYouHaveThenTheirArtists() {
        let other = ClipFeedComposer.posts(
            sessions: [.init(meta: ClipFeedSessionMeta(id: UUID(), kind: .gym, title: "Dance",
                                                       startedAt: start.addingTimeInterval(-86_400 * 60)),
                             clips: [video(1)], sessionActivity: .festival,
                             festivalNight: night("EDC 2026", pack: "edc26", day: "Friday"))],
            climbMeta: [:], exerciseName: { _ in "?" })
        let posts = lostLands() + other
        XCTAssertEqual(ClipFestivalChips.festivals(in: posts).map(\.name), ["Lost Lands 2026", "EDC 2026"])
        let row = ClipFestivalChips.artists(in: posts, packID: "ll26")
        XCTAssertEqual(row.artists, ["Excision", "Subtronics"])      // alphabetical
        XCTAssertEqual(row.untagged, 1)                              // one unmatched post (2 clips)
        XCTAssertEqual(ClipFestivalChips.artists(in: posts, packID: "edc26").artists, [])
    }

    func testFestivalAndArtistFilters() {
        let posts = lostLands()
        var f = ClipFeedFilter()
        f.festivalPack = "ll26"
        XCTAssertTrue(f.isActive)
        XCTAssertEqual(f.apply(posts, isFavorite: { _ in false }).count, 3)
        f.festivalArtist = .artist("Excision")
        XCTAssertEqual(f.apply(posts, isFavorite: { _ in false }).map(\.title), ["Excision · Cyclops"])
        f.festivalArtist = .untagged
        XCTAssertEqual(f.apply(posts, isFavorite: { _ in false }).map(\.title), ["Lost Lands 2026 · Saturday"])
        f.festivalPack = "edc26"
        f.festivalArtist = nil
        XCTAssertTrue(f.apply(posts, isFavorite: { _ in false }).isEmpty)
    }

    /// The session header names the festival, not the generic "Festival".
    func testSessionHeaderNamesTheFestival() {
        let s = ClipFeedSections.sessions(lostLands())
        XCTAssertEqual(s.count, 1)
        XCTAssertTrue(s[0].detail?.hasSuffix("· Lost Lands 2026") == true, s[0].detail ?? "")
    }

    // MARK: Tag artist → "Pick another set…" (prompt 172)

    /// Any clip can be tagged to any artist: the day's sets, the one playing when you filmed first, then by
    /// how close each was to that moment.
    func testSetsByProximityPutsWhatWasPlayingFirst() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func set(_ a: String, _ startMin: Double, _ endMin: Double) -> FestivalSet {
            FestivalSet(artist: a, start: t0.addingTimeInterval(startMin * 60), end: t0.addingTimeInterval(endMin * 60))
        }
        let sets = [set("Early", 0, 60), set("Playing", 90, 150), set("Next", 160, 220), set("Late", 300, 360)]
        let capture = t0.addingTimeInterval(120 * 60)                  // inside "Playing"
        XCTAssertEqual(FestivalTagging.setsByProximity(sets, to: capture).map(\.artist),
                       ["Playing", "Next", "Early", "Late"])            // 0, 40, 60, 180 min away
    }
}
