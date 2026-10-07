import XCTest
@testable import Snappet

/// Prompt 166: the autoplay control's confirmation says what happened, including when the system holds it back.
final class ClipAutoplayCopyTests: XCTestCase {
    func testMessages() {
        XCTAssertEqual(ClipAutoplayCopy.message(enabled: false, reduceMotion: true, lowPower: true),
                       "Autoplay off — tap a clip to play it")
        XCTAssertEqual(ClipAutoplayCopy.message(enabled: true, reduceMotion: false, lowPower: false),
                       "Autoplay on — clips play muted as you scroll")
        XCTAssertTrue(ClipAutoplayCopy.message(enabled: true, reduceMotion: false, lowPower: true).contains("Low Power"))
        XCTAssertTrue(ClipAutoplayCopy.message(enabled: true, reduceMotion: true, lowPower: false).contains("Reduce Motion"))
    }

    func testToastsWithTheSameTextAreDistinct() {
        XCTAssertNotEqual(ClipFeedToast(message: "x"), ClipFeedToast(message: "x"))
    }
}
