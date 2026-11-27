import XCTest
import UIKit
@testable import Snappet

/// Stickers burn into an exported Studio video as the symbol, in its colour (prompt 308).
///
/// On a phone (iPhone 13 Pro Max, iOS 27.2.1) the overlay reference's `ref-sticker` frame came
/// out as two solid black rectangles: the layer was handed a symbol image's `.cgImage`, which is
/// the untinted template raster, not the tinted picture. The fix draws the tinted symbol into a
/// bitmap of our own. A bitmap is not a glyph, so the simulator's Core Animation tool draws it
/// too, and this test renders the scene through the real export and looks at the pixels.
final class StudioStickerExportTests: StudioFixtureTestCase {

    override class var sources: [StudioGoldenSource] { [.overlayBase] }

    private let frame = 10
    private let orange: (r: Int, g: Int, b: Int) = (255, 149, 0)      // #FF9500

    // MARK: The bitmap the layer gets

    func testStickerImageIsTheTintedSymbolOnATransparentBackground() throws {
        let image = try XCTUnwrap(StudioOverlays.stickerImage(symbol: "flame.fill", colorHex: "#FF9500",
                                                              pointSize: 230))
        let bitmap = try XCTUnwrap(rgba(image.cgImage))
        let w = bitmap.width, h = bitmap.height
        XCTAssertGreaterThan(w, 100)
        XCTAssertGreaterThan(h, 100)
        // Every corner is see-through.
        for (x, y) in [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)] {
            XCTAssertEqual(bitmap.pixel(x, y).a, 0, "corner (\(x), \(y)) is transparent")
        }
        // The symbol is there, and it is orange, not black or the untinted template.
        let opaque = bitmap.pixels.filter { $0.a == 255 }
        XCTAssertGreaterThan(Double(opaque.count) / Double(w * h), 0.25, "the flame covers its box")
        for p in opaque.prefix(2_000) {
            XCTAssertTrue(close(p, orange, 6), "an opaque pixel is orange: \(p)")
        }
        // A colour the app cannot read falls back to white, like text.
        let white = try XCTUnwrap(StudioOverlays.stickerImage(symbol: "star.fill", colorHex: "nope", pointSize: 50))
        let whiteBitmap = try XCTUnwrap(rgba(white.cgImage))
        let center = whiteBitmap.pixel(whiteBitmap.width / 2, whiteBitmap.height / 2)
        XCTAssertTrue(close(center, (255, 255, 255), 3), "the star's middle is white: \(center)")
        // An unknown symbol draws the filled circle the layer always fell back to.
        XCTAssertNotNil(StudioOverlays.stickerImage(symbol: "no.such.symbol.anywhere", colorHex: "#FFFFFF",
                                                    pointSize: 50))
    }

    /// What the layer used to get, for the record: the `.cgImage` of a tinted symbol image.
    func testOldPathCGImageForTheRecord() throws {
        let config = UIImage.SymbolConfiguration(pointSize: 230, weight: .semibold)
        let old = try XCTUnwrap(UIImage(systemName: "flame.fill", withConfiguration: config)?
            .withTintColor(UIColor(red: 1, green: 149 / 255, blue: 0, alpha: 1), renderingMode: .alwaysOriginal))
        guard let cg = old.cgImage else { print("StudioStickerExportTests old path: cgImage is nil"); return }
        let bitmap = try XCTUnwrap(rgba(cg))
        let inked = bitmap.pixels.filter { $0.a > 0 }
        let opaque = inked.filter { $0.a == 255 }
        func mean(_ k: KeyPath<(r: UInt8, g: UInt8, b: UInt8, a: UInt8), UInt8>) -> Int {
            opaque.isEmpty ? -1 : opaque.reduce(0) { $0 + Int($1[keyPath: k]) } / opaque.count
        }
        print("StudioStickerExportTests old path: \(cg.width)x\(cg.height) px, \(cg.bitsPerComponent) bpc, "
              + "alpha info \(cg.alphaInfo.rawValue), space \(cg.colorSpace?.name.map { $0 as String } ?? "-"), "
              + "image \(old.size) @\(old.scale)x; \(inked.count) pixels with alpha > 0, \(opaque.count) opaque, "
              + "mean opaque colour (\(mean(\.r)), \(mean(\.g)), \(mean(\.b)))")
    }

    // MARK: The exported frame

    /// `ref-sticker`, frame 10, through `StudioComposer.export` on the simulator: the star is
    /// white, the flame orange, and the rest of each old black box is the video underneath.
    func testExportedStickerFrameShowsTheSymbolsNotBlackBoxes() async throws {
        let scene = try XCTUnwrap(StudioOverlayReference.scenes.first { $0.id == "ref-sticker" })
        var sticker = scene
        sticker.frames = [frame]
        var bare = StudioGoldenScene.passThrough(.overlayBase)
        bare.frames = [frame]
        let fixture = try fixture()
        let with = try await StudioGoldenRenderer.frames(of: sticker, fixture: fixture, path: .export)[0]
        let without = try await StudioGoldenRenderer.frames(of: bare, fixture: fixture, path: .export)[0]
        attach(with, "ref-sticker-f010-export")
        XCTAssertEqual(with.width, 540)
        XCTAssertEqual(with.height, 960)

        // The two old boxes (prompt 308's phone frame): side = 12 % of the height × scale, centred
        // on the overlay's position, the flame's turned −20°.
        let starCenter = CGPoint(x: 0.3 * 540, y: 0.3 * 960), starSide = 0.12 * 960.0
        let flameCenter = CGPoint(x: 0.7 * 540, y: 0.7 * 960), flameSide = 0.12 * 960.0 * 2
        let flameTurn = -20.0 * .pi / 180

        // In the middle of the star: white. The flame has a hollow in its middle, so: a large
        // part of its old box is orange (the video there is yellow, so nothing else is).
        let star = with.pixelAt(starCenter)
        XCTAssertTrue(close(star, (255, 255, 255), 30), "the star's middle is white, got \(star)")
        var orangeCount = 0, flameTotal = 0
        let flameHalf = Int(flameSide / 2)
        for dy in -flameHalf ... flameHalf {
            for dx in -flameHalf ... flameHalf {
                let at = point(flameCenter, local: CGPoint(x: dx, y: dy), turn: flameTurn)
                guard at.x >= 0, at.y >= 0, at.x < 540, at.y < 960 else { continue }
                flameTotal += 1
                if close(with.pixelAt(at), orange, 30) { orangeCount += 1 }
            }
        }
        XCTAssertGreaterThan(Double(orangeCount) / Double(max(flameTotal, 1)), 0.3,
                             "\(orangeCount) of \(flameTotal) pixels in the flame's old box are orange")

        // Inside each old box but outside the symbol (its corners): the video, not black.
        for (center, side, turn, name) in [(starCenter, starSide, 0.0, "star"),
                                           (flameCenter, flameSide, flameTurn, "flame")] {
            for corner in [CGPoint(x: -0.42, y: -0.42), CGPoint(x: 0.42, y: -0.42),
                           CGPoint(x: -0.42, y: 0.42), CGPoint(x: 0.42, y: 0.42)] {
                let at = point(center, local: CGPoint(x: corner.x * side, y: corner.y * side), turn: turn)
                let got = with.pixelAt(at), video = without.pixelAt(at)
                XCTAssertTrue(close(got, (Int(video.r), Int(video.g), Int(video.b)), 24),
                              "\(name) box corner \(corner) shows the video \(video), got \(got)")
            }
            // Nothing near black anywhere in the box (the clip has no black there).
            var black = 0, total = 0
            let half = Int(side / 2)
            for dy in -half ... half {
                for dx in -half ... half {
                    let at = point(center, local: CGPoint(x: dx, y: dy), turn: turn)
                    guard at.x >= 0, at.y >= 0, at.x < 540, at.y < 960 else { continue }
                    total += 1
                    let p = with.pixelAt(at)
                    if Int(p.r) + Int(p.g) + Int(p.b) < 60 { black += 1 }
                }
            }
            XCTAssertLessThan(Double(black) / Double(max(total, 1)), 0.005,
                              "\(name): \(black) of \(total) pixels in the old box are black")
        }
    }

    // MARK: Helpers

    /// The bitmap as straight RGBA bytes with its alpha (premultiplied, sRGB).
    private func rgba(_ image: CGImage) -> StudioGoldenImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? StudioGoldenImage(width: w, height: h, rgba: bytes) : nil
    }

    /// A point given in a box's own picture coordinates (x right, y down, from its centre), with
    /// the box turned the way `CATransform3DMakeRotation(turn, 0, 0, 1)` turns it in the export
    /// (Core Animation's y-up space: a negative angle looks clockwise).
    private func point(_ center: CGPoint, local: CGPoint, turn: Double) -> CGPoint {
        let c = cos(turn), s = sin(turn)
        let x = local.x * c - (-local.y) * s
        let yUp = local.x * s + (-local.y) * c
        return CGPoint(x: center.x + x, y: center.y - yUp)
    }

    private func close(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), _ q: (r: Int, g: Int, b: Int),
                       _ tolerance: Int) -> Bool {
        abs(Int(p.r) - q.r) <= tolerance && abs(Int(p.g) - q.g) <= tolerance && abs(Int(p.b) - q.b) <= tolerance
    }
}

private extension StudioGoldenImage {
    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }
    func pixelAt(_ p: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        pixel(min(width - 1, max(0, Int(p.x.rounded(.down)))), min(height - 1, max(0, Int(p.y.rounded(.down)))))
    }
    var pixels: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] {
        stride(from: 0, to: rgba.count, by: 4).map { (rgba[$0], rgba[$0 + 1], rgba[$0 + 2], rgba[$0 + 3]) }
    }
}
