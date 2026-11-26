import XCTest
import AVFoundation
@testable import Snappet

/// A clip with no edits comes out of the Studio looking as it went in (prompt 304). These tests
/// need no golden image: the Studio's frame is compared with the same frame of the source file
/// decoded directly. They are what found that every export was about 18 levels too bright in the
/// mid-tones (the compositor wrote its frames with a different BT.709 curve than the one it read
/// them with), and they are what keeps it from coming back.
///
/// The frame is looked at in 16 × 16 squares (overlapping by half), in two kinds:
/// - **flat** squares, where the source has one colour. The Studio's mean colour there must be
///   the source's, to within `Limits.flat` per channel. This is the colour check.
/// - **edge** squares, where the source has an edge. Two decoders and a second H.264 pass place
///   colour a little differently at an edge, so these get a looser allowance.
final class StudioPassThroughTests: StudioFixtureTestCase {

    override class var sources: [StudioGoldenSource] { [.portraitA, .portraitB, .rotated] }

    /// What a frame may differ by.
    struct Limits {
        /// The signed mean difference (Studio − source) of any channel in a flat square.
        var flat: ClosedRange<Double>
        /// The size of the mean difference of any channel in a square with an edge.
        var edge: Double
        /// Single pixels (brightness, averaged colour, how many): `mean` is not used.
        var pixels: StudioGoldenTolerance
    }

    /// An SDR clip. Measured on the simulator (Xcode 27.2, iOS 26.5), export and preview, three
    /// sources: flat squares −1.0 ... +1.5; edge squares up to 5.1; brightness up to 15 on one or
    /// two pixels at the white block's edge. Before the fix a region's mean was 22 to 24 up
    /// everywhere. The edge allowance has room for another decoder or Xcode; the flat one is
    /// the colour check and has little.
    static let limits = Limits(
        flat: -2 ... 2, edge: 10,
        pixels: StudioGoldenTolerance(luma: 14, chroma: 9, maxFraction: 0.002, maxCellFraction: 0.06, mean: 255))

    /// The mean difference per channel of every full 16 × 16 square, split by whether the
    /// reference is one colour there: no channel varies by more than `flatRange` inside the
    /// square or within `margin` pixels of it (a video file's colour bleeds a few pixels from an
    /// edge, and differently on each pass).
    struct Squares {
        var flatLow = 0.0, flatHigh = 0.0, edge = 0.0
        var flatCount = 0, edgeCount = 0

        var line: String {
            func decimal(_ value: Double) -> String { String(format: "%.1f", value) }
            return "flat squares \(decimal(flatLow)) ... \(decimal(flatHigh)) "
                + "(\(flatCount)), edge squares up to \(decimal(edge)) (\(edgeCount))"
        }

        func within(_ limits: Limits) -> Bool {
            flatCount > 0 && flatLow >= limits.flat.lowerBound && flatHigh <= limits.flat.upperBound
                && edge <= limits.edge
        }
    }

    static func squares(actual: StudioGoldenImage, reference: StudioGoldenImage, flatRange: Int = 6,
                        margin: Int = 8) -> Squares {
        var out = Squares()
        guard actual.width == reference.width, actual.height == reference.height else { return out }
        let w = reference.width, h = reference.height
        var y = 0
        while y + 16 <= h {
            var x = 0
            while x + 16 <= w {
                var sum = [0, 0, 0], low = [255, 255, 255], high = [0, 0, 0]
                for row in max(0, y - margin) ..< min(h, y + 16 + margin) {
                    for column in max(0, x - margin) ..< min(w, x + 16 + margin) {
                        let i = (row * w + column) * 4
                        let inside = row >= y && row < y + 16 && column >= x && column < x + 16
                        for channel in 0 ..< 3 {
                            let value = Int(reference.rgba[i + channel])
                            if inside { sum[channel] += Int(actual.rgba[i + channel]) - value }
                            low[channel] = min(low[channel], value)
                            high[channel] = max(high[channel], value)
                        }
                    }
                }
                let means = sum.map { Double($0) / 256 }
                if (0 ..< 3).allSatisfy({ high[$0] - low[$0] <= flatRange }) {
                    out.flatLow = out.flatCount == 0 ? means.min() ?? 0 : min(out.flatLow, means.min() ?? 0)
                    out.flatHigh = out.flatCount == 0 ? means.max() ?? 0 : max(out.flatHigh, means.max() ?? 0)
                    out.flatCount += 1
                } else {
                    out.edge = max(out.edge, means.map { abs($0) }.max() ?? 0)
                    out.edgeCount += 1
                }
                x += 8
            }
            y += 8
        }
        return out
    }

