import XCTest
@testable import Snappet

/// The image comparison behind the Studio's golden frames (prompt 304), on images made in the test.
final class StudioGoldenCompareTests: XCTestCase {

    private let tolerance = StudioGoldenTolerance(luma: 12, chroma: 12, maxFraction: 0.002, maxCellFraction: 0.08)

    /// 180×320, grey, with a white 30×30 block.
    private func frame(blockX: Int = 60, blockY: Int = 145) -> StudioGoldenImage {
        var image = StudioGoldenImage(width: 180, height: 320, r: 90, g: 120, b: 150)
        image.fill(x: blockX, y: blockY, width: 30, height: 30, r: 255, g: 255, b: 255)
        return image
    }

    /// The same image with every channel moved by a repeatable amount in `-amount ... amount`.
    private func noisy(_ image: StudioGoldenImage, amount: Int) -> StudioGoldenImage {
        var out = image
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in out.rgba.indices where i % 4 != 3 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let step = Int((state >> 33) % UInt64(2 * amount + 1)) - amount
            out.rgba[i] = UInt8(min(255, max(0, Int(out.rgba[i]) + step)))
        }
        return out
    }

    func testIdenticalImagesPass() {
        let result = StudioGoldenCompare.compare(actual: frame(), golden: frame(), tolerance: tolerance)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.differing, 0)
        XCTAssertEqual(result.maxLuma, 0)
        XCTAssertEqual(result.maxChroma, 0)
        XCTAssertNil(result.worst)
        XCTAssertEqual(result.total, 180 * 320)
    }

    /// Every channel of every pixel moved by up to 12: no pixel's brightness can be more than
    /// 12 away, and the noise averages out of the colour.
    func testNoiseWithinTheTolerancePasses() {
        let result = StudioGoldenCompare.compare(actual: noisy(frame(), amount: 12), golden: frame(), tolerance: tolerance)
        XCTAssertTrue(result.passed, result.summary)
        XCTAssertEqual(result.differing, 0)
        XCTAssertGreaterThan(result.maxLuma, 4)
        XCTAssertLessThanOrEqual(result.maxLuma, 12)
        XCTAssertLessThan(result.maxChroma, 4)
    }

    func testNoiseAboveTheToleranceFails() {
        let result = StudioGoldenCompare.compare(actual: noisy(frame(), amount: 60), golden: frame(), tolerance: tolerance)
        XCTAssertFalse(result.passed)
        XCTAssertGreaterThan(result.fraction, 0.2)
    }

    // MARK: Colour is compared after averaging

    /// (200, 92, 116) is as bright as the grey (90, 120, 150) and a very different colour.
    private let sameBrightness: (r: UInt8, g: UInt8, b: UInt8) = (200, 92, 116)

    /// What a video file does to a sharp colour edge: a line of pixels with the wrong colour and
    /// the right brightness. It passes.
    func testAOnePixelLineOfAnotherColourWithTheSameBrightnessPasses() {
        var actual = frame()
        actual.fill(x: 20, y: 0, width: 1, height: 140, r: sameBrightness.r, g: sameBrightness.g, b: sameBrightness.b)
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        XCTAssertEqual(result.differing, 0, result.summary)
        XCTAssertLessThanOrEqual(result.maxLuma, 1)
        XCTAssertEqual(result.maxChroma, 9, "an eighth of the colour difference of 69")
        XCTAssertTrue(result.passed)
    }

    /// An area of another colour with the same brightness (a wrong filter, a wrong clip) fails.
    func testAnAreaOfAnotherColourWithTheSameBrightnessFails() {
        var actual = frame()
        actual.fill(x: 20, y: 20, width: 20, height: 20, r: sameBrightness.r, g: sameBrightness.g, b: sameBrightness.b)
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        XCTAssertLessThanOrEqual(result.maxLuma, 1)
        XCTAssertEqual(result.maxChroma, 69)
        XCTAssertGreaterThan(result.differing, 400)
        XCTAssertFalse(result.passed, result.summary)
    }

    /// The block one frame further along (3 pixels): a strip on each side of it changes.
    func testABlockShiftedByThreePixelsFails() {
        let result = StudioGoldenCompare.compare(actual: frame(blockX: 63), golden: frame(), tolerance: tolerance)
        XCTAssertFalse(result.passed, result.summary)
        XCTAssertEqual(result.differing, 2 * 3 * 30)
        XCTAssertEqual(result.maxLuma, 139, "white against the grey's brightness of 116")
        XCTAssertEqual(result.maxChroma, 7, "three columns of eight changed colour")
        // 180 pixels are 0.31 % of the frame, above the 0.2 % allowed; and one region holds a
        // large share of them.
        XCTAssertGreaterThan(result.fraction, tolerance.maxFraction)
        XCTAssertGreaterThan(result.worst?.fraction ?? 0, tolerance.maxCellFraction)
    }

    func testAMissingBlockFailsAndTheWorstRegionIsInsideIt() throws {
        let empty = StudioGoldenImage(width: 180, height: 320, r: 90, g: 120, b: 150)
        let result = StudioGoldenCompare.compare(actual: empty, golden: frame(), tolerance: tolerance)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.differing, 900)
        let worst = try XCTUnwrap(result.worst)
        // The block covers x 60…89, y 145…174. The first square that is wholly inside it starts
        // at x 64, y 152 (squares start every 8 pixels).
        XCTAssertEqual(worst.x, 64)
        XCTAssertEqual(worst.y, 152)
        XCTAssertEqual(worst.differing, 256)
        XCTAssertEqual(worst.fraction, 1, accuracy: 1e-9)
        XCTAssertTrue(result.summary.contains("worst region x 64–79, y 152–167"), result.summary)
    }

    /// A small element in the wrong place is a small share of the frame. The one-region rule is
    /// what fails it.
    func testASmallPatchInOnePlaceFailsAlthoughItIsUnderTheFrameAllowance() {
        var actual = frame()
        actual.fill(x: 16, y: 16, width: 8, height: 8, r: 0, g: 0, b: 0)           // 64 px = 0.11 %
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        XCTAssertLessThan(result.fraction, tolerance.maxFraction)
        XCTAssertEqual(result.worst?.differing, 64)
        XCTAssertFalse(result.passed, "64 of one region's 256 pixels is 25 %, above the 8 % allowed")
    }

    /// The same number of pixels spread over the frame is what an encoder does to edges: it passes.
    func testTheSameNumberOfPixelsSpreadOutPasses() {
        var actual = frame()
        for n in 0 ..< 64 {                                       // one pixel in each of 64 regions
            actual.fill(x: (n % 8) * 20 + 3, y: (n / 8) * 36 + 5, width: 1, height: 1, r: 0, g: 0, b: 0)
        }
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        XCTAssertEqual(result.differing, 64)
        XCTAssertTrue(result.passed, result.summary)
    }

    func testTooManyScatteredPixelsFailTheFrameAllowance() {
        var actual = frame()
        for y in stride(from: 0, to: 320, by: 8) {                // 40 × 23 = 920 px = 1.6 %, 4 per region
            for x in stride(from: 0, to: 180, by: 8) { actual.fill(x: x, y: y, width: 1, height: 1, r: 0, g: 0, b: 0) }
        }
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        XCTAssertLessThan(result.worst?.fraction ?? 1, tolerance.maxCellFraction)
        XCTAssertGreaterThan(result.fraction, tolerance.maxFraction)
        XCTAssertFalse(result.passed)
    }

    func testADifferentSizeFails() {
        let small = StudioGoldenImage(width: 90, height: 160, r: 90, g: 120, b: 150)
        let result = StudioGoldenCompare.compare(actual: small, golden: frame(), tolerance: tolerance)
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.sizeMatches)
        XCTAssertEqual(result.summary, "size 90×160, golden is 180×320")
        XCTAssertNil(StudioGoldenCompare.diffImage(actual: small, golden: frame(), tolerance: tolerance))
    }

    /// 180 is not a multiple of 8: the last square is cut by the edge, and is still measured
    /// against a whole square.
    func testAnEdgeRegionIsCutToTheImageAndMeasuredAgainstAWholeSquare() throws {
        var actual = frame()
        actual.fill(x: 176, y: 0, width: 4, height: 16, r: 0, g: 0, b: 0)
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        let worst = try XCTUnwrap(result.worst)
        XCTAssertEqual(worst.x, 168)
        XCTAssertEqual(worst.width, 12)
        XCTAssertEqual(worst.height, 16)
        XCTAssertEqual(worst.differing, 64)
        XCTAssertEqual(worst.fraction, 0.25, accuracy: 1e-9)
    }

    /// A strip that lies across the line between two squares is still counted whole by the
    /// square that overlaps both.
    func testAStripAcrossTwoSquaresIsCountedWhole() {
        var actual = frame()
        actual.fill(x: 14, y: 32, width: 4, height: 16, r: 0, g: 0, b: 0)           // x 14…17
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        XCTAssertEqual(result.worst?.differing, 64)
        XCTAssertEqual(result.worst?.x, 8)
    }

    func testAnImageSmallerThanOneSquare() {
        let golden = StudioGoldenImage(width: 4, height: 4, r: 0, g: 0, b: 0)
        let actual = StudioGoldenImage(width: 4, height: 4, r: 255, g: 0, b: 0)
        let result = StudioGoldenCompare.compare(actual: actual, golden: golden, tolerance: tolerance)
        XCTAssertEqual(result.differing, 16)
        XCTAssertEqual(result.worst, .init(x: 0, y: 0, width: 4, height: 4, differing: 16))
        XCTAssertFalse(result.passed)
    }

    func testDiffImageMarksOnlyTheDifferingPixels() throws {
        let golden = frame()
        let diff = try XCTUnwrap(StudioGoldenCompare.diffImage(actual: frame(blockX: 63), golden: golden,
                                                               tolerance: tolerance))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(diff.rgba[(y * 180 + x) * 4 ..< (y * 180 + x) * 4 + 3]) }
        XCTAssertEqual(pixel(61, 150), [255, 0, 255], "where the block was and is not")
        XCTAssertEqual(pixel(91, 150), [255, 0, 255], "where the block is and was not")
        XCTAssertEqual(pixel(75, 150), [85, 85, 85], "unchanged: the rendered pixel at a third")
        XCTAssertEqual(pixel(10, 10), [30, 40, 50])
        let marked = stride(from: 0, to: diff.rgba.count, by: 4).filter {
            diff.rgba[$0] == 255 && diff.rgba[$0 + 1] == 0 && diff.rgba[$0 + 2] == 255
        }.count
        XCTAssertEqual(marked, 180)
    }

    func testSummaryNamesTheNumbers() {
        let result = StudioGoldenCompare.compare(actual: frame(blockX: 63), golden: frame(), tolerance: tolerance)
        XCTAssertTrue(result.summary.hasPrefix(
            "180 of 57600 pixels differ (0.31%, allowed 0.20%), largest brightness difference 139 (allowed 12), "
            + "largest colour difference 7 (allowed 12); worst region x "), result.summary)
    }

    func testPNGRoundTripKeepsEveryPixel() throws {
        let image = noisy(frame(), amount: 40)
        let data = try XCTUnwrap(StudioGoldenRenderer.pngData(image))
        XCTAssertEqual(StudioGoldenRenderer.image(pngData: data), image)
    }
}
