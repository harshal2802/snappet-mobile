import XCTest
import CoreGraphics
@testable import Snappet

/// Unit tests for the **pure** B3 clip-editor geometry/timing math — no device, no AVFoundation,
/// no SwiftUI. Exercises trim→time-window (clamp/order), speed→scaled duration, split→two
/// adjacent non-overlapping trims, normalized crop-rect→transform + position→layer-point, and
/// output renderSize per aspect. The rendered output (cropped, text-overlaid, speed-ramped video)
/// is device-pending (the sim has no Photos/video); these prove the math's shape with synthetic
/// inputs (decisions.md 2026-06-01, B3).
final class ClipEditGeometryTests: XCTestCase {

    typealias G = ClipEditGeometry

    // MARK: - Trim → time window

    func testTrimWindowKeepsValidRange() throws {
        let w = try XCTUnwrap(G.trimWindow(start: 2, end: 8, assetDuration: 10))
        XCTAssertEqual(w.start, 2, accuracy: 1e-9)
        XCTAssertEqual(w.end, 8, accuracy: 1e-9)
        XCTAssertEqual(w.duration, 6, accuracy: 1e-9)
    }

    func testTrimWindowClampsToAssetDuration() throws {
        let w = try XCTUnwrap(G.trimWindow(start: -5, end: 100, assetDuration: 10))
        XCTAssertEqual(w.start, 0, accuracy: 1e-9)
        XCTAssertEqual(w.end, 10, accuracy: 1e-9)
    }

    func testTrimWindowInvertedCollapsesToMinSlice() throws {
        // end <= start → a minimal valid slice, never zero/negative.
        let w = try XCTUnwrap(G.trimWindow(start: 8, end: 3, assetDuration: 10, minDuration: 0.05))
        XCTAssertGreaterThanOrEqual(w.duration, 0.05 - 1e-9)
        XCTAssertGreaterThan(w.end, w.start)
        XCTAssertLessThanOrEqual(w.end, 10)
    }

    func testTrimWindowZeroAssetReturnsNil() {
        XCTAssertNil(G.trimWindow(start: 0, end: 1, assetDuration: 0))
    }

    func testTrimWindowStartAlwaysLessThanEnd() throws {
        for (s, e, d) in [(0.0, 5.0, 5.0), (5.0, 5.0, 10.0), (9.99, 10.0, 10.0), (3.0, 2.0, 10.0)] {
            let w = try XCTUnwrap(G.trimWindow(start: s, end: e, assetDuration: d))
            XCTAssertLessThan(w.start, w.end, "start<end for (\(s),\(e),\(d))")
            XCTAssertGreaterThanOrEqual(w.start, 0)
            XCTAssertLessThanOrEqual(w.end, d + 1e-9)
        }
    }

    // MARK: - Speed → scaled output duration

    func testSpeedDoubleHalvesDuration() {
        XCTAssertEqual(G.scaledDuration(sourceDuration: 10, speed: 2.0), 5, accuracy: 1e-9)
    }

    func testSpeedHalfDoublesDuration() {
        XCTAssertEqual(G.scaledDuration(sourceDuration: 10, speed: 0.5), 20, accuracy: 1e-9)
    }

    func testSpeedOneIsUnchanged() {
        XCTAssertEqual(G.scaledDuration(sourceDuration: 7.5, speed: 1.0), 7.5, accuracy: 1e-9)
    }

    func testSpeedClampedToRange() {
        XCTAssertEqual(G.clampSpeed(0.0), 0.25, accuracy: 1e-9)
        XCTAssertEqual(G.clampSpeed(99), 4.0, accuracy: 1e-9)
        XCTAssertEqual(G.clampSpeed(1.5), 1.5, accuracy: 1e-9)
        // A degenerate 0 speed clamps, so duration stays finite & positive.
        let d = G.scaledDuration(sourceDuration: 10, speed: 0)
        XCTAssertTrue(d.isFinite && d > 0)
    }

    // MARK: - Split → two adjacent, non-overlapping trims

    func testSplitProducesAdjacentNonOverlappingHalves() throws {
        let window = try XCTUnwrap(G.trimWindow(start: 0, end: 10, assetDuration: 10))
        let (a, b) = try XCTUnwrap(G.split(window, at: 4))
        XCTAssertEqual(a.start, 0, accuracy: 1e-9)
        XCTAssertEqual(a.end, 4, accuracy: 1e-9)
        XCTAssertEqual(b.start, 4, accuracy: 1e-9)   // adjacent: a.end == b.start
        XCTAssertEqual(b.end, 10, accuracy: 1e-9)
        XCTAssertEqual(a.end, b.start, accuracy: 1e-9)            // no gap
        XCTAssertEqual(a.duration + b.duration, window.duration, accuracy: 1e-9)  // no overlap, exhaustive
    }

    func testSplitClampsCutInsideWindowSoBothHalvesValid() throws {
        let window = try XCTUnwrap(G.trimWindow(start: 0, end: 10, assetDuration: 10))
        // Cut beyond the end clamps so the second half keeps ≥ minDuration.
        let (a, b) = try XCTUnwrap(G.split(window, at: 1000, minDuration: 0.05))
        XCTAssertGreaterThanOrEqual(a.duration, 0.05 - 1e-9)
        XCTAssertGreaterThanOrEqual(b.duration, 0.05 - 1e-9)
        XCTAssertEqual(a.end, b.start, accuracy: 1e-9)
    }

