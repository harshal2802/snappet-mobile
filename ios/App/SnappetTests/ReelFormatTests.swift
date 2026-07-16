import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the pure reel-builder upgrades (highlights P1): the export format presets and
/// the per-highlight intensity badge math. No device, no AVFoundation.
final class ReelFormatTests: XCTestCase {

    // MARK: - Format presets

    func testNativeHasNoForcedAspect() {
        XCTAssertNil(ReelFormat.native.aspect, "native keeps the first segment's canvas")
    }

    func testPresetAspectsMatchTheirNames() {
        XCTAssertEqual(ReelFormat.story.aspect!, 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(ReelFormat.portrait.aspect!, 4.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(ReelFormat.square.aspect!, 1.0, accuracy: 1e-9)
    }

    func testLabelsAreUniqueAndNonEmpty() {
        let labels = ReelFormat.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertFalse(labels.contains(where: \.isEmpty))
    }

    // MARK: - Intensity: peak BPM in a highlight window

    private let hr: [HRSample] = [
        HRSample(t: 0, bpm: 90), HRSample(t: 10, bpm: 120),
        HRSample(t: 20, bpm: 168), HRSample(t: 30, bpm: 140),
    ]

    func testPeakPicksTheHighestSampleInsideTheWindow() {
        XCTAssertEqual(ReelIntensity.peakBpm(hr: hr, start: 5, end: 25), 168)
    }

    func testPeakBoundsAreInclusive() {
        XCTAssertEqual(ReelIntensity.peakBpm(hr: hr, start: 20, end: 20), 168)
    }

    func testPeakIsNilWhenNoSampleLandsInTheWindow() {
        XCTAssertNil(ReelIntensity.peakBpm(hr: hr, start: 40, end: 60),
                     "no HR in the window → the row falls back to the engine score")
        XCTAssertNil(ReelIntensity.peakBpm(hr: [], start: 0, end: 30))
    }

    func testInvertedWindowIsNil() {
        XCTAssertNil(ReelIntensity.peakBpm(hr: hr, start: 25, end: 5))
    }

    // MARK: - Intensity: %HRR fraction (badge tint)

    func testFractionIsKarvonen() {
        // rest 60, max 190 → (168-60)/(190-60) ≈ 0.83 — lands in the "hard" band.
        XCTAssertEqual(ReelIntensity.fraction(peakBpm: 168, restBpm: 60, maxBpm: 190),
                       108.0 / 130.0, accuracy: 1e-9)
    }

    func testFractionClampsToUnitRange() {
        XCTAssertEqual(ReelIntensity.fraction(peakBpm: 300, restBpm: 60, maxBpm: 190), 1)
        XCTAssertEqual(ReelIntensity.fraction(peakBpm: 40, restBpm: 60, maxBpm: 190), 0)
    }

    func testFractionUsesDefaultsWhenProfileMissing() {
        let f = ReelIntensity.fraction(peakBpm: 125, restBpm: nil, maxBpm: nil)
        XCTAssertEqual(f, (125 - ReelIntensity.defaultRestBpm)
                          / (ReelIntensity.defaultMaxBpm - ReelIntensity.defaultRestBpm),
                       accuracy: 1e-9)
    }

    func testDegenerateProfileIsSafe() {
        XCTAssertEqual(ReelIntensity.fraction(peakBpm: 100, restBpm: 190, maxBpm: 190), 0,
                       "max ≤ rest must not divide by zero")
    }
}