    private func assertPassesThrough(_ source: StudioGoldenSource, fixture: StudioGoldenRenderer.Fixture,
                                     limits: (StudioSelfCheck.RenderPath) -> Limits = { _ in StudioPassThroughTests.limits },
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let scene = StudioGoldenScene.passThrough(source)
        for path in StudioSelfCheck.RenderPath.allCases {
            let frames = try await StudioGoldenRenderer.frames(of: scene, fixture: fixture, path: path)
            for (frame, image) in zip(scene.frames, frames) {
                let direct = try await StudioGoldenRenderer.sourceFrame(fixture.url(source), frame: frame)
                let allowed = limits(path)
                let pixels = StudioGoldenCompare.compare(actual: image, golden: direct, tolerance: allowed.pixels)
                let squares = Self.squares(actual: image, reference: direct)
                let what = "\(source.rawValue) \(path.rawValue) frame \(frame)"
                print("StudioPassThroughTests: \(what): \(squares.line); brightness \(pixels.maxLuma), "
                    + "colour \(pixels.maxChroma), \(pixels.differing) pixels over")
                if !pixels.passed || !squares.within(allowed) {
                    attach(image, "\(source.rawValue)-\(path.rawValue)-f\(frame)-studio")
                    attach(direct, "\(source.rawValue)-f\(frame)-direct")
                }
                XCTAssertTrue(pixels.passed, "\(what): \(pixels.summary)", file: file, line: line)
                XCTAssertTrue(squares.within(allowed),
                              "\(what): \(squares.line); allowed flat \(allowed.flat), edge \(allowed.edge)",
                              file: file, line: line)
            }
        }
    }

    func testAnUneditedClipComesOutAsItWentIn() async throws {
        for source in [StudioGoldenSource.portraitA, .portraitB] {
            try await assertPassesThrough(source, fixture: try fixture())
        }
    }

    func testAnUneditedSidewaysClipComesOutUprightAndUnchanged() async throws {
        try await assertPassesThrough(.rotated, fixture: try fixture())
    }

    /// The limits are strict enough: the old brightening fails them, and so do much smaller
    /// shifts — 7 levels, 3 levels, and a change of hue with no change of brightness.
    func testTheLimitsCatchABrighterAndATintedFrame() async throws {
        let direct = try await StudioGoldenRenderer.sourceFrame(try fixture().url(.portraitA), frame: 14)
        func shifted(red: Int, green: Int, blue: Int) -> StudioGoldenImage {
            var image = direct
            for i in stride(from: 0, to: image.rgba.count, by: 4) {
                image.rgba[i] = UInt8(min(255, max(0, Int(image.rgba[i]) + red)))
                image.rgba[i + 1] = UInt8(min(255, max(0, Int(image.rgba[i + 1]) + green)))
                image.rgba[i + 2] = UInt8(min(255, max(0, Int(image.rgba[i + 2]) + blue)))
            }
            return image
        }
        XCTAssertTrue(Self.squares(actual: direct, reference: direct).within(Self.limits))
        XCTAssertGreaterThan(Self.squares(actual: direct, reference: direct).flatCount, 100,
                             "most of the pattern is flat colour")
        XCTAssertFalse(Self.squares(actual: shifted(red: 18, green: 18, blue: 18), reference: direct).within(Self.limits),
                       "18 levels everywhere is what the Studio drew before the fix")
        XCTAssertFalse(Self.squares(actual: shifted(red: 7, green: 7, blue: 7), reference: direct).within(Self.limits),
                       "7 levels everywhere is a visible shift and must fail")
        XCTAssertFalse(Self.squares(actual: shifted(red: 3, green: 3, blue: 3), reference: direct).within(Self.limits),
                       "3 levels everywhere must fail")
        XCTAssertFalse(Self.squares(actual: shifted(red: -3, green: -3, blue: -3), reference: direct).within(Self.limits),
                       "3 levels darker everywhere must fail")
        XCTAssertFalse(Self.squares(actual: shifted(red: 3, green: 0, blue: -3), reference: direct).within(Self.limits),
                       "a hue shift (red up 3, blue down 3) must fail")
        // The HDR limits are one-sided around the measured offset: the same offset moved 25
        // darker or lighter, or 6 darker, is outside them.
        let hdr = Squares(flatLow: 0, flatHigh: 11.2, edge: 12.1, flatCount: 500, edgeCount: 200)
        var darker = hdr, lighter = hdr, alittleDarker = hdr
        darker.flatLow -= 25; darker.flatHigh -= 25
        lighter.flatLow += 25; lighter.flatHigh += 25
        alittleDarker.flatLow -= 6; alittleDarker.flatHigh -= 6
        for path in StudioSelfCheck.RenderPath.allCases {
            XCTAssertTrue(hdr.within(Self.hdrLimits(path)))
            XCTAssertFalse(darker.within(Self.hdrLimits(path)), "an HDR clip 25 darker must fail")
            XCTAssertFalse(lighter.within(Self.hdrLimits(path)), "an HDR clip 25 lighter must fail")
            XCTAssertFalse(alittleDarker.within(Self.hdrLimits(path)), "an HDR clip 6 darker must fail")
        }
    }