    func testSplitTooShortWindowReturnsNil() throws {
        let window = try XCTUnwrap(G.trimWindow(start: 0, end: 0.05, assetDuration: 1))
        XCTAssertNil(G.split(window, at: 0.025, minDuration: 0.05))
    }

    // MARK: - Output renderSize per aspect

    func testRenderSizePortraitFromLandscapeSource() {
        // A 1920×1080 (landscape) source normalized to 9:16 → portrait canvas, even dims.
        let size = G.renderSize(for: .portrait9x16, sourceSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(size.height, 1920, accuracy: 1)       // long edge preserved as height
        XCTAssertEqual(size.width, 1920 * 9 / 16, accuracy: 1)
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
    }

    func testRenderSizeSquare() {
        let size = G.renderSize(for: .square1x1, sourceSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(size.width, size.height)
        XCTAssertEqual(size.width, 1920, accuracy: 1)
    }

    func testRenderSizeLandscapeFromPortraitSource() {
        let size = G.renderSize(for: .landscape16x9, sourceSize: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(size.width, 1920, accuracy: 1)        // long edge preserved as width
        XCTAssertEqual(size.height, 1080, accuracy: 1)
    }

    func testRenderSizeOriginalEvenized() {
        let size = G.renderSize(for: .original, sourceSize: CGSize(width: 1081, height: 607))
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.width, 1082)   // rounded up to even
        XCTAssertEqual(size.height, 608)
    }

    func testRenderSizeAlwaysPositiveEvenForDegenerateSource() {
        for aspect in G.OutputAspect.allCases {
            let size = G.renderSize(for: aspect, sourceSize: .zero)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    // MARK: - Crop rect → transform

    func testFullFrameCropAspectFillsSourceIntoRender() {
        // Full-frame crop of a 1000×1000 source into a 500×500 render → uniform 0.5 scale, no offset.
        let t = G.cropTransform(cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                sourceSize: CGSize(width: 1000, height: 1000),
                                renderSize: CGSize(width: 500, height: 500))
        XCTAssertEqual(t.a, 0.5, accuracy: 1e-6)
        XCTAssertEqual(t.d, 0.5, accuracy: 1e-6)
        XCTAssertEqual(t.tx, 0, accuracy: 1e-6)
        XCTAssertEqual(t.ty, 0, accuracy: 1e-6)
    }

    func testCenterCropZoomsAndTranslates() {
        // Crop the centered middle 50% of a 1000×1000 source into a 500×500 render.
        let t = G.cropTransform(cropRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                sourceSize: CGSize(width: 1000, height: 1000),
                                renderSize: CGSize(width: 500, height: 500))
        // cropped region is 500×500 px → scale = 500/500 = 1.0
        XCTAssertEqual(t.a, 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.d, 1.0, accuracy: 1e-6)
        // translate so the crop origin (250,250) lands at the canvas origin → tx = -250.
        XCTAssertEqual(t.tx, -250, accuracy: 1e-6)
        XCTAssertEqual(t.ty, -250, accuracy: 1e-6)
    }

    func testDegenerateCropRectIsSanitizedNotNaN() {
        let t = G.cropTransform(cropRect: CGRect(x: 0, y: 0, width: 0, height: 0),
                                sourceSize: CGSize(width: 1000, height: 1000),
                                renderSize: CGSize(width: 500, height: 500))
        XCTAssertTrue(t.a.isFinite && t.d.isFinite && t.tx.isFinite && t.ty.isFinite)
        XCTAssertGreaterThan(t.a, 0)
    }

    func testSanitizedCropRectClampsIntoUnitSquare() {
        let r = G.sanitizedCropRect(CGRect(x: -1, y: 2, width: 5, height: 0))
        XCTAssertGreaterThanOrEqual(r.minX, 0)
        XCTAssertGreaterThanOrEqual(r.minY, 0)
        XCTAssertLessThanOrEqual(r.maxX, 1 + 1e-9)
        XCTAssertLessThanOrEqual(r.maxY, 1 + 1e-9)
        XCTAssertGreaterThanOrEqual(r.height, 0.05 - 1e-9)
    }

    // MARK: - Normalized position → CALayer point (y flipped)

    func testLayerPointFlipsYForBottomLeftOrigin() {
        let size = CGSize(width: 400, height: 800)
        // Top-center (0.5, 0.0) → x=200, y=800 (top in CALayer's bottom-left space).
        let top = G.layerPoint(normalized: CGPoint(x: 0.5, y: 0.0), in: size)
        XCTAssertEqual(top.x, 200, accuracy: 1e-9)
        XCTAssertEqual(top.y, 800, accuracy: 1e-9)
        // Bottom-center (0.5, 1.0) → y=0.
        let bottom = G.layerPoint(normalized: CGPoint(x: 0.5, y: 1.0), in: size)
        XCTAssertEqual(bottom.y, 0, accuracy: 1e-9)
        // Center → exact middle.
        let center = G.layerPoint(normalized: CGPoint(x: 0.5, y: 0.5), in: size)
        XCTAssertEqual(center, CGPoint(x: 200, y: 400))
    }

    func testLayerPointClampsOutOfRangeNormalized() {
        let size = CGSize(width: 100, height: 100)
        let p = G.layerPoint(normalized: CGPoint(x: 2, y: -1), in: size)
        XCTAssertEqual(p.x, 100, accuracy: 1e-9)   // clamped to 1.0 * width
        XCTAssertEqual(p.y, 100, accuracy: 1e-9)   // clamped to 0.0 (top) → flipped to height
    }
}
