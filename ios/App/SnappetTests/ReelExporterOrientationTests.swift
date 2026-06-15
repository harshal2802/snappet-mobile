import XCTest
import CoreGraphics
@testable import Snappet

/// Pure geometry tests for the reel-exporter's mixed-orientation normalisation (#139).
/// No AVFoundation, no Photos, no device — only CGAffineTransform + ClipEditGeometry math.
/// These verify the canvas-selection and letterbox/pillarbox algebra that prevents the
/// VideoToolbox -12902 error when clips of differing orientation are stitched together.
final class ReelExporterOrientationTests: XCTestCase {

    // Convenience alias.
    typealias G = ClipEditGeometry

    // MARK: - Oriented size (CGRect.applying mirrors ReelExporter.orientedSize)

    func testIdentityTransformPreservesNaturalSize() {
        let natSize = CGSize(width: 1920, height: 1080)
        let rect = CGRect(origin: .zero, size: natSize).applying(.identity)
        XCTAssertEqual(abs(rect.width), 1920, accuracy: 1e-4)
        XCTAssertEqual(abs(rect.height), 1080, accuracy: 1e-4)
    }

    func testPortraitPreferredTransformSwapsDimensions() {
        // iPhone portrait video: stored 1920×1080, preferredTransform rotates to portrait.
        // Typical value: a=0, b=1, c=-1, d=0, tx=1080, ty=0 (90° CW + translate to origin).
        let natSize = CGSize(width: 1920, height: 1080)
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let rect = CGRect(origin: .zero, size: natSize).applying(preferred)
        XCTAssertEqual(abs(rect.width), 1080, accuracy: 1e-4, "oriented width = 1080")
        XCTAssertEqual(abs(rect.height), 1920, accuracy: 1e-4, "oriented height = 1920")
    }

    func testUpsideDownTransformPreservesOrientedDimensions() {
        // 180° rotation: a=-1, b=0, c=0, d=-1, tx=natW, ty=natH.
        let natSize = CGSize(width: 1920, height: 1080)
        let preferred = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        let rect = CGRect(origin: .zero, size: natSize).applying(preferred)
        XCTAssertEqual(abs(rect.width), 1920, accuracy: 1e-4, "180° flip keeps landscape width")
        XCTAssertEqual(abs(rect.height), 1080, accuracy: 1e-4, "180° flip keeps landscape height")
    }

    // MARK: - Letterbox / pillarbox via ClipEditGeometry.fitTransform

