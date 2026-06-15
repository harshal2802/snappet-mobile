import XCTest
import CoreGraphics
@testable import Snappet

/// Unit tests for the pure geometry helpers in `ReelExporter` — no AVFoundation, no device,
/// no Photos. Covers `orientedSize` (naturalSize × preferredTransform → display dimensions)
/// and `fitTransform` (orient + uniform scale-to-fit + center into a render canvas).
/// These are the invariants that prevent the -11800 / -12902 regression on mixed-orientation footage.
final class ReelExporterGeometryTests: XCTestCase {

    private let exporter = ReelExporter()

    // MARK: - orientedSize

    func testOrientedSizeIdentityTransformPreservesDimensions() {
        let natural = CGSize(width: 1920, height: 1080)
        let result = exporter.orientedSize(natural, transform: .identity)
        XCTAssertEqual(result.width, 1920, accuracy: 1e-6)
        XCTAssertEqual(result.height, 1080, accuracy: 1e-6)
    }

    func testOrientedSize90DegreeRotationSwapsDimensions() {
        // A landscape 1920x1080 frame rotated 90 degrees should present as 1080x1920.
        let natural = CGSize(width: 1920, height: 1080)
        let t = CGAffineTransform(rotationAngle: .pi / 2)
        let result = exporter.orientedSize(natural, transform: t)
        XCTAssertEqual(result.width, 1080, accuracy: 1e-6)
        XCTAssertEqual(result.height, 1920, accuracy: 1e-6)
    }

    func testOrientedSize180DegreeRotationPreservesDimensions() {
        let natural = CGSize(width: 1920, height: 1080)
        let t = CGAffineTransform(rotationAngle: .pi)
        let result = exporter.orientedSize(natural, transform: t)
        XCTAssertEqual(result.width, 1920, accuracy: 1e-6)
        XCTAssertEqual(result.height, 1080, accuracy: 1e-6)
    }

    func testOrientedSize270DegreeRotationSwapsDimensions() {
        let natural = CGSize(width: 1920, height: 1080)
        let t = CGAffineTransform(rotationAngle: 3 * .pi / 2)
        let result = exporter.orientedSize(natural, transform: t)
        XCTAssertEqual(result.width, 1080, accuracy: 1e-6)
        XCTAssertEqual(result.height, 1920, accuracy: 1e-6)
    }

    func testOrientedSizeAlwaysNonNegativeForAnyMultipleOf90() {
        let natural = CGSize(width: 1080, height: 1920)
        for degrees in [0.0, 90.0, 180.0, 270.0] {
            let t = CGAffineTransform(rotationAngle: degrees * .pi / 180)
            let result = exporter.orientedSize(natural, transform: t)
            XCTAssertGreaterThanOrEqual(result.width, 0, "width non-negative at \(degrees) degrees")
            XCTAssertGreaterThanOrEqual(result.height, 0, "height non-negative at \(degrees) degrees")
        }
    }

    func testOrientedSizePortraitNaturalSizeIdentityUnchanged() {
        // Portrait natural size (e.g. front-facing camera that stores portrait natively).
        let natural = CGSize(width: 1080, height: 1920)
        let result = exporter.orientedSize(natural, transform: .identity)
        XCTAssertEqual(result.width, 1080, accuracy: 1e-6)
        XCTAssertEqual(result.height, 1920, accuracy: 1e-6)
    }

