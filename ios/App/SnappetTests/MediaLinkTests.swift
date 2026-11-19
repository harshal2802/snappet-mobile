import XCTest
@testable import Snappet

/// The PURE core of media link resilience (cloud-connect P1, prompt 265) — no device, no Photos:
/// fingerprint matching (incl. the "never guess" ambiguity rule) and the stamp / re-link / missing
/// plan. The PhotoKit edge (`MediaLinkService`) is device-pending.
final class MediaLinkTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func fp(_ offset: TimeInterval = 0, video: Bool = true, duration: Double? = 12,
                       w: Int? = 1920, h: Int? = 1080, name: String? = "IMG_0001.MOV") -> MediaFingerprint {
        MediaFingerprint(capturedAt: t0.addingTimeInterval(offset), isVideo: video,
                         durationSec: video ? duration : nil, pixelWidth: w, pixelHeight: h,
                         originalFilename: name)
    }

    private func row(_ local: String, cloud: String? = nil, fingerprint: MediaFingerprint? = nil,
                     fallback: MediaFingerprint? = nil, id: UUID = UUID()) -> MediaLinkRow {
        MediaLinkRow(id: id, localIdentifier: local, cloudIdentifier: cloud,
                     fingerprint: fingerprint, fallbackFingerprint: fallback)
    }

    // MARK: - Matcher

    func testIdenticalFingerprintScoresHighest() {
        XCTAssertEqual(MediaLinkMatcher.score(want: fp(), have: fp()), 5)
    }

    func testKindMismatchDisqualifies() {
        XCTAssertNil(MediaLinkMatcher.score(want: fp(video: true), have: fp(video: false)))
    }

    func testCaptureInstantOutsideToleranceDisqualifies() {
        XCTAssertNotNil(MediaLinkMatcher.score(want: fp(), have: fp(2)))
        XCTAssertNil(MediaLinkMatcher.score(want: fp(), have: fp(2.5)))
    }

    func testDurationAndSizeMismatchDisqualifyWhenBothKnown() {
        XCTAssertNil(MediaLinkMatcher.score(want: fp(duration: 12), have: fp(duration: 13)))
        XCTAssertNil(MediaLinkMatcher.score(want: fp(w: 1920, h: 1080), have: fp(w: 1280, h: 720)))
    }

    func testRotatedPixelSizeStillMatches() {
        XCTAssertNotNil(MediaLinkMatcher.score(want: fp(w: 1920, h: 1080), have: fp(w: 1080, h: 1920)))
    }

    func testUnknownFieldsDoNotDisqualifyButScoreLower() {
        let weak = MediaFingerprint(capturedAt: t0, isVideo: true)
        XCTAssertEqual(MediaLinkMatcher.score(want: weak, have: fp()), 1)
    }

    func testFilenameComparisonIgnoresCaseAndOnlyAddsScore() {
        XCTAssertEqual(MediaLinkMatcher.score(want: fp(name: "img_0001.mov"), have: fp()), 5)
        // A different name (an edited / exported copy) is not a disqualifier.
        XCTAssertEqual(MediaLinkMatcher.score(want: fp(name: "other.mov"), have: fp()), 3)
    }

    func testBestMatchPicksTheStrongerCandidate() {
        let pool = [MediaLinkCandidate(localIdentifier: "renamed", fingerprint: fp(name: "copy.mov")),
                    MediaLinkCandidate(localIdentifier: "exact", fingerprint: fp())]
        XCTAssertEqual(MediaLinkMatcher.bestMatch(for: fp(), among: pool), "exact")
    }

    func testBestMatchRefusesToGuessOnATie() {
        // Two burst photos: same instant, size, no usable filename difference.
        let want = fp(video: false, name: nil)
        let pool = [MediaLinkCandidate(localIdentifier: "a", fingerprint: fp(video: false, name: nil)),
                    MediaLinkCandidate(localIdentifier: "b", fingerprint: fp(1, video: false, name: nil))]
        XCTAssertNil(MediaLinkMatcher.bestMatch(for: want, among: pool))
    }

    func testBestMatchSkipsExcludedIdentifiers() {
        let pool = [MediaLinkCandidate(localIdentifier: "taken", fingerprint: fp())]
        XCTAssertNil(MediaLinkMatcher.bestMatch(for: fp(), among: pool, excluding: ["taken"]))
    }

    // MARK: - Planner: live rows are stamped once

    func testLiveUnstampedRowIsStampedWithCloudIDAndFingerprint() {
        let r = row("L1")
        let library = MediaLibrarySnapshot(present: ["L1": fp()], cloudIdentifiers: ["L1": "C1"])
        XCTAssertEqual(MediaLinkPlanner.plan(rows: [r], library: library),
                       [r.id: .stamp(cloudIdentifier: "C1", fingerprint: fp())])
    }

    func testSettledRowProducesNoAction() {
        let r = row("L1", cloud: "C1", fingerprint: fp())
        let library = MediaLibrarySnapshot(present: ["L1": fp()], cloudIdentifiers: ["L1": "C1"])
        XCTAssertTrue(MediaLinkPlanner.plan(rows: [r], library: library).isEmpty)
    }

    func testExistingCloudIDSurvivesWhenPhotoKitCannotMapThisPass() {
        let r = row("L1", cloud: "C1", fingerprint: fp())
        let library = MediaLibrarySnapshot(present: ["L1": fp()])   // no cloud mapping returned
        XCTAssertTrue(MediaLinkPlanner.plan(rows: [r], library: library).isEmpty)
    }

    func testUnstampableLiveRowIsLeftAlone() {
        let r = row("L1")
        let library = MediaLibrarySnapshot(unstampable: ["L1"])
        XCTAssertTrue(MediaLinkPlanner.plan(rows: [r], library: library).isEmpty)
    }

    // MARK: - Planner: dead rows

    func testDeadRowRelinksThroughCloudIdentifierFirst() {
        let r = row("OLD", cloud: "C1", fingerprint: fp())
        let library = MediaLibrarySnapshot(
            localForCloud: ["C1": "NEW"],
            candidates: [MediaLinkCandidate(localIdentifier: "OTHER", fingerprint: fp())])
        XCTAssertEqual(MediaLinkPlanner.plan(rows: [r], library: library),
                       [r.id: .relink(localIdentifier: "NEW", via: .cloudIdentifier)])
    }

    func testDeadRowFallsBackToFingerprint() {
        let r = row("OLD", fingerprint: fp())
        let library = MediaLibrarySnapshot(
            candidates: [MediaLinkCandidate(localIdentifier: "NEW", fingerprint: fp())])
        XCTAssertEqual(MediaLinkPlanner.plan(rows: [r], library: library),
                       [r.id: .relink(localIdentifier: "NEW", via: .fingerprint)])
    }

    func testNeverStampedRowUsesTheSessionDerivedFallback() {
        let weak = MediaFingerprint(capturedAt: t0, isVideo: true, durationSec: 12)
        let r = row("OLD", fallback: weak)
        let library = MediaLibrarySnapshot(
            candidates: [MediaLinkCandidate(localIdentifier: "NEW", fingerprint: fp())])
        XCTAssertEqual(MediaLinkPlanner.plan(rows: [r], library: library),
                       [r.id: .relink(localIdentifier: "NEW", via: .fingerprint)])
    }

    func testDeadRowWithNoMatchIsMissing() {
        let r = row("OLD", cloud: "C1", fingerprint: fp())
        XCTAssertEqual(MediaLinkPlanner.plan(rows: [r], library: MediaLibrarySnapshot()), [r.id: .missing])
    }

    func testAssetOwnedByALiveRowIsNeverGivenToADeadOne() {
        let live = row("L1", cloud: "C1", fingerprint: fp())
        let dead = row("OLD", fingerprint: fp())
        let library = MediaLibrarySnapshot(
            present: ["L1": fp()],
            candidates: [MediaLinkCandidate(localIdentifier: "L1", fingerprint: fp())])
        XCTAssertEqual(MediaLinkPlanner.plan(rows: [live, dead], library: library), [dead.id: .missing])
    }

    func testTwoRowsSharingOneDeadAssetLandOnTheSameNewAsset() {
        // The same physical clip filed in two sessions (legitimate manual add).
        let a = row("OLD", cloud: "C1", fingerprint: fp())
        let b = row("OLD", cloud: "C1", fingerprint: fp())
        let library = MediaLibrarySnapshot(localForCloud: ["C1": "NEW"])
        let plan = MediaLinkPlanner.plan(rows: [a, b], library: library)
        XCTAssertEqual(plan[a.id], .relink(localIdentifier: "NEW", via: .cloudIdentifier))
        XCTAssertEqual(plan[b.id], .relink(localIdentifier: "NEW", via: .cloudIdentifier))
    }

    func testTwoDifferentDeadRowsCannotClaimTheSameCandidate() {
        let a = row("OLD-A", fingerprint: fp(), id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let b = row("OLD-B", fingerprint: fp(), id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        let library = MediaLibrarySnapshot(
            candidates: [MediaLinkCandidate(localIdentifier: "NEW", fingerprint: fp())])
        let plan = MediaLinkPlanner.plan(rows: [b, a], library: library)   // input order must not matter
        XCTAssertEqual(plan[a.id], .relink(localIdentifier: "NEW", via: .fingerprint))
        XCTAssertEqual(plan[b.id], .missing)
    }

    // MARK: - Search windows + summary

    func testSearchWindowsMergeOverlapsAndSkipUnsearchableRows() {
        let dead = [row("A", fingerprint: fp(0)), row("B", fingerprint: fp(3)),
                    row("C", fingerprint: fp(600)), row("D")]   // D has nothing to search by
        let windows = MediaLinkPlanner.searchWindows(for: dead)
        XCTAssertEqual(windows, [
            DateInterval(start: t0.addingTimeInterval(-2), end: t0.addingTimeInterval(5)),
            DateInterval(start: t0.addingTimeInterval(598), end: t0.addingTimeInterval(602)),
        ])
    }

    func testDeadRowsAreThoseAbsentFromTheLibrary() {
        let rows = [row("L1"), row("OLD")]
        XCTAssertEqual(MediaLinkPlanner.deadRows(rows, present: ["L1"]).map(\.localIdentifier), ["OLD"])
    }

    func testSummaryTalliesEachOutcome() {
        let actions: [UUID: MediaLinkAction] = [
            UUID(): .stamp(cloudIdentifier: nil, fingerprint: fp()),
            UUID(): .relink(localIdentifier: "N", via: .fingerprint),
            UUID(): .missing, UUID(): .missing,
        ]
        XCTAssertEqual(MediaLinkPlanner.summary(of: actions),
                       MediaLinkPlanner.Summary(stamped: 1, relinked: 1, missing: 2))
    }
}
