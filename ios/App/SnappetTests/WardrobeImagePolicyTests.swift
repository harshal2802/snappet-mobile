import XCTest
@testable import Snappet

/// Pure sizing rules for closet photos (wardrobe prompt 03). No simulator, no images —
/// just the arithmetic that decides how big a stored garment photo may be.
final class WardrobeImagePolicyTests: XCTestCase {

    // MARK: fittedSize

    func testFittedSizeClampsLongestEdgeAndPreservesAspect() {
        // The real shape that caused the bug: a 3024×2820 cut-out master.
        let fitted = WardrobeImagePolicy.fittedSize(for: CGSize(width: 3024, height: 2820),
                                                    maxEdge: 1024)
        XCTAssertEqual(max(fitted.width, fitted.height), 1024, accuracy: 1)
        let sourceAspect = 3024.0 / 2820.0
        XCTAssertEqual(fitted.width / fitted.height, sourceAspect, accuracy: 0.01)
    }

    func testFittedSizeClampsPortraitOnHeight() {
        let fitted = WardrobeImagePolicy.fittedSize(for: CGSize(width: 2820, height: 3024),
                                                    maxEdge: 1024)
        XCTAssertEqual(fitted.height, 1024, accuracy: 1)
        XCTAssertLessThan(fitted.width, fitted.height)
    }

    /// Load-bearing: re-encoding must only ever shrink. A small photo passing through the
    /// pipeline (or the migration) must not be blown up and re-compressed.
    func testFittedSizeNeverUpscales() {
        let small = CGSize(width: 200, height: 150)
        XCTAssertEqual(WardrobeImagePolicy.fittedSize(for: small, maxEdge: 1024), small)
        let exact = CGSize(width: 1024, height: 512)
        XCTAssertEqual(WardrobeImagePolicy.fittedSize(for: exact, maxEdge: 1024), exact)
    }

    func testFittedSizePassesThroughDegenerateSizes() {
        XCTAssertEqual(WardrobeImagePolicy.fittedSize(for: .zero, maxEdge: 1024), .zero)
        let noHeight = CGSize(width: 4000, height: 0)
        XCTAssertEqual(WardrobeImagePolicy.fittedSize(for: noHeight, maxEdge: 1024), noHeight)
    }

    // MARK: needsDownscale

    func testNeedsDownscaleOnlyWhenMeaningfullyOver() {
        XCTAssertTrue(WardrobeImagePolicy.needsDownscale(CGSize(width: 3024, height: 2820),
                                                         maxEdge: 1024))
        XCTAssertFalse(WardrobeImagePolicy.needsDownscale(CGSize(width: 1024, height: 800),
                                                          maxEdge: 1024))
        XCTAssertFalse(WardrobeImagePolicy.needsDownscale(CGSize(width: 320, height: 240),
                                                          maxEdge: 1024))
    }

    /// The migration's termination guarantee: whatever `fittedSize` produces must not itself
    /// report as needing work, or the closet would be re-encoded on every single launch.
    func testDownscalingReachesAFixedPoint() {
        for source in [CGSize(width: 3024, height: 2820), CGSize(width: 4032, height: 3024),
                       CGSize(width: 1025, height: 999), CGSize(width: 5000, height: 100)] {
            for maxEdge in [WardrobeImagePolicy.displayMaxEdge,
                            WardrobeImagePolicy.thumbnailMaxEdge] {
                let fitted = WardrobeImagePolicy.fittedSize(for: source, maxEdge: maxEdge)
                XCTAssertFalse(WardrobeImagePolicy.needsDownscale(fitted, maxEdge: maxEdge),
                               "\(source) → \(fitted) still reports as needing downscale at \(maxEdge)")
                // And it is genuinely idempotent, not just under the slack.
                XCTAssertEqual(WardrobeImagePolicy.fittedSize(for: fitted, maxEdge: maxEdge), fitted)
            }
        }
    }

    // MARK: bitmapBytes

    func testBitmapBytesQuantifiesTheOriginalProblem() {
        // What one closet tile used to decode to fill a 96pt square.
        let master = WardrobeImagePolicy.bitmapBytes(for: CGSize(width: 3024, height: 2820))
        XCTAssertEqual(master, 3024 * 2820 * 4)
        XCTAssertGreaterThan(master, 30_000_000)

        // What it decodes to now.
        let thumb = WardrobeImagePolicy.fittedSize(for: CGSize(width: 3024, height: 2820),
                                                   maxEdge: WardrobeImagePolicy.thumbnailMaxEdge)
        XCTAssertLessThan(WardrobeImagePolicy.bitmapBytes(for: thumb), 500_000)
    }

    func testBitmapBytesHonorsScaleAndClampsNegatives() {
        let at3x = WardrobeImagePolicy.bitmapBytes(for: CGSize(width: 100, height: 100), scale: 3)
        XCTAssertEqual(at3x, 300 * 300 * 4)
        XCTAssertEqual(WardrobeImagePolicy.bitmapBytes(for: CGSize(width: -10, height: 10)), 0)
    }

    // MARK: policy constants

    /// The caps must cover the largest on-screen use of each slot, or tiles render soft.
    func testCapsCoverTheLargestOnScreenUses() {
        XCTAssertGreaterThanOrEqual(WardrobeImagePolicy.displayMaxEdge, 240 * 3,
                                    "detail hero is 240pt — 3x needs 720px")
        XCTAssertGreaterThanOrEqual(WardrobeImagePolicy.thumbnailMaxEdge, 100 * 3,
                                    "largest tile use is 100pt — 3x needs 300px")
    }
}