    func testOrientedSizeIPhoneBackCameraPortraitTransform() {
        // Back-camera portrait video: stored 1920x1080 landscape, preferredTransform rotates to portrait.
        // Standard back-camera portrait transform: (a=0, b=1, c=-1, d=0, tx=1920, ty=0)
        let natural = CGSize(width: 1920, height: 1080)
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0)
        let result = exporter.orientedSize(natural, transform: t)
        XCTAssertEqual(result.width, 1080, accuracy: 1e-6)
        XCTAssertEqual(result.height, 1920, accuracy: 1e-6)
    }

    // MARK: - fitTransform

    func testFitTransformSameAspectProducesUniformScaleNoOffset() {
        // Canvas and source have the same aspect (both 16:9) — fit is a pure scale, no letterboxing.
        let source = CGSize(width: 1920, height: 1080)
        let canvas = CGSize(width: 960, height: 540)
        let t = exporter.fitTransform(orientedSize: source, preferred: .identity, renderSize: canvas)
        XCTAssertEqual(t.a, 0.5, accuracy: 1e-6, "uniform x scale")
        XCTAssertEqual(t.d, 0.5, accuracy: 1e-6, "uniform y scale")
        XCTAssertEqual(t.tx, 0, accuracy: 1e-6, "no horizontal offset")
        XCTAssertEqual(t.ty, 0, accuracy: 1e-6, "no vertical offset")
    }

    func testFitTransformSameSourceAndCanvasSizeProducesIdentityLikeTransform() {
        let size = CGSize(width: 1080, height: 1920)
        let t = exporter.fitTransform(orientedSize: size, preferred: .identity, renderSize: size)
        XCTAssertEqual(t.a, 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.d, 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.tx, 0, accuracy: 1e-6)
        XCTAssertEqual(t.ty, 0, accuracy: 1e-6)
    }

    func testFitTransformPortraitSourceIntoLandscapeCanvasLetterboxesHorizontally() {
        // Portrait 1080x1920 into landscape 1920x1080:
        // scale = min(1920/1080, 1080/1920) = 1080/1920 ≈ 0.5625
        // Scaled width fills height; tx = (1920 - 607.5) / 2 = 656.25
        let source = CGSize(width: 1080, height: 1920)
        let canvas = CGSize(width: 1920, height: 1080)
        let t = exporter.fitTransform(orientedSize: source, preferred: .identity, renderSize: canvas)
        let expectedScale = min(canvas.width / source.width, canvas.height / source.height)
        XCTAssertEqual(t.a, expectedScale, accuracy: 1e-6, "uniform scale a")
        XCTAssertEqual(t.d, expectedScale, accuracy: 1e-6, "uniform scale d")
        let expectedTx = (canvas.width - source.width * expectedScale) / 2
        XCTAssertEqual(t.tx, expectedTx, accuracy: 1e-6, "centers horizontally")
        XCTAssertEqual(t.ty, 0, accuracy: 1e-6, "height fills canvas, no vertical offset")
    }

    func testFitTransformLandscapeSourceIntoPortraitCanvasLetterboxesVertically() {
        // Landscape 1920x1080 into portrait 1080x1920:
        // scale = min(1080/1920, 1920/1080) = 1080/1920 ≈ 0.5625
        // Scaled width fills; ty = (1920 - 607.5) / 2 = 656.25
        let source = CGSize(width: 1920, height: 1080)
        let canvas = CGSize(width: 1080, height: 1920)
        let t = exporter.fitTransform(orientedSize: source, preferred: .identity, renderSize: canvas)
        let expectedScale = min(canvas.width / source.width, canvas.height / source.height)
        XCTAssertEqual(t.a, expectedScale, accuracy: 1e-6, "uniform scale a")
        XCTAssertEqual(t.d, expectedScale, accuracy: 1e-6, "uniform scale d")
        XCTAssertEqual(t.tx, 0, accuracy: 1e-6, "width fills canvas, no horizontal offset")
        let expectedTy = (canvas.height - source.height * expectedScale) / 2
        XCTAssertEqual(t.ty, expectedTy, accuracy: 1e-6, "centers vertically")
    }

    func testFitTransformNeverDistorts() {
        // Scale on both axes must always be equal (no stretching).
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 1440, height: 2560), CGSize(width: 1920, height: 1080)),
            (CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1080)),
            (CGSize(width: 1080, height: 1080), CGSize(width: 1920, height: 1080)),
            (CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1920)),
        ]
        for (source, canvas) in cases {
            let t = exporter.fitTransform(orientedSize: source, preferred: .identity, renderSize: canvas)
            XCTAssertEqual(t.a, t.d, accuracy: 1e-9,
                           "uniform scale (no distortion) for source=\(source) canvas=\(canvas)")
        }
    }

    func testFitTransformScaledSourceNeverExceedsCanvas() {
        // The scaled source must fit inside the canvas on both axes.
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)),
            (CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)),
            (CGSize(width: 640, height: 480), CGSize(width: 1920, height: 1080)),
        ]
        for (source, canvas) in cases {
            let t = exporter.fitTransform(orientedSize: source, preferred: .identity, renderSize: canvas)
            let scaledW = source.width * t.a
            let scaledH = source.height * t.d
            XCTAssertLessThanOrEqual(scaledW, canvas.width + 1e-6,
                                     "scaled width must not exceed canvas")
            XCTAssertLessThanOrEqual(scaledH, canvas.height + 1e-6,
                                     "scaled height must not exceed canvas")
        }
    }

    func testFitTransformDegenerateZeroSourceReturnsPreferredTransform() {
        // A zero-size source is degenerate — the guard returns preferred unchanged.
        let preferred = CGAffineTransform(translationX: 100, y: 200)
        let t = exporter.fitTransform(orientedSize: .zero, preferred: preferred,
                                      renderSize: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(t.tx, preferred.tx, accuracy: 1e-6)
        XCTAssertEqual(t.ty, preferred.ty, accuracy: 1e-6)
        XCTAssertEqual(t.a, preferred.a, accuracy: 1e-6)
    }

    func testFitTransformOutputFillsExactlyWhenAspectMatches() {
        // When source and canvas share the same aspect ratio, both axes fill exactly.
        let source = CGSize(width: 1920, height: 1080)  // 16:9
        let canvas = CGSize(width: 1280, height: 720)   // also 16:9
        let t = exporter.fitTransform(orientedSize: source, preferred: .identity, renderSize: canvas)
        let scaledW = source.width * t.a
        let scaledH = source.height * t.d
        XCTAssertEqual(scaledW, canvas.width, accuracy: 1e-6, "width fills canvas")
        XCTAssertEqual(scaledH, canvas.height, accuracy: 1e-6, "height fills canvas")
    }
}
