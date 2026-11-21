import XCTest
@testable import Snappet

/// Manual relink (cloud-connect P1b, prompt 266): a hand-picked asset is verified against the
/// missing clip's fingerprint — attached only on a unique match, otherwise reported.
final class MediaRelinkTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func fp(_ offset: TimeInterval = 0, video: Bool = true, duration: Double? = 12,
                    name: String? = nil) -> MediaFingerprint {
        MediaFingerprint(capturedAt: t0.addingTimeInterval(offset), isVideo: video,
                         durationSec: video ? duration : nil, pixelWidth: 1920, pixelHeight: 1080,
                         originalFilename: name)
    }

    private func row(_ local: String, _ fingerprint: MediaFingerprint?, fallback: MediaFingerprint? = nil,
                     id: UUID = UUID()) -> MediaLinkRow {
        MediaLinkRow(id: id, localIdentifier: local, cloudIdentifier: nil,
                     fingerprint: fingerprint, fallbackFingerprint: fallback)
    }

    private func pick(_ id: String, _ fingerprint: MediaFingerprint) -> MediaLinkCandidate {
        MediaLinkCandidate(localIdentifier: id, fingerprint: fingerprint)
    }

    func testMatchingPickIsAttached() {
        let r = row("OLD", fp())
        let result = MediaRelinkPlanner.assign(missing: [r], picks: [pick("NEW", fp())], owned: [])
        XCTAssertEqual(result.relinks, [r.id: "NEW"])
        XCTAssertEqual(result.verdicts, ["NEW": .attached(rowIDs: [r.id])])
        XCTAssertEqual(result.attachedRowCount, 1)
        XCTAssertEqual(result.unmatchedPickCount, 0)
    }

    func testPickThatMatchesNothingIsReportedNotAttached() {
        let r = row("OLD", fp())
        let result = MediaRelinkPlanner.assign(missing: [r], picks: [pick("NEW", fp(3600))], owned: [])
        XCTAssertTrue(result.relinks.isEmpty)
        XCTAssertEqual(result.verdicts, ["NEW": .noMatch])
        XCTAssertEqual(result.unmatchedPickCount, 1)
    }

    func testWrongKindOrLengthIsNoMatch() {
        let r = row("OLD", fp(duration: 12))
        let result = MediaRelinkPlanner.assign(
            missing: [r], picks: [pick("PHOTO", fp(video: false)), pick("LONG", fp(duration: 40))], owned: [])
        XCTAssertTrue(result.relinks.isEmpty)
        XCTAssertEqual(result.verdicts, ["PHOTO": .noMatch, "LONG": .noMatch])
    }

    func testPickAlreadyUsedByALiveClipIsRejected() {
        let r = row("OLD", fp())
        let result = MediaRelinkPlanner.assign(missing: [r], picks: [pick("LIVE", fp())], owned: ["LIVE"])
        XCTAssertTrue(result.relinks.isEmpty)
        XCTAssertEqual(result.verdicts, ["LIVE": .alreadyInUse])
    }

    func testTwoRowsSharingOneDeadIdentifierBothLandOnThePick() {
        let a = row("OLD", fp()), b = row("OLD", fp())
        let result = MediaRelinkPlanner.assign(missing: [a, b], picks: [pick("NEW", fp())], owned: [])
        XCTAssertEqual(result.relinks, [a.id: "NEW", b.id: "NEW"])
        XCTAssertEqual(result.verdicts["NEW"],
                       .attached(rowIDs: [a.id, b.id].sorted { $0.uuidString < $1.uuidString }))
    }

    func testOnePickThatFitsTwoDifferentMissingClipsEquallyIsNotGuessed() {
        // Two burst shots are missing; one pick fits both the same.
        let a = row("OLD-A", fp(0, video: false)), b = row("OLD-B", fp(1, video: false))
        let result = MediaRelinkPlanner.assign(
            missing: [a, b], picks: [pick("NEW", fp(0.5, video: false))], owned: [])
        XCTAssertTrue(result.relinks.isEmpty)
        XCTAssertEqual(result.verdicts, ["NEW": .ambiguous])
    }

    func testTwoPicksThatFitOneMissingClipEquallyAreNotGuessed() {
        let r = row("OLD", fp(video: false))
        let result = MediaRelinkPlanner.assign(
            missing: [r], picks: [pick("A", fp(0, video: false)), pick("B", fp(1, video: false))], owned: [])
        XCTAssertTrue(result.relinks.isEmpty)
        XCTAssertEqual(result.verdicts, ["A": .ambiguous, "B": .ambiguous])
    }

    func testTheStrongerOfTwoPicksWinsAndTheOtherIsReported() {
        let r = row("OLD", fp(name: "IMG_1.MOV"))
        let result = MediaRelinkPlanner.assign(
            missing: [r], picks: [pick("EXACT", fp(name: "IMG_1.MOV")), pick("COPY", fp(name: "copy.mov"))],
            owned: [])
        XCTAssertEqual(result.relinks, [r.id: "EXACT"])
        XCTAssertEqual(result.verdicts["COPY"], .noMatch)
    }

    func testEachPickFindsItsOwnMissingClipRegardlessOfOrder() {
        let a = row("OLD-A", fp(0)), b = row("OLD-B", fp(600))
        let picks = [pick("NEW-B", fp(600)), pick("NEW-A", fp(0))]
        let one = MediaRelinkPlanner.assign(missing: [a, b], picks: picks, owned: [])
        let two = MediaRelinkPlanner.assign(missing: [b, a], picks: picks.reversed(), owned: [])
        XCTAssertEqual(one.relinks, [a.id: "NEW-A", b.id: "NEW-B"])
        XCTAssertEqual(one, two)
    }

    func testNeverStampedClipMatchesThroughTheSessionFallback() {
        let weak = MediaFingerprint(capturedAt: t0, isVideo: true, durationSec: 12)
        let r = row("OLD", nil, fallback: weak)
        let result = MediaRelinkPlanner.assign(missing: [r], picks: [pick("NEW", fp())], owned: [])
        XCTAssertEqual(result.relinks, [r.id: "NEW"])
    }

    func testClipWithNothingToVerifyAgainstIsNeverAttached() {
        let r = row("OLD", nil)   // never stamped, offset clamped to 0 → no fallback
        let result = MediaRelinkPlanner.assign(missing: [r], picks: [pick("NEW", fp())], owned: [])
        XCTAssertTrue(result.relinks.isEmpty)
        XCTAssertEqual(result.verdicts, ["NEW": .noMatch])
    }

    func testTheSamePickTwiceCountsOnce() {
        let r = row("OLD", fp())
        let result = MediaRelinkPlanner.assign(
            missing: [r], picks: [pick("NEW", fp()), pick("NEW", fp())], owned: [])
        XCTAssertEqual(result.relinks, [r.id: "NEW"])
        XCTAssertEqual(result.verdicts.count, 1)
    }
}

