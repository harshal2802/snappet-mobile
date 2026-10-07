import XCTest
@testable import Snappet

/// Prompt 167 — the feed groups posts under session headers, the grid under months.
final class ClipFeedSectionsTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private let locale = Locale(identifier: "en_GB")

    private func post(_ id: String, session: UUID, at: Date, kind: ClipFeedKind = .kilter,
                      title: String = "Tuesday Session", angle: Int? = 40) -> ClipFeedPost {
        var p = ClipFeedPost(id: id, sessionID: session, kind: kind, moduleID: "kilter",
                             discipline: kind == .kilter ? .climbing : .strength,
                             title: id, subtitle: title, overlayDetail: "", climbUUID: nil, exerciseID: nil,
                             captureAt: at, sessionStartedAt: at, sessionEndedAt: nil, isFromAppleWatch: false,
                             clips: [], aspect: ClipFeedComposer.defaultAspect)
        p.sessionTitle = title
        p.sessionAngle = kind == .kilter ? angle : nil
        return p
    }

    // Tue 29 Sep 2026 / Sat 26 Sep 2026 / Fri 28 Aug 2026 (UTC noon)
    private let tue = Date(timeIntervalSince1970: 1_790_683_200)
    private let sat = Date(timeIntervalSince1970: 1_790_424_000)
    private let aug = Date(timeIntervalSince1970: 1_787_918_400)

    func testConsecutivePostsOfASessionShareOneHeader() {
        let k = UUID(), g = UUID()
        let posts = [post("a", session: k, at: tue), post("b", session: k, at: tue),
                     post("c", session: g, at: sat, kind: .gym, title: "Push Day A")]
        let s = ClipFeedSections.sessions(posts, calendar: cal, locale: locale)
        XCTAssertEqual(s.map { $0.posts.map(\.id) }, [["a", "b"], ["c"]])
        XCTAssertEqual(s[0].title, "Tuesday Session")
        // Day label comes from the locale's "EEE d MMM" template ("Tue 29 Sept" in en_GB) — assert the parts.
        XCTAssertTrue(s[0].detail?.hasPrefix("Tue 29") == true, s[0].detail ?? "")
        XCTAssertTrue(s[0].detail?.hasSuffix(" · Kilter · 40°") == true, s[0].detail ?? "")
        XCTAssertEqual(s[0].countLabel, "2 posts")
        XCTAssertTrue(s[1].detail?.hasPrefix("Sat 26") == true, s[1].detail ?? "")
        XCTAssertTrue(s[1].detail?.hasSuffix(" · Gym") == true, s[1].detail ?? "")
        XCTAssertEqual(s[1].countLabel, "1 post")
    }

    /// A session that reappears later (never from the composer, but filters can't reorder) gets its own
    /// section with a distinct id — ForEach identity stays unique.
    func testRepeatedSessionGetsADistinctSectionID() {
        let k = UUID(), g = UUID()
        let s = ClipFeedSections.sessions([post("a", session: k, at: tue), post("b", session: g, at: sat),
                                           post("c", session: k, at: tue)], calendar: cal, locale: locale)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(Set(s.map(\.id)).count, 3)
    }

    func testMonthsGroupNewestFirst() {
        let m = ClipFeedSections.months([post("a", session: UUID(), at: tue), post("b", session: UUID(), at: sat),
                                         post("c", session: UUID(), at: aug)], calendar: cal, locale: locale)
        XCTAssertEqual(m.map(\.title), ["September 2026", "August 2026"])
        XCTAssertEqual(m.map { $0.posts.count }, [2, 1])
        XCTAssertEqual(m.first?.id, "2026-09")
    }

    /// A festival night whose untagged "session clips" post comes first still reads as Festival.
    func testSessionWithAFestivalPostReadsAsFestival() {
        let night = UUID()
        var untagged = post("clips", session: night, at: tue, kind: .gym, title: "Lost Lands")
        untagged.discipline = .general
        var set = post("set", session: night, at: tue, kind: .gym, title: "Lost Lands")
        set.discipline = .festival
        let s = ClipFeedSections.sessions([untagged, set], calendar: cal, locale: locale)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].discipline, .festival)
        XCTAssertTrue(s[0].detail?.hasSuffix(" · Festival") == true, s[0].detail ?? "")
    }
}
