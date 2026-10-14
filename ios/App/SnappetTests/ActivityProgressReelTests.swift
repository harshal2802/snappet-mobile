import XCTest
@testable import Snappet

/// Unit tests for the **pure** `ActivityProgressReel` (activity progress P3, prompt 180): PR moments, reel picks,
/// captions, and caption placement.
final class ActivityProgressReelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func point(_ daysAgo: Double, _ value: Double) -> ActivityDashboard.Point {
        ActivityDashboard.Point(sessionID: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400), value: value,
                                label: "\(value)", hasMedia: true)
    }

    private func dashboard(_ points: [ActivityDashboard.Point], metric: ActivityDashboard.Metric) -> ActivityDashboard {
        ActivityDashboard(key: ActivityKey(exerciseId: "x", nameKey: ""), discipline: .strength, metric: metric,
                          points: points, kpis: [], records: [], weeks: [], sessionCount: points.count, lastDone: nil)
    }

    private func clip(session: UUID, daysAgo: Double, kind: String = "video", set: String? = "60 kg × 8",
                      offset: Double = 10) -> ActivityClip {
        let m = ActivityMediaInput(id: UUID(), sessionID: session, assignedExerciseID: UUID(), assignedSetIndex: 0,
                                   kindRaw: kind, offsetSec: offset, durationSec: 5, localIdentifier: UUID().uuidString)
        return ActivityClip(media: m, sessionID: session, sessionDate: now.addingTimeInterval(-daysAgo * 86_400),
                            setIndex: 0, setSummary: set, avgBPM: nil)
    }

    // MARK: - Badges

    func testFirstThenStrictImprovementsArePRs() {
        let pts = [point(40, 70), point(30, 72), point(20, 72), point(10, 69), point(1, 75)]
        let b = ActivityProgressReel.badges(dashboard(pts, metric: .oneRepMax))
        XCTAssertEqual(b[pts[0].sessionID], .first)
        XCTAssertEqual(b[pts[1].sessionID], .pr)
        XCTAssertNil(b[pts[2].sessionID], "a tie is not a PR")
        XCTAssertNil(b[pts[3].sessionID])
        XCTAssertEqual(b[pts[4].sessionID], .pr)
    }

    func testPaceBadgesFollowLowerIsBetter() {
        let pts = [point(20, 330), point(10, 340), point(1, 320)]
        let b = ActivityProgressReel.badges(dashboard(pts, metric: .pace))
        XCTAssertNil(b[pts[1].sessionID])
        XCTAssertEqual(b[pts[2].sessionID], .pr)
    }

    // MARK: - Picks

    func testPickRulesAreChronologicalAndVideoOnly() {
        let s1 = UUID(), s2 = UUID(), s3 = UUID()
        // Two in one month (days 70 & 60 → same month only if close; use explicit dates below).
        let a = clip(session: s1, daysAgo: 62)
        let photo = clip(session: s1, daysAgo: 62, kind: "photo", offset: 20)
        let b = clip(session: s2, daysAgo: 61, offset: 5)
        let c = clip(session: s3, daysAgo: 1)
        let clips = [c, b, photo, a]
        let badges: [UUID: ActivityProgressReel.Badge] = [s1: .first, s3: .pr]

        XCTAssertEqual(ActivityProgressReel.pick(clips, rule: .all, badges: badges, calendar: cal).map(\.id),
                       [a.id, b.id, c.id], "oldest → newest, photos dropped")
        XCTAssertEqual(ActivityProgressReel.pick(clips, rule: .prs, badges: badges, calendar: cal).map(\.id),
                       [a.id, c.id])
        let monthly = ActivityProgressReel.pick(clips, rule: .monthly, badges: badges, calendar: cal)
        let months = Set(monthly.map { cal.dateComponents([.year, .month], from: $0.sessionDate) })
        XCTAssertEqual(months.count, monthly.count, "one clip per month")
        XCTAssertEqual(monthly.last?.id, c.id)
    }

    func testPRsRuleTakesOneClipPerSession() {
        let s = UUID()
        let picks = ActivityProgressReel.pick([clip(session: s, daysAgo: 3, offset: 10), clip(session: s, daysAgo: 3, offset: 50)],
                                              rule: .prs, badges: [s: .pr], calendar: cal)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks.first?.media.offsetSec, 10)
    }

    // MARK: - Captions

    func testCaptionIncludesSetWhenPresent() {
        XCTAssertTrue(ActivityProgressReel.caption(clip(session: UUID(), daysAgo: 1)).hasSuffix(" · 60 kg × 8"))
        XCTAssertFalse(ActivityProgressReel.caption(clip(session: UUID(), daysAgo: 1, set: nil)).contains("·"))
    }

    func testCaptionOverlaysFollowPlacementsAndSkipUncaptioned() {
        let placements = [ActivityProgressReel.Placement(mediaItemId: "a", startSec: 0, durationSec: 4),
                          ActivityProgressReel.Placement(mediaItemId: "b", startSec: 4, durationSec: 6),
                          ActivityProgressReel.Placement(mediaItemId: "c", startSec: 10, durationSec: 2)]
        let overlays = ActivityProgressReel.captionOverlays(placements: placements, captions: ["a": "Jan", "c": "Oct"])
        XCTAssertEqual(overlays.map(\.content), ["Jan", "Oct"])
        XCTAssertEqual(overlays[1].startSec, 10)
        XCTAssertEqual(overlays[1].endSec, 12)
        XCTAssertEqual(overlays[0].kind, .text)
        XCTAssertLessThan(overlays[0].normalizedY, 0.3, "clears the bottom HR scorebug")
    }
}