    /// A wide-colour clip (tagged Display P3). AVFoundation converts it to BT.709 before the
    /// compositor sees it (`supportsWideColorSourceFrames` is off), and the export is BT.709; the
    /// frame, shown as sRGB, must be what the file shows when it is decoded directly.
    func testAWideColourClipKeepsItsColours() async throws {
        let directory = StudioGoldenRenderer.newFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try StudioGoldenRenderer.makeFixture([.wideColour], in: directory)
        try await assertPassesThrough(.wideColour, fixture: fixture, limits: { _ in Self.wideColourLimits })
    }

    /// An HDR clip (10-bit HEVC, BT.2020 HLG). AVFoundation converts it to SDR BT.709 before the
    /// compositor sees it (`supportsHDRSourceFrames` is off); the Studio's output is SDR. The
    /// direct decode is tone-mapped to SDR by another part of the system, so the two are not
    /// equal: in flat colour the Studio's frame is lighter than the direct decode by 0 to 11
    /// levels a channel, the same on the export and on the preview. That is AVFoundation's
    /// conversion, not the compositor's; the limits hold the offset to what was measured, on
    /// each path, so a later shift either way fails.
    func testAnHDRClipIsExportedAsSDRCloseToItsOwnSDRPicture() async throws {
        let directory = StudioGoldenRenderer.newFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture: StudioGoldenRenderer.Fixture
        do {
            fixture = try StudioGoldenRenderer.makeFixture([.hdr], in: directory)
        } catch {
            throw XCTSkip("this machine cannot write a 10-bit HEVC file: \(error.localizedDescription)")
        }
        try await assertPassesThrough(.hdr, fixture: fixture, limits: Self.hdrLimits)
    }

    /// Display P3. Measured on the simulator: flat squares −3.6 ... +1.1 on the export and
    /// −3.0 ... +1.0 on the preview (the conversion from P3 leaves a channel a few levels low);
    /// edge squares up to 6.8; brightness up to 19 on single pixels.
    static let wideColourLimits = Limits(
        flat: -5.5 ... 3, edge: 12,
        pixels: StudioGoldenTolerance(luma: 24, chroma: 12, maxFraction: 0.002, maxCellFraction: 0.06, mean: 255))

    /// HLG. Measured on the simulator: flat squares 0.0 ... +11.2 on the export and 0.0 ... +11.0
    /// on the preview; edge squares up to 12.1 and 11.7; brightness up to 22 on single pixels.
    /// The two paths agree here, so they share one limit.
    static func hdrLimits(_ path: StudioSelfCheck.RenderPath) -> Limits {
        Limits(flat: -3 ... 14.5, edge: 17,
               pixels: StudioGoldenTolerance(luma: 28, chroma: 13, maxFraction: 0.002, maxCellFraction: 0.08, mean: 255))
    }
}
