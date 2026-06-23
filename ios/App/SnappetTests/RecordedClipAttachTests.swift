import XCTest
@testable import Snappet

/// Unit tests for the **pure** attach seam used when a clip recorded in-app during a timed set / attempt
/// (`RecordedClip`) is filed against the session: `SessionMediaService.candidate(for:startedAt:)`. No device,
/// no Photos — the camera capture + the Photos save + the SwiftData insert are device-pending; here we lock
/// the offset-clamp, the always-`.video` kind, and the duration passthrough that the row is built from.
final class RecordedClipAttachTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func clip(_ id: String, at offset: TimeInterval, duration: Double?) -> RecordedClip {
        RecordedClip(localIdentifier: id, capturedAt: start.addingTimeInterval(offset), durationSec: duration)
    }

    // MARK: - Offset relative to the session start

    func testOffsetIsSecondsSinceSessionStart() {
        let c = SessionMediaService.candidate(for: clip("rec-1", at: 90, duration: 12), startedAt: start)
        XCTAssertEqual(c.offsetSec, 90, accuracy: 0.0001)
    }

    func testOffsetClampsToZeroForARecordingThatBeganBeforeStart() {
        // A clip whose recording started just before the session start pins to 0, never negative
        // (matches SessionMediaService.offset — the leading-pad clamp).
        let c = SessionMediaService.candidate(for: clip("rec-2", at: -5, duration: 8), startedAt: start)
        XCTAssertEqual(c.offsetSec, 0, accuracy: 0.0001)
    }

    // MARK: - Kind + identity + duration passthrough

    func testRecordedClipIsAlwaysVideo() {
        let c = SessionMediaService.candidate(for: clip("rec-3", at: 30, duration: 4), startedAt: start)
        XCTAssertEqual(c.kind, .video)
    }

    func testLocalIdentifierAndDurationCarryThrough() {
        let c = SessionMediaService.candidate(for: clip("asset://abc", at: 30, duration: 17.5), startedAt: start)
        XCTAssertEqual(c.localIdentifier, "asset://abc")
        XCTAssertEqual(c.durationSec, 17.5)
    }

    func testNilDurationIsPreserved() {
        // An unreadable duration stays nil (a video row may carry no measured duration).
        let c = SessionMediaService.candidate(for: clip("rec-4", at: 10, duration: nil), startedAt: start)
        XCTAssertNil(c.durationSec)
    }
}
