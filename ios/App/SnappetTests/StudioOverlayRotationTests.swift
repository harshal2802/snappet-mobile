import XCTest
import QuartzCore
@testable import Snappet

/// A turned overlay is turned the same way in the exported file as in the preview (prompt 321).
///
/// The preview turns an overlay with SwiftUI's `.rotationEffect(.degrees(rotationDegrees))`:
/// positive = clockwise on screen. The export's Core Animation layer tree has its origin at the
/// bottom left, where `CATransform3DMakeRotation(+angle)` turns counter-clockwise, and it used the
/// angle as it was: on the phone, "Second go" at +10° rose to the right in the file and fell to the
/// right in the editor. These tests export turned overlays through the real export on the
/// simulator. Stickers are bitmaps and the text's highlight box is a filled layer, so the
/// simulator draws both (it does not draw the letters).
final class StudioOverlayRotationTests: StudioFixtureTestCase {

    override class var sources: [StudioGoldenSource] { [.overlayBase] }

    private let frame = 10

    // MARK: Pure

    /// The layer transform turns a point clockwise on screen for a positive angle: in the y-up
    /// layer space, (1, 0) turned +90° goes to (0, −1), i.e. down on screen.
    func testPositiveDegreesTurnClockwiseOnScreen() {
        let t = StudioOverlays.overlayRotation(degrees: 90)
        let p = CGPoint(x: 1, y: 0).applying(CATransform3DGetAffineTransform(t))
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, -1, accuracy: 1e-9, "y up: −1 is down on screen, so the turn is clockwise")
        let q = CGPoint(x: 1, y: 0).applying(CATransform3DGetAffineTransform(StudioOverlays.overlayRotation(degrees: -90)))
        XCTAssertEqual(q.y, 1, accuracy: 1e-9)
    }

    // MARK: Through the export

    /// A wide sticker, a text line on a highlight, and a climb tag (dark default highlight), each
    /// turned, over the test video. Each overlay's pixels (where the frame differs from the bare
    /// clip) are measured: a wide shape turned clockwise has its right end lower than its left end
    /// on screen, so x and y rise together (positive correlation, y down); counter-clockwise, the
    /// other way round.
    func testTurnedOverlaysTurnTheWayThePreviewDoes() async throws {
        let clip = StudioGoldenScene.clip(.overlayBase, 0)
        let scene = StudioGoldenScene(
            id: "overlay-rotation", title: "Overlay rotation", clips: [clip],
            overlays: [
                OverlayItem(kind: .sticker, content: "rectangle.fill", startSec: 0, endSec: 1,
                            position: CGPoint(x: 0.5, y: 0.2), rotationDegrees: 30, colorHex: "#FF9500"),
                OverlayItem(kind: .text, content: "TURN TURN", startSec: 0, endSec: 1,
                            position: CGPoint(x: 0.5, y: 0.5), rotationDegrees: 20,
                            colorHex: "#000000", highlightHex: "#FF9500"),
                OverlayItem(kind: .climbName, content: "Pinch Me · V5", startSec: 0, endSec: 1,
                            position: CGPoint(x: 0.5, y: 0.8), rotationDegrees: -20, clipID: clip.id)],
            frames: [frame])
        var bare = StudioGoldenScene.passThrough(.overlayBase)
        bare.frames = [frame]
        let fixture = try fixture()
        let with = try await StudioGoldenRenderer.frames(of: scene, fixture: fixture, path: .export)[0]
        let without = try await StudioGoldenRenderer.frames(of: bare, fixture: fixture, path: .export)[0]
        attach(with, "overlay-rotation-f010-export")

        // (name, rows of the band it is in, the sign its correlation must have)
        let cases: [(String, ClosedRange<Int>, Double)] = [
            ("sticker +30°", 92 ... 292, 1), ("text +20°", 380 ... 580, 1), ("climb tag −20°", 668 ... 868, -1)]
        for (name, rows, sign) in cases {
            var xs: [Double] = [], ys: [Double] = []
            for y in rows {
                for x in 0 ..< with.width {
                    let i = (y * with.width + x) * 4
                    let d = abs(Int(with.rgba[i]) - Int(without.rgba[i]))
                        + abs(Int(with.rgba[i + 1]) - Int(without.rgba[i + 1]))
                        + abs(Int(with.rgba[i + 2]) - Int(without.rgba[i + 2]))
                    if d > 90 { xs.append(Double(x)); ys.append(Double(y)) }
                }
            }
            XCTAssertGreaterThan(xs.count, 2_000, "\(name) is drawn")
            let r = correlation(xs, ys)
            print("StudioOverlayRotationTests \(name): correlation \(r)")
            // The old direction gives the same size with the other sign.
            XCTAssertGreaterThan(r * sign, 0.1,"\(name): x–y correlation \(r) (y down; + = clockwise)")
        }
    }

    private func correlation(_ xs: [Double], _ ys: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my)
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }
}
