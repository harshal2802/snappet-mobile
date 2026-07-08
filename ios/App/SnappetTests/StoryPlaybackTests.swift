import XCTest
@testable import Snappet

/// F6: pure Story playback state machine — auto-advance, pause/resume, index bounds.
final class StoryPlaybackTests: XCTestCase {

    func testTickAdvancesThenDismisses() {
        var p = StoryPlayback(sceneCount: 3, perSceneDuration: 1)
        XCTAssertFalse(p.tick(0.5)); XCTAssertEqual(p.index, 0)
        XCTAssertFalse(p.tick(0.6)); XCTAssertEqual(p.index, 1)   // crossed 1.0 → next scene
        XCTAssertFalse(p.tick(1.0)); XCTAssertEqual(p.index, 2)
        XCTAssertTrue(p.tick(1.0), "ticking past the last scene signals dismiss")
    }

    func testPauseFreezesAndResume() {
        var p = StoryPlayback(sceneCount: 2, perSceneDuration: 1)
        p.pause()
        XCTAssertFalse(p.tick(5)); XCTAssertEqual(p.index, 0); XCTAssertEqual(p.progress, 0)
        p.resume()
        _ = p.tick(0.5); XCTAssertEqual(p.progress, 0.5, accuracy: 0.001)
    }

    /// #271: a story paused for the share sheet must not stay frozen once the user navigates —
    /// deliberate next/back taps are an implicit resume (the sheet's onDismiss also resumes).
    func testNextAndBackClearPause() {
        var p = StoryPlayback(sceneCount: 3, perSceneDuration: 1)
        p.pause()
        XCTAssertFalse(p.next())
        XCTAssertFalse(p.isPaused, "tap-right resumes a paused story")
        XCTAssertFalse(p.tick(0.5)); XCTAssertEqual(p.progress, 0.5, accuracy: 0.001)
        p.pause()
        p.back()
        XCTAssertFalse(p.isPaused, "tap-left resumes a paused story")
    }

    func testNextBackBounds() {
        var p = StoryPlayback(sceneCount: 3)
        p.back(); XCTAssertEqual(p.index, 0, "no underflow")
        XCTAssertFalse(p.next()); XCTAssertEqual(p.index, 1)
        XCTAssertFalse(p.next()); XCTAssertEqual(p.index, 2)
        XCTAssertTrue(p.next(), "next past the last scene signals dismiss")
        p.back(); XCTAssertEqual(p.index, 1)
    }
}