/// The wording + grouping the notice and sheet show (pure).
final class MissingClipsNoticeTests: XCTestCase {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private let us = Locale(identifier: "en_US")
    private let day = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13 UTC

    private func clip(_ offset: TimeInterval?, video: Bool = true, duration: Double? = 14,
                      title: String? = "Bouldering") -> MissingClip {
        MissingClip(id: UUID(), localIdentifier: UUID().uuidString, isVideo: video,
                    capturedAt: offset.map { day.addingTimeInterval($0) }, durationSec: duration,
                    sessionTitle: title)
    }

    func testTitlesAreSingularAndPlural() {
        XCTAssertEqual(MissingClipsNotice.title(count: 1), "1 clip isn’t on this phone")
        XCTAssertEqual(MissingClipsNotice.title(count: 3), "3 clips aren’t on this phone")
        XCTAssertEqual(MissingClipsNotice.sheetTitle(count: 0), "Missing clips")
        XCTAssertEqual(MissingClipsNotice.sheetTitle(count: 1), "Find 1 missing clip")
        XCTAssertEqual(MissingClipsNotice.sheetTitle(count: 3), "Find 3 missing clips")
    }

    func testNoticeReturnsOnlyWhenMoreGoMissingThanWereDismissed() {
        XCTAssertFalse(MissingClipsNotice.shouldShow(count: 0, dismissedAtCount: 0))
        XCTAssertTrue(MissingClipsNotice.shouldShow(count: 3, dismissedAtCount: 0))
        XCTAssertFalse(MissingClipsNotice.shouldShow(count: 3, dismissedAtCount: 3))
        XCTAssertFalse(MissingClipsNotice.shouldShow(count: 2, dismissedAtCount: 3), "some came back")
        XCTAssertTrue(MissingClipsNotice.shouldShow(count: 4, dismissedAtCount: 3))
    }

    func testClipsGroupBySessionAndDayInOrder() {
        let clips = [clip(0), clip(-60), clip(-86_400 * 2), clip(0, title: "Dance"), clip(nil, title: nil)]
        let groups = MissingClipsNotice.groups(clips, calendar: utc, locale: us)
        XCTAssertEqual(groups.map(\.title),
                       ["Bouldering · Nov 14, 2023", "Bouldering · Nov 12, 2023", "Dance · Nov 14, 2023", "Unknown session"])
        XCTAssertEqual(groups.map(\.clips.count), [2, 1, 1, 1])
    }

    func testRowLine() {
        // The system puts a narrow no-break space before AM/PM; compare with plain spaces.
        func line(_ clip: MissingClip) -> String {
            MissingClipsNotice.line(for: clip, calendar: utc, locale: us).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(line(clip(0)), "10:13 PM · 0:14")
        XCTAssertEqual(line(clip(0, duration: 75)), "10:13 PM · 1:15")
        XCTAssertEqual(line(clip(0, video: false, duration: nil)), "10:13 PM · Photo")
        XCTAssertEqual(line(clip(nil)), "Video · 0:14")
        XCTAssertEqual(line(clip(nil, video: false, duration: nil)), "Photo")
    }

    func testOutcomeMessages() {
        XCTAssertEqual(MissingClipsNotice.Outcome(attached: 3, unmatched: 0).message, "3 clips found")
        XCTAssertEqual(MissingClipsNotice.Outcome(attached: 1, unmatched: 2).message,
                       "1 clip found · 2 picks didn’t match a missing clip")
        XCTAssertEqual(MissingClipsNotice.Outcome(attached: 0, unmatched: 1).message,
                       "That pick didn’t match a missing clip")
        XCTAssertEqual(MissingClipsNotice.Outcome(attached: 0, unmatched: 4).message,
                       "None of those matched a missing clip")
    }

    func testOutcomeCountsUnreadablePicksAsUnmatched() {
        let row = UUID()
        var result = MediaRelinkPlanner.Result()
        result.relinks = [row: "NEW"]
        result.verdicts = ["NEW": .attached(rowIDs: [row])]
        let outcome = MissingClipsNotice.Outcome(result: result, picked: 3)   // two never resolved
        XCTAssertEqual(outcome, MissingClipsNotice.Outcome(attached: 1, unmatched: 2))
    }
}
