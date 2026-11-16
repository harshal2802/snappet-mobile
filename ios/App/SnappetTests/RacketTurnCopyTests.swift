import XCTest
import AVFoundation
import UIKit
@testable import Snappet

/// Prompt 259: the viewer's turn reaches copies (pure maths for 0–3 turns on portrait and landscape sources, the
/// turned-once rule for derived videos, turned stills) and an export of the bundled synthetic clips comes out upright
/// (size and where a known marker lands). The export runs on the simulator (passthrough: the turn is the output track's
/// transform) and on a device (re-encoded with the same transform).
@MainActor
final class RacketTurnCopyTests: XCTestCase {

    // MARK: Maths

    private let landscape = CGSize(width: 1920, height: 1080)
    /// How an iPhone stores a portrait video: landscape pixels, a quarter turn clockwise to show.
    private let portraitSensor = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    private func shown(_ natural: CGSize, _ t: CGAffineTransform) -> CGRect {
        CGRect(origin: .zero, size: natural).applying(t)
    }

    private func assertSame(_ a: CGAffineTransform, _ b: CGAffineTransform, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.a, b.a), (a.b, b.b), (a.c, b.c), (a.d, b.d), (a.tx, b.tx), (a.ty, b.ty)] {
            XCTAssertEqual(x, y, accuracy: 0.0001, "\(a) vs \(b)", file: file, line: line)
        }
    }

    func testNoTurnKeepsTheStoredTransform() {
        for t in [CGAffineTransform.identity, portraitSensor, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)] {
            XCTAssertEqual(RacketVideoTurn.transform(natural: landscape, preferred: t, turns: 0), t)
            XCTAssertEqual(RacketVideoTurn.transform(natural: landscape, preferred: t, turns: nil), t)
            XCTAssertEqual(RacketVideoTurn.transform(natural: landscape, preferred: t, turns: 4), t, "a full turn is none")
        }
    }

    func testLandscapeSourceTurns() {
        // 1 turn: exactly the transform the camera writes for a portrait video.
        assertSame(RacketVideoTurn.transform(natural: landscape, preferred: .identity, turns: 1), portraitSensor)
        assertSame(RacketVideoTurn.transform(natural: landscape, preferred: .identity, turns: 2),
                   CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080))
        assertSame(RacketVideoTurn.transform(natural: landscape, preferred: .identity, turns: 3),
                   CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920))
        let sizes = (0...3).map { RacketVideoTurn.renderSize(natural: landscape, preferred: .identity, turns: $0) }
        XCTAssertEqual(sizes, [landscape, CGSize(width: 1080, height: 1920), landscape, CGSize(width: 1080, height: 1920)])
        for k in 0...3 {
            let r = shown(landscape, RacketVideoTurn.transform(natural: landscape, preferred: .identity, turns: k))
            XCTAssertEqual(r.origin, .zero, "turn \(k) lands on the render rect")
            XCTAssertEqual(r.size, sizes[k])
        }
    }

    func testPortraitSourceTurns() {
        // A camera portrait (landscape pixels + a quarter turn): 1 more turn ⇒ upside-down landscape pixels = 180°.
        assertSame(RacketVideoTurn.transform(natural: landscape, preferred: portraitSensor, turns: 1),
                   CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080))
        assertSame(RacketVideoTurn.transform(natural: landscape, preferred: portraitSensor, turns: 3), .identity)
        // A portrait stored upright (portrait pixels, identity), like the bundled test clip.
        let portrait = CGSize(width: 1080, height: 1920)
        assertSame(RacketVideoTurn.transform(natural: portrait, preferred: .identity, turns: 1),
                   CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0))
        for (natural, pref) in [(landscape, portraitSensor), (portrait, CGAffineTransform.identity)] {
            let sizes = (0...3).map { RacketVideoTurn.renderSize(natural: natural, preferred: pref, turns: $0) }
            XCTAssertEqual(sizes, [portrait, landscape, portrait, landscape])
            for k in 0...3 {
                let r = shown(natural, RacketVideoTurn.transform(natural: natural, preferred: pref, turns: k))
                XCTAssertEqual(r.origin.x, 0, accuracy: 0.001)
                XCTAssertEqual(r.origin.y, 0, accuracy: 0.001)
                XCTAssertEqual(r.size, sizes[k], "turn \(k)")
            }
        }
    }

    func testCornersGoClockwise() {
        let s = CGSize(width: 100, height: 50)
        let tl = CGPoint(x: 0, y: 0)
        XCTAssertEqual(RacketVideoTurn.point(tl, in: s, turns: 0), tl)
        XCTAssertEqual(RacketVideoTurn.point(tl, in: s, turns: 1), CGPoint(x: 50, y: 0), "top-left → top-right")
        XCTAssertEqual(RacketVideoTurn.point(tl, in: s, turns: 2), CGPoint(x: 100, y: 50), "→ bottom-right")
        XCTAssertEqual(RacketVideoTurn.point(tl, in: s, turns: 3), CGPoint(x: 0, y: 100), "→ bottom-left")
    }

    // MARK: Derived videos are turned once

    func testDerivedVideosAreTurnedOnce() {
        var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
        log.assets = [.init(localIdentifier: "orig", startSec: 0, durationSec: 60)]
        log.quarterTurns = RacketVideoTurn.stored(RacketVideoTurn.next(nil))
        XCTAssertEqual(log.copyTurns, 1, "the derived video is saved with the turn")
        log.derived = [RacketDerivedVideo(localIdentifier: "derived", startSec: 0, endSec: 60)]
        log.playFromDerived()
        XCTAssertEqual(RacketVideoMap.sources(log).map(\.localIdentifier), ["derived"])
        XCTAssertNil(log.quarterTurns, "the player doesn't turn the upright derived video again")
        XCTAssertEqual(log.copyTurns, 0, "nor does a copy of it")
        XCTAssertEqual(RacketVideoTurn.normalized(log.quarterTurns), 0)
        // Rotate after that turns the derived video, from upright.
        log.quarterTurns = RacketVideoTurn.stored(RacketVideoTurn.next(log.quarterTurns))
        XCTAssertEqual(log.copyTurns, 1)
    }

    func testOldDerivedRecordingKeepsItsTurn() {
        // Made before prompt 259: derived (not turned) with a turn on the log ⇒ the turn still applies.
        var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
        log.derived = [RacketDerivedVideo(localIdentifier: "derived", startSec: 0, endSec: 60)]
        log.originalDeleted = true
        log.quarterTurns = 1
        XCTAssertEqual(log.copyTurns, 1)
    }

    // MARK: Stills

    /// A 40×20 still, red in the top-left 10×10 corner, blue elsewhere.
    private func marked() -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: f).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    func testStillsTurnTheirPixels() throws {
        let img = marked()
        XCTAssertTrue(RacketVideoLibrary.turned(img, turns: 0) === img)
        for k in 1...3 {
            let out = RacketVideoLibrary.turned(img, turns: k)
            XCTAssertEqual(out.imageOrientation, .up, "the pixels turn, not a tag")
            XCTAssertEqual(out.size, RacketVideoTurn.displayed(img.size, turns: k))
            let cg = try XCTUnwrap(out.cgImage)
            let corner = RacketVideoTurn.point(CGPoint(x: 5, y: 5), in: img.size, turns: k)
            XCTAssertTrue(Pixels(cg).isRed(at: corner), "turn \(k): the red corner at \(corner)")
            let opposite = RacketVideoTurn.point(CGPoint(x: 35, y: 15), in: img.size, turns: k)
            XCTAssertTrue(Pixels(cg).isBlue(at: opposite), "turn \(k): blue at \(opposite)")
        }
    }

    // MARK: Export of a generated clip

    /// The bundled synthetic clips, each with a marker: the blue table (large) and the orange square near the top
    /// right (a corner marker, the ball: in place on the first frame), upright points in the stored picture.
    private struct Clip {
        let name: String
        let size: CGSize
        let table: CGPoint
        let orange: CGPoint
    }

    private let clips = [
        Clip(name: "racket-uitest-landscape.mov", size: CGSize(width: 960, height: 540),
             table: CGPoint(x: 480, y: 275), orange: CGPoint(x: 866, y: 106)),
        Clip(name: "racket-uitest-portrait.mov", size: CGSize(width: 540, height: 960),
             table: CGPoint(x: 270, y: 530), orange: CGPoint(x: 507, y: 287)),
    ]

    private func segment(_ id: String) -> RacketVideoSegment {
        RacketVideoSegment(localIdentifier: id, assetStart: 0, assetEnd: 2, timelineStart: 0)
    }

    private func frame(_ url: URL, at sec: Double = 0) async throws -> CGImage {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        return try await g.image(at: CMTime(seconds: sec, preferredTimescale: 600)).image
    }

    private func check(_ url: URL, _ clip: Clip, turns k: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let size = await RacketVideoLibrary.displayedSize(of: url)
        XCTAssertEqual(size, RacketVideoTurn.displayed(clip.size, turns: k), "\(clip.name) turn \(k): shown size", file: file, line: line)
        let px = Pixels(try await frame(url))
        let table = RacketVideoTurn.point(clip.table, in: clip.size, turns: k)
        let orange = RacketVideoTurn.point(clip.orange, in: clip.size, turns: k)
        XCTAssertTrue(px.isBlue(at: table), "\(clip.name) turn \(k): the table at \(table) — \(px.rgb(at: table))", file: file, line: line)
        XCTAssertTrue(px.isOrange(at: orange), "\(clip.name) turn \(k): the orange corner marker at \(orange) — \(px.rgb(at: orange))",
                      file: file, line: line)
    }

    func testExportedCopiesAreUprightForEveryTurn() async throws {
        for clip in clips {
            for k in 0...3 {
                let url = try await RacketVideoLibrary.shared.export([([segment(RecapClipSeed.bundledScheme + clip.name)], 0, 2)],
                                                                     turns: k, fileName: "turn-test-\(k)-\(clip.name).mp4")
                defer { try? FileManager.default.removeItem(at: url) }
                try await check(url, clip, turns: k)
            }
        }
    }

    func testNoTurnKeepsTheSourceTransform() async throws {
        let clip = clips[0]
        let url = try await RacketVideoLibrary.shared.export([([segment(RecapClipSeed.bundledScheme + clip.name)], 0, 2)],
                                                             fileName: "turn-test-none.mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let transform = try await track.load(.preferredTransform)
        XCTAssertEqual(transform, .identity)
        try await check(url, clip, turns: 0)
    }

    /// Turn → "Delete the long original" (the derived video is saved turned, the turn cleared) → play / share the
    /// derived video again: upright, turned exactly once.
    func testTurnThenDeriveThenShareIsTurnedOnce() async throws {
        for clip in clips {
            var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
            log.quarterTurns = 1
            let derived = try await RacketVideoLibrary.shared.export([([segment(RecapClipSeed.bundledScheme + clip.name)], 0, 2)],
                                                                     turns: log.copyTurns, fileName: "turn-test-derived-\(clip.name).mp4")
            defer { try? FileManager.default.removeItem(at: derived) }
            log.derived = [RacketDerivedVideo(localIdentifier: derived.absoluteString, startSec: 0, endSec: 2)]
            log.playFromDerived()
            XCTAssertEqual(RacketVideoTurn.normalized(log.quarterTurns), 0, "the player draws the derived video as stored")
            let segs = RacketVideoMap.segments(start: 0, end: 2, log: log)
            XCTAssertEqual(segs.first?.localIdentifier, derived.absoluteString)
            let shared = try await RacketVideoLibrary.shared.export([(segs, 0, 2)], turns: log.copyTurns,
                                                                    fileName: "turn-test-shared-\(clip.name).mp4")
            defer { try? FileManager.default.removeItem(at: shared) }
            try await check(derived, clip, turns: 1)
            try await check(shared, clip, turns: 1)
        }
    }
}

/// RGBA pixels of a still, read top-left first.
private struct Pixels {
    let w: Int, h: Int
    let data: [UInt8]

    init(_ cg: CGImage) {
        w = cg.width; h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        data = buf
    }

    func rgb(at p: CGPoint) -> (Int, Int, Int) {
        let x = min(w - 1, max(0, Int(p.x))), y = min(h - 1, max(0, Int(p.y)))
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    func isRed(at p: CGPoint) -> Bool { let (r, g, b) = rgb(at: p); return r > 200 && g < 60 && b < 60 }
    func isBlue(at p: CGPoint) -> Bool { let (r, _, b) = rgb(at: p); return b > 120 && b > r + 50 }
    func isOrange(at p: CGPoint) -> Bool { let (r, g, b) = rgb(at: p); return r > 180 && g > 90 && g < 200 && b < 140 }
}
