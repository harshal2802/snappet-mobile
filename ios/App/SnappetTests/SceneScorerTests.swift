import XCTest
import CoreImage
import CoreGraphics
@testable import Snappet

/// #83 Step 1 off-device proof: the Vision/Core Image scene scorer must **demonstrably penalize
/// blurry/empty frames**. We synthesize a sharp, high-detail frame and a flat/blurred one (no real
/// camera needed — runs on the sim) and assert the real scorer ranks them correctly. Plus a pure check
/// of the combination math.
final class SceneScorerTests: XCTestCase {

    // MARK: - Pure combination (always runs, no Vision)

    func testScoreCombinationPenalizesBlurryEmptyFrames() {
        let crisp = SceneFrameSignals(sharpness: 0.9, saliency: 0.8, presence: 0.6)
        let blurryEmpty = SceneFrameSignals(sharpness: 0.05, saliency: 0.05, presence: 0.0)
        XCTAssertGreaterThan(SceneScoring.score(crisp), SceneScoring.score(blurryEmpty))
        // Sharpness gates: even a salient-but-blurry frame loses to a sharp one.
        let salientButBlurry = SceneFrameSignals(sharpness: 0.1, saliency: 1.0, presence: 1.0)
        let sharpPlain = SceneFrameSignals(sharpness: 1.0, saliency: 0.2, presence: 0.0)
        XCTAssertGreaterThan(SceneScoring.score(sharpPlain), SceneScoring.score(salientButBlurry))
    }

    func testScoreIsClampedToUnitRange() {
        XCTAssertEqual(SceneScoring.score(.init(sharpness: 0, saliency: 0, presence: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(SceneScoring.score(.init(sharpness: 1, saliency: 1, presence: 1)), 1, accuracy: 1e-9)
    }

    // MARK: - Real Vision / Core Image metrics on synthesized frames

    /// A sharp, high-frequency frame (fine checkerboard) must score higher than a uniform/empty one —
    /// the actual `sharpnessEnergy` (variance-of-Laplacian) computation, not a stub.
    func testSharpFrameOutscoresFlatFrame() {
        let scorer = SceneScorer()
        let sharp = scorer.frameSignals(Self.checkerboard(side: 256, cell: 8))
        let flat = scorer.frameSignals(Self.solid(side: 256, gray: 0.5))
        XCTAssertGreaterThan(sharp.sharpness, flat.sharpness,
                             "a detailed frame must measure sharper than a flat one")
        // A flat gray frame has essentially no focus energy.
        XCTAssertLessThan(flat.sharpness, sharp.sharpness * 0.5)
    }

    /// End-to-end through `SceneScoring.score` after the same relative normalization the scorer applies:
    /// the flat frame lands at/near 0, the detailed frame well above it.
    func testCombinedSceneScoreFavorsTheDetailedFrame() {
        let scorer = SceneScorer()
        let sharp = scorer.frameSignals(Self.checkerboard(side: 256, cell: 8))
        let flat = scorer.frameSignals(Self.solid(side: 256, gray: 0.5))
        let maxSharp = max(sharp.sharpness, flat.sharpness, 1e-9)
        let maxSal = max(sharp.saliency, flat.saliency, 1e-9)
        func norm(_ s: SceneFrameSignals) -> Double {
            SceneScoring.score(.init(sharpness: s.sharpness / maxSharp,
                                     saliency: s.saliency / maxSal, presence: s.presence))
        }
        XCTAssertGreaterThan(norm(sharp), norm(flat))
    }

    // MARK: - Fixtures (synthesized in code — no bundled assets)

    private static func checkerboard(side: Int, cell: Int) -> CGImage {
        makeImage(side: side) { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.setFillColor(gray: 0, alpha: 1)
            for y in stride(from: 0, to: side, by: cell) {
                for x in stride(from: 0, to: side, by: cell) where ((x / cell) + (y / cell)) % 2 == 0 {
                    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
        }
    }

    private static func solid(side: Int, gray: CGFloat) -> CGImage {
        makeImage(side: side) { ctx in
            ctx.setFillColor(gray: gray, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private static func makeImage(side: Int, draw: (CGContext) -> Void) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }
}
