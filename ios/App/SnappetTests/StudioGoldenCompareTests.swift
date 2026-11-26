import XCTest
@testable import Snappet

/// The image comparison behind the Studio's golden frames (prompt 304), on images made in the test.
final class StudioGoldenCompareTests: XCTestCase {

    private let tolerance = StudioGoldenTolerance(luma: 12, chroma: 12, maxFraction: 0.002, maxCellFraction: 0.08, mean: 255)

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

    // MARK: The mean colour of a region

    /// 180×320, one colour, no block.
    private var plain: StudioGoldenImage { StudioGoldenImage(width: 180, height: 320, r: 90, g: 120, b: 150) }

    /// Every pixel 4 levels redder: far under the per-pixel limits, and exactly 4 in every
    /// region's mean.
    func testASmallShiftEverywhereIsMeasuredByTheRegionMean() {
        var actual = plain
        for i in stride(from: 0, to: actual.rgba.count, by: 4) { actual.rgba[i] += 4 }
        var limit = tolerance
        limit.mean = 4
        let allowed = StudioGoldenCompare.compare(actual: actual, golden: plain, tolerance: limit)
        XCTAssertEqual(allowed.differing, 0)
        XCTAssertEqual(allowed.maxMean, 4, accuracy: 1e-9)
        XCTAssertTrue(allowed.passed, allowed.summary)
        limit.mean = 3.9
        let refused = StudioGoldenCompare.compare(actual: actual, golden: plain, tolerance: limit)
        XCTAssertEqual(refused.differing, 0, "no pixel is over the per-pixel limits")
        XCTAssertFalse(refused.passed)
        XCTAssertTrue(refused.summary.contains("largest region mean difference 4.0 (allowed 3.9) at x 0–15, y 0–15"),
                      refused.summary)
    }

    /// Noise has no mean: every channel of every pixel moved by up to 12, and no region's mean
    /// moves by as much as 1.5.
    func testNoiseDoesNotMoveARegionsMean() {
        // A plain mid-tone image, so no channel is clipped at 0 or 255 (clipping would bias the mean).
        let result = StudioGoldenCompare.compare(actual: noisy(plain, amount: 12), golden: plain, tolerance: tolerance)
        XCTAssertLessThan(result.maxMean, 2.5)
        XCTAssertGreaterThan(result.maxMean, 0)
    }

    /// The mean is signed per channel: a region half 10 brighter and half 10 darker has a mean
    /// difference of 0, and a region with one channel up and another down reports the larger.
    func testTheRegionMeanIsPerChannelAndSigned() {
        var checker = plain
        for y in 0 ..< 320 {
            for x in 0 ..< 180 {
                let i = (y * 180 + x) * 4
                checker.rgba[i + 1] = UInt8(Int(checker.rgba[i + 1]) + ((x + y) % 2 == 0 ? 10 : -10))
            }
        }
        XCTAssertEqual(StudioGoldenCompare.compare(actual: checker, golden: plain, tolerance: tolerance).maxMean, 0)
        var tinted = plain
        for i in stride(from: 0, to: tinted.rgba.count, by: 4) { tinted.rgba[i] += 3; tinted.rgba[i + 2] -= 7 }
        XCTAssertEqual(StudioGoldenCompare.compare(actual: tinted, golden: plain, tolerance: tolerance).maxMean, 7)
    }

    /// A square cut by the image's edge takes its mean over the pixels it has.
    func testAnEdgeRegionsMeanIsOverItsOwnPixels() throws {
        var actual = frame()
        actual.fill(x: 168, y: 0, width: 12, height: 16, r: 100, g: 120, b: 150)     // red +10 in the last square
        let result = StudioGoldenCompare.compare(actual: actual, golden: frame(), tolerance: tolerance)
        XCTAssertEqual(result.maxMean, 10)
        XCTAssertEqual(result.meanRegion, .init(x: 168, y: 0, width: 12, height: 16, differing: 0))
    }

