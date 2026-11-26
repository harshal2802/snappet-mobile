#if DEBUG
import XCTest
@testable import Snappet

/// The seed behind `StudioHRTimingUITests` (prompt 306): its rows are what a real "Save to
/// original" writes, and each clip's capture time is the one the UI test expects.
final class StudioHRTimingSeedTests: XCTestCase {

    private func rows() -> [StudioHRTimingSeed.Clip: SessionMedia] {
        let made = StudioHRTimingSeed.mediaRows(sessionID: UUID())
        return Dictionary(uniqueKeysWithValues: zip(StudioHRTimingSeed.Clip.allCases, made))
    }

    func testTheUnbakedClipHasNoMap() throws {
        let a = try XCTUnwrap(rows()[.a])
        XCTAssertFalse(a.isBaked)
        XCTAssertNil(a.bakeTimeMap)
        XCTAssertEqual(a.offsetSec, 60)
        XCTAssertEqual(a.durationSec, 10)
        XCTAssertEqual(a.captureClock.captureTime(renditionTime: 4), 64)
    }

    func testTheStartTrimClipMapsRenditionZeroToSourceTwenty() throws {
        let b = try XCTUnwrap(rows()[.b])
        XCTAssertTrue(b.isBaked)
        XCTAssertEqual(b.offsetSec, 200, "a 'Save to original' does not move the offset")
        XCTAssertEqual(b.durationSec, 10, "the rendered length")
        let map = try XCTUnwrap(b.bakeTimeMap)
        XCTAssertTrue(map.isRevertible)
        XCTAssertNil(map.revertsTo)
        XCTAssertEqual(map.segments, [.init(renditionStartSec: 0, sourceStartSec: 20, speed: 1)])
        XCTAssertEqual(map.renditionDurationSec, 10, accuracy: 1e-9)
        XCTAssertEqual(b.captureClock.captureTime(renditionTime: 0), 220)
        XCTAssertEqual(b.captureClock.captureTime(renditionTime: 4), 224)
        // What the revert check would do with "no edited video": back to the recording.
        XCTAssertEqual(ClipBakePlan.revertFinding(map: map), .backToRecording)
    }

    func testTheDoubleSpeedClipMapsRenditionTimeToTwiceTheSourceTime() throws {
        let c = try XCTUnwrap(rows()[.c])
        XCTAssertTrue(c.isBaked)
        XCTAssertEqual(c.offsetSec, 120)
        XCTAssertEqual(c.durationSec, 10)
        let map = try XCTUnwrap(c.bakeTimeMap)
        XCTAssertTrue(map.isRevertible)
        XCTAssertEqual(map.segments, [.init(renditionStartSec: 0, sourceStartSec: 0, speed: 2)])
        XCTAssertEqual(map.renditionDurationSec, 10, accuracy: 1e-9)
        XCTAssertEqual(c.captureClock.captureTime(renditionTime: 4), 128)
        let window = c.captureClock.captureWindow(renditionStart: 0, renditionEnd: 10)
        XCTAssertEqual(window.start, 120)
        XCTAssertEqual(window.span, 20, accuracy: 1e-9)
    }

    func testTheRampNamesItsSecondAndCoversEveryClipsWindow() {
        let series = StudioHRTimingSeed.rampSeries()
        XCTAssertEqual(series.first?.bpm, 60)
        XCTAssertEqual(series.last?.t, StudioHRTimingSeed.sessionSeconds)
        XCTAssertTrue(zip(series, series.dropFirst()).allSatisfy { $0.bpm < $1.bpm }, "strictly rising")
        XCTAssertEqual(StudioHRTimingSeed.rampBPM(at: 220), 170)
        // Clip B's window with the default 30 s tail ends at 260 s.
        XCTAssertGreaterThanOrEqual(StudioHRTimingSeed.sessionSeconds,
                                    200 + 20 + StudioHRTimingSeed.videoSeconds + HRClipWindow.defaultTailSec)
    }

    func testOnlySeededIdentifiersResolveToTheGeneratedVideo() async {
        let real = await StudioHRTimingSeed.asset(forLocalIdentifier: "3F2A1B0C-1234-4D5E-8F90-ABCDEF012345/L0/001")
        XCTAssertNil(real, "a Photos identifier is never answered by the seed")
        let bundled = await StudioHRTimingSeed.asset(forLocalIdentifier: "uitest-bundled://recap-uitest-clip.mov")
        XCTAssertNil(bundled)
        let seeded = await StudioHRTimingSeed.asset(forLocalIdentifier: StudioHRTimingSeed.Clip.b.localIdentifier)
        let seconds = try? await seeded?.load(.duration).seconds
        XCTAssertEqual(seconds ?? 0, StudioHRTimingSeed.videoSeconds, accuracy: 0.05)
    }

    func testNothingIsRecordedOnALaunchWithoutTheSeedArgument() {
        XCTAssertFalse(StudioHRTimingSeed.isActive)
        let before = StudioHRTimingDebug.shared.current
        StudioHRTimingDebug.shared.exportPlaced([PlacedClipHR(startSec: 0, durationSec: 1, samples: [])])
        StudioHRTimingDebug.shared.probed("x", BakedAssetProbe(hasEditedRendition: false, currentDuration: 1))
        StudioHRTimingDebug.shared.checked(rows: 1, answered: true, reverted: 1, seconds: 0)
        XCTAssertEqual(StudioHRTimingDebug.shared.current, before)
    }
}
#endif
