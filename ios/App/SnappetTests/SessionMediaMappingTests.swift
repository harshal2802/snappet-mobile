import XCTest
@testable import Snappet

/// Unit tests for the **pure** B1 mapping — no device, no Photos: the capture-time window
/// predicate (incl. ±pad boundaries), the clamped creationDate→offset math, and
/// dedupe-by-localIdentifier. The live PHAsset discovery + thumbnails are device-pending
/// (decisions.md 2026-06-01, B1).
final class SessionMediaMappingTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var end: Date { start.addingTimeInterval(1800) }   // 30-min session
    private let pad = SessionMediaService.padSec               // 90 s

    private func asset(_ id: String, _ created: Date?, isVideo: Bool = false, duration: Double = 0)
        -> (localIdentifier: String, creationDate: Date?, isVideo: Bool, duration: Double) {
        (id, created, isVideo, duration)
    }

    // MARK: - In-window predicate (incl. ±pad boundaries)

    func testInsideWindow() {
        XCTAssertTrue(SessionMediaService.isInWindow(start.addingTimeInterval(600),
                                                     startedAt: start, completedAt: end))
    }

    func testBoundariesInclusiveWithPad() {
        // Exactly start − pad and end + pad are inside (inclusive boundaries).
        XCTAssertTrue(SessionMediaService.isInWindow(start.addingTimeInterval(-pad),
                                                     startedAt: start, completedAt: end))
        XCTAssertTrue(SessionMediaService.isInWindow(end.addingTimeInterval(pad),
                                                     startedAt: start, completedAt: end))
    }

    func testJustOutsidePadIsExcluded() {
        XCTAssertFalse(SessionMediaService.isInWindow(start.addingTimeInterval(-pad - 1),
                                                      startedAt: start, completedAt: end))
        XCTAssertFalse(SessionMediaService.isInWindow(end.addingTimeInterval(pad + 1),
                                                      startedAt: start, completedAt: end))
    }

    func testActiveSessionUsesNowAsEnd() {
        // completedAt == nil → window end is "now" + pad; a recent capture is in-window.
        XCTAssertTrue(SessionMediaService.isInWindow(Date().addingTimeInterval(-5),
                                                     startedAt: Date().addingTimeInterval(-60),
                                                     completedAt: nil))
    }

    // MARK: - Offset = clamped seconds since startedAt

    func testOffsetIsSecondsSinceStart() {
        XCTAssertEqual(SessionMediaService.offset(of: start.addingTimeInterval(123), startedAt: start),
                       123, accuracy: 0.001)
    }

    func testOffsetClampsToZeroInsideLeadingPad() {
        // Captured 30 s before startedAt (inside the leading pad) → pinned to 0, not negative.
        XCTAssertEqual(SessionMediaService.offset(of: start.addingTimeInterval(-30), startedAt: start), 0)
    }

    // MARK: - candidates(from:) — filter + map + sort + dedupe

    func testCandidatesFilterMapAndSortByOffset() {
        let out = SessionMediaService.candidates(from: [
            asset("late", end.addingTimeInterval(30), isVideo: true, duration: 12),  // in pad
            asset("mid", start.addingTimeInterval(300)),
            asset("early", start.addingTimeInterval(-pad)),                          // pad boundary
            asset("waytoolate", end.addingTimeInterval(pad + 100)),                  // excluded
            asset("nodate", nil),                                                    // excluded
        ], startedAt: start, completedAt: end)

        XCTAssertEqual(out.map(\.localIdentifier), ["early", "mid", "late"])   // sorted by offset
        XCTAssertEqual(out[0].offsetSec, 0)                                    // clamped
        XCTAssertEqual(out[1].offsetSec, 300, accuracy: 0.001)
        XCTAssertEqual(out[2].kind, .video)
        XCTAssertEqual(out[2].durationSec, 12)
        XCTAssertNil(out[1].durationSec)                                       // photo → nil duration
    }

    func testDedupeByLocalIdentifier() {
        let out = SessionMediaService.candidates(from: [
            asset("a", start.addingTimeInterval(60)),
            asset("b", start.addingTimeInterval(120)),
        ], startedAt: start, completedAt: end, existingIdentifiers: ["a"])

        XCTAssertEqual(out.map(\.localIdentifier), ["b"])   // "a" already tagged → skipped
    }
}