    func testDiffImageOutlinesARegionWhoseMeanIsOff() throws {
        var actual = frame()
        for y in 32 ..< 48 { for x in 32 ..< 48 { actual.rgba[(y * 180 + x) * 4] += 8 } }
        var limit = tolerance
        limit.mean = 6
        let diff = try XCTUnwrap(StudioGoldenCompare.diffImage(actual: actual, golden: frame(), tolerance: limit))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(diff.rgba[(y * 180 + x) * 4 ..< (y * 180 + x) * 4 + 3]) }
        XCTAssertEqual(pixel(32, 32), [255, 230, 0], "the corner of the square whose mean is 8 off")
        XCTAssertEqual(pixel(47, 40), [255, 230, 0])
        XCTAssertEqual(pixel(40, 40), [32, 40, 50], "inside: the rendered pixel at a third")
        XCTAssertEqual(pixel(100, 100), [30, 40, 50])
    }

    // MARK: At the tolerances the golden tests use

    private let export = StudioSelfCheck.tolerance(for: .export, on: .simulator)
    private let preview = StudioSelfCheck.tolerance(for: .preview, on: .simulator)

    /// A fixture frame, as the golden image.
    private var scene: StudioGoldenImage { StudioGoldenPattern.frame(.portraitA, index: 10) }

    private func assertFailsOnBoth(_ actual: StudioGoldenImage, _ golden: StudioGoldenImage, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for (name, tolerance) in [("export", export), ("preview", preview)] {
            let result = StudioGoldenCompare.compare(actual: actual, golden: golden, tolerance: tolerance)
            XCTAssertFalse(result.passed, "\(what) passed at the simulator's \(name) tolerance: \(result.summary)",
                           file: file, line: line)
        }
    }

    /// The control: a little noise on the same picture passes at both.
    func testTheSamePictureWithALittleNoisePassesAtBothTolerances() {
        for tolerance in [export, preview] {
            let result = StudioGoldenCompare.compare(actual: noisy(scene, amount: 3), golden: scene, tolerance: tolerance)
            XCTAssertTrue(result.passed, result.summary)
        }
    }

    /// A colour change with no change in brightness and no edge: 8 levels warmer over a 64×64
    /// area. Each pixel is far inside the per-pixel limits; the region mean fails it.
    func testAColourOnlyChangeFailsAtBothTolerances() {
        var actual = scene
        for y in 200 ..< 264 {
            for x in 100 ..< 164 {
                let i = (y * 180 + x) * 4
                actual.rgba[i] += 8
                actual.rgba[i + 2] -= 8
            }
        }
        for tolerance in [export, preview] {
            let result = StudioGoldenCompare.compare(actual: actual, golden: scene, tolerance: tolerance)
            XCTAssertEqual(result.differing, 0, "no pixel is over the brightness or colour limit")
            XCTAssertEqual(result.maxMean, 8)
        }
        assertFailsOnBoth(actual, scene, "a colour-only change")
    }

    /// Overlay-sized elements: a 40×12 dark box and a 24×10 tag that are in the golden image and
    /// not in the frame.
    func testAMissingBoxAndAMissingSmallTagFailAtBothTolerances() {
        var withBox = scene
        withBox.fill(x: 70, y: 203, width: 40, height: 12, r: 20, g: 20, b: 20)
        assertFailsOnBoth(scene, withBox, "a missing 40×12 box")
        var withTag = scene
        withTag.fill(x: 31, y: 247, width: 24, height: 10, r: 20, g: 20, b: 20)
        assertFailsOnBoth(scene, withTag, "a missing 24×10 tag")
    }

    /// A solid white 40×40 box one pixel, and two pixels, to the right of where it belongs. One
    /// pixel is 80 changed pixels of 57,600 — under both frame allowances, and 16 of a region's
    /// 256 — so it is the region mean that fails it on the preview (white against the blue
    /// quarter moves a region's mean red by 12).
    func testASolidBoxOneOrTwoPixelsOutOfPlaceFailsAtBothTolerances() {
        func boxed(at x: Int) -> StudioGoldenImage {
            var image = scene
            image.fill(x: x, y: 230, width: 40, height: 40, r: 255, g: 255, b: 255)
            return image
        }
        let onePixel = StudioGoldenCompare.compare(actual: boxed(at: 21), golden: boxed(at: 20), tolerance: preview)
        XCTAssertEqual(onePixel.differing, 80)
        XCTAssertLessThan(onePixel.fraction, preview.maxFraction)
        XCTAssertLessThan(onePixel.cellFraction, preview.maxCellFraction)
        XCTAssertGreaterThan(onePixel.maxMean, 12)
        assertFailsOnBoth(boxed(at: 21), boxed(at: 20), "a box one pixel out of place")
        assertFailsOnBoth(boxed(at: 22), boxed(at: 20), "a box two pixels out of place")
        assertFailsOnBoth(boxed(at: 20), boxed(at: 21), "a box one pixel out of place, the other way")
    }

    /// A glass tile — 12 % white over the picture — that is in the golden image and not in the
    /// frame. On the preview no single pixel is over the brightness limit of 24.
    func testAMissingFaintGlassTileFailsAtBothTolerances() {
        var withTile = scene
        for y in 130 ..< 190 {
            for x in 30 ..< 150 {
                let i = (y * 180 + x) * 4
                for channel in 0 ..< 3 {
                    let value = Double(withTile.rgba[i + channel])
                    withTile.rgba[i + channel] = UInt8((value + 0.12 * (255 - value)).rounded())
                }
            }
        }
        let onPreview = StudioGoldenCompare.compare(actual: scene, golden: withTile, tolerance: preview)
        XCTAssertLessThan(onPreview.maxLuma, preview.luma)
        XCTAssertGreaterThan(onPreview.maxMean, 15)
        assertFailsOnBoth(scene, withTile, "a missing 12 % white tile")
    }

    func testPNGRoundTripKeepsEveryPixel() throws {
        let image = noisy(frame(), amount: 40)
        let data = try XCTUnwrap(StudioGoldenRenderer.pngData(image))
        XCTAssertEqual(StudioGoldenRenderer.image(pngData: data), image)
    }
}
