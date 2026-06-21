import XCTest
import CoreGraphics
@testable import Snappet

/// F3 (R1) — single-active-player nearest-viewport-center index + hysteresis no-thrash.
/// Pure: synthetic geometry, no SwiftUI/AVFoundation.
final class FeedActivePlayerCoordinatorTests: XCTestCase {

    private let viewport = CGRect(x: 0, y: 0, width: 390, height: 800)   // viewport center y = 400

    /// Three stacked cards of height 300; card index 1 straddles the viewport center.
    private func stackedFrames(offsetY: CGFloat) -> [CGRect] {
        (0..<3).map { i in CGRect(x: 0, y: CGFloat(i) * 300 - offsetY, width: 390, height: 300) }
    }

    func testEmptyFramesYieldsNil() {
        XCTAssertNil(FeedActivePlayerCoordinator.activeIndex(cardFrames: [], viewport: viewport, current: nil, hysteresis: 20))
    }

    func testNearestCenterIsSelectedFromCold() {
        // offsetY 0 → card 1 spans [300,600], center 450 (dist 50); card 0 center 150 (dist 250).
        let frames = stackedFrames(offsetY: 0)
        let idx = FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: nil, hysteresis: 20)
        XCTAssertEqual(idx, 1, "the card whose center is nearest the viewport center wins")
    }

    func testScrollHandsOffToNewNearestWhenItClearlyWins() {
        // Scroll up by 300 → card 2 now spans [300,600] (center 450, dist 50); card 1 center 150 (dist 250).
        let frames = stackedFrames(offsetY: 300)
        let idx = FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: 1, hysteresis: 20)
        XCTAssertEqual(idx, 2, "a clearly-closer card takes over the active player")
    }

    func testHysteresisPreventsThrashNearCenter() {
        // current = 0 (center 410, dist 10). card 1 center 390 (dist 10) — equal distance, so the
        // challenger does NOT beat current by > hysteresis → current is held (no thrash).
        let frames = [
            CGRect(x: 0, y: 260, width: 390, height: 300),   // card 0: center 410, dist 10
            CGRect(x: 0, y: 240, width: 390, height: 300),   // card 1: center 390, dist 10
        ]
        let idx = FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: 0, hysteresis: 20)
        XCTAssertEqual(idx, 0, "a near-tie challenger must not steal the active player (hysteresis)")
    }

    func testHysteresisYieldsWhenChallengerBeatsBandByMoreThanThreshold() {
        // current = 0 (center 410, dist 10). card 1 center 405? make card 1 clearly closer: center 400 (dist 0).
        // 0's dist (10) - 1's dist (0) = 10, which is NOT > hysteresis 20 → still held.
        let frames = [
            CGRect(x: 0, y: 260, width: 390, height: 300),   // card 0: center 410, dist 10
            CGRect(x: 0, y: 250, width: 390, height: 300),   // card 1: center 400, dist 0
        ]
        XCTAssertEqual(FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: 0, hysteresis: 20),
                       0, "improvement of 10 does not exceed the 20 band → hold current")
        // With a smaller band (5), the 10-point improvement now exceeds it → hand off.
        XCTAssertEqual(FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: 0, hysteresis: 5),
                       1, "improvement of 10 exceeds the 5 band → hand off")
    }

    func testCardScrolledFullyOffScreenIsNotSelected() {
        // Card 0 fully above the viewport; only card 1 (partially on) is a candidate.
        let frames = [
            CGRect(x: 0, y: -400, width: 390, height: 300),  // entirely above viewport (maxY = -100)
            CGRect(x: 0, y: 100, width: 390, height: 300),   // on screen, center 250
        ]
        let idx = FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: nil, hysteresis: 20)
        XCTAssertEqual(idx, 1, "an off-screen card is never the active player")
    }

    func testCurrentReleasedWhenItScrollsOffScreen() {
        // current = 0 but card 0 is now fully off-screen → must release to the on-screen card.
        let frames = [
            CGRect(x: 0, y: -400, width: 390, height: 300),  // off screen
            CGRect(x: 0, y: 300, width: 390, height: 300),   // on screen, center 450
        ]
        let idx = FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: 0, hysteresis: 20)
        XCTAssertEqual(idx, 1, "when the active card leaves the screen the player moves to the visible one")
    }

    func testAllOffScreenYieldsNil() {
        let frames = [
            CGRect(x: 0, y: -1000, width: 390, height: 300),
            CGRect(x: 0, y: 2000, width: 390, height: 300),
        ]
        XCTAssertNil(FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: 0, hysteresis: 20))
    }

    func testTieBreaksToLowestIndexFromCold() {
        // Two cards equidistant from center, no current → lowest index wins for stability.
        let frames = [
            CGRect(x: 0, y: 250, width: 390, height: 300),   // center 400, dist 0
            CGRect(x: 0, y: 250, width: 390, height: 300),   // center 400, dist 0
        ]
        XCTAssertEqual(FeedActivePlayerCoordinator.activeIndex(cardFrames: frames, viewport: viewport, current: nil, hysteresis: 20), 0)
    }
}