    func testSameAspectClipFitsExactlyWithNoOffset() {
        // Portrait source into portrait canvas of the exact same size → scale 1, no offset.
        let canvas = CGSize(width: 1080, height: 1920)
        let oriented = CGSize(width: 1080, height: 1920)
        let fit = G.fitTransform(sourceSize: oriented, into: CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(fit.a, 1.0, accuracy: 1e-6, "no scaling needed")
        XCTAssertEqual(fit.tx, 0.0, accuracy: 1e-6, "no horizontal shift")
        XCTAssertEqual(fit.ty, 0.0, accuracy: 1e-6, "no vertical shift")
    }

    func testLandscapeClipLetterboxedIntoPortraitCanvas() {
        // Landscape oriented (1920×1080) into portrait canvas (1080×1920).
        // Scale = min(1080/1920, 1920/1080) = 0.5625 — clip fills canvas width, letterboxed vertically.
        let canvas = CGSize(width: 1080, height: 1920)
        let oriented = CGSize(width: 1920, height: 1080)
        let fit = G.fitTransform(sourceSize: oriented, into: CGRect(origin: .zero, size: canvas))

        let expectedScale: CGFloat = 1080.0 / 1920.0  // ≈ 0.5625
        XCTAssertEqual(fit.a, expectedScale, accuracy: 1e-6, "letterbox scale")
        XCTAssertEqual(fit.tx, 0, accuracy: 1e-6, "fills canvas width → no horizontal offset")

        let scaledH = 1080 * expectedScale
        XCTAssertEqual(fit.ty, (1920 - scaledH) / 2, accuracy: 1e-4, "centred vertically")

        // The letterboxed clip must stay fully inside the canvas.
        let scaledW = 1920 * expectedScale
        XCTAssertLessThanOrEqual(scaledW, canvas.width + 1e-4, "no horizontal overflow")
        XCTAssertLessThanOrEqual(scaledH, canvas.height + 1e-4, "no vertical overflow")
    }

    func testPortraitClipPillarboxedIntoLandscapeCanvas() {
        // Portrait oriented (1080×1920) into landscape canvas (1920×1080).
        // Scale = min(1920/1080, 1080/1920) = 0.5625 — fills canvas height, pillarboxed horizontally.
        let canvas = CGSize(width: 1920, height: 1080)
        let oriented = CGSize(width: 1080, height: 1920)
        let fit = G.fitTransform(sourceSize: oriented, into: CGRect(origin: .zero, size: canvas))

        let expectedScale: CGFloat = 1080.0 / 1920.0
        XCTAssertEqual(fit.a, expectedScale, accuracy: 1e-6, "pillarbox scale")
        XCTAssertEqual(fit.ty, 0, accuracy: 1e-6, "fills canvas height → no vertical offset")

        let scaledW = 1080 * expectedScale
        XCTAssertEqual(fit.tx, (1920 - scaledW) / 2, accuracy: 1e-4, "centred horizontally")

        let scaledH = 1920 * expectedScale
        XCTAssertLessThanOrEqual(scaledW, canvas.width + 1e-4)
        XCTAssertLessThanOrEqual(scaledH, canvas.height + 1e-4)
    }

    // MARK: - Combined preferred + fit stays within canvas

    func testPortraitSegmentInPortraitCanvasStaysInBounds() {
        // preferred rotates a 1920×1080 stored video to a 1080×1920 portrait display.
        // fit into a 1080×1920 canvas → scale=1, combined = preferred.
        let canvas = CGSize(width: 1080, height: 1920)
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let orientedSize = CGSize(width: 1080, height: 1920)
        let fit = G.fitTransform(sourceSize: orientedSize, into: CGRect(origin: .zero, size: canvas))
        let combined = preferred.concatenating(fit)

        // The combined transform must map the natural 1920×1080 rect into [0, canvas].
        let result = CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)).applying(combined)
        XCTAssertGreaterThanOrEqual(result.minX, -1e-3)
        XCTAssertGreaterThanOrEqual(result.minY, -1e-3)
        XCTAssertLessThanOrEqual(result.maxX, canvas.width + 1e-3)
        XCTAssertLessThanOrEqual(result.maxY, canvas.height + 1e-3)
    }

    func testLandscapeSegmentLetterboxedIntoPortraitCanvasStaysInBounds() {
        // A landscape segment (identity preferredTransform, 1920×1080 display size)
        // letterboxed into a portrait canvas (1080×1920).
        let canvas = CGSize(width: 1080, height: 1920)
        let preferred = CGAffineTransform.identity
        let orientedSize = CGSize(width: 1920, height: 1080)
        let fit = G.fitTransform(sourceSize: orientedSize, into: CGRect(origin: .zero, size: canvas))
        let combined = preferred.concatenating(fit)

        let result = CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)).applying(combined)
        XCTAssertGreaterThanOrEqual(result.minX, -1e-3)
        XCTAssertGreaterThanOrEqual(result.minY, -1e-3)
        XCTAssertLessThanOrEqual(result.maxX, canvas.width + 1e-3)
        XCTAssertLessThanOrEqual(result.maxY, canvas.height + 1e-3)
    }

    func testSquareSegmentFitsIntoPortraitCanvasWithPillarbox() {
        // A 1080×1080 square into a 1080×1920 portrait canvas → letterboxed vertically:
        // scale=1 (width already matches), no tx, ty = (1920-1080)/2 = 420.
        let canvas = CGSize(width: 1080, height: 1920)
        let oriented = CGSize(width: 1080, height: 1080)
        let fit = G.fitTransform(sourceSize: oriented, into: CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(fit.a, 1.0, accuracy: 1e-6, "square fills canvas width at scale 1")
        XCTAssertEqual(fit.tx, 0.0, accuracy: 1e-6)
        XCTAssertEqual(fit.ty, (1920 - 1080) / 2, accuracy: 1e-4, "centred vertically with bars")
    }
}
