import XCTest
import AVFoundation
@testable import Snappet

/// A clip with no edits comes out of the Studio looking as it went in (prompt 304). These tests
/// need no golden image: the Studio's frame is compared with the same frame of the source file
/// decoded directly. They are what found that every export was about 18 levels too bright in the
/// mid-tones (the compositor wrote its frames with a different BT.709 curve than the one it read
/// them with), and they are what keeps it from coming back.
final class StudioPassThroughTests: StudioFixtureTestCase {

    override class var sources: [StudioGoldenSource] { [.portraitA, .portraitB, .rotated] }

    /// How far the Studio's frame may be from the directly decoded one. Measured after the fix:
    /// brightness up to 11 on single pixels (the edges of the white block, after a second H.264
    /// pass), averaged colour up to 6, a region's mean colour up to 4.2 (the two decoders place
    /// colour differently at an edge). Before the fix a region's mean was 22 to 24 off everywhere.
    static let tolerance = StudioGoldenTolerance(luma: 14, chroma: 9, maxFraction: 0.002,
                                                 maxCellFraction: 0.06, mean: 6)

    private func assertPassesThrough(_ source: StudioGoldenSource, fixture: StudioGoldenRenderer.Fixture,
                                     tolerance: StudioGoldenTolerance = StudioPassThroughTests.tolerance,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let scene = StudioGoldenScene.passThrough(source)
        for path in StudioSelfCheck.RenderPath.allCases {
            let frames = try await StudioGoldenRenderer.frames(of: scene, fixture: fixture, path: path)
            for (frame, image) in zip(scene.frames, frames) {
                let direct = try await StudioGoldenRenderer.sourceFrame(fixture.url(source), frame: frame)
                let result = StudioGoldenCompare.compare(actual: image, golden: direct, tolerance: tolerance)
                print("StudioPassThroughTests: \(source.rawValue) \(path.rawValue) frame \(frame): \(result.summary)")
                if !result.passed {
                    attach(image, "\(source.rawValue)-\(path.rawValue)-f\(frame)-studio")
                    attach(direct, "\(source.rawValue)-f\(frame)-direct")
                }
                XCTAssertTrue(result.passed, "\(source.rawValue), \(path.rawValue), frame \(frame): \(result.summary)",
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

    /// The comparison above is strict enough: a frame 18 levels brighter everywhere (what the
    /// Studio drew before the fix) fails it.
    func testTheToleranceCatchesTheOldBrightening() async throws {
        let direct = try await StudioGoldenRenderer.sourceFrame(try fixture().url(.portraitA), frame: 14)
        var brighter = direct
        for i in brighter.rgba.indices where i % 4 != 3 { brighter.rgba[i] = UInt8(min(255, Int(brighter.rgba[i]) + 18)) }
        XCTAssertFalse(StudioGoldenCompare.compare(actual: brighter, golden: direct, tolerance: Self.tolerance).passed)
        var slightly = direct
        for i in slightly.rgba.indices where i % 4 != 3 { slightly.rgba[i] = UInt8(min(255, Int(slightly.rgba[i]) + 7)) }
        XCTAssertFalse(StudioGoldenCompare.compare(actual: slightly, golden: direct, tolerance: Self.tolerance).passed,
                       "7 levels everywhere is a visible shift and must fail")
    }

    /// A wide-colour clip (tagged Display P3). AVFoundation converts it to BT.709 before the
    /// compositor sees it (`supportsWideColorSourceFrames` is off), and the export is BT.709; the
    /// frame, shown as sRGB, must be what the file shows when it is decoded directly.
    func testAWideColourClipKeepsItsColours() async throws {
        let directory = StudioGoldenRenderer.newFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try StudioGoldenRenderer.makeFixture([.wideColour], in: directory)
        try await assertPassesThrough(.wideColour, fixture: fixture, tolerance: Self.wideColourTolerance)
    }

    /// An HDR clip (10-bit HEVC, BT.2020 HLG). AVFoundation converts it to SDR BT.709 before the
    /// compositor sees it (`supportsHDRSourceFrames` is off); the Studio's output is SDR. The
    /// direct decode is tone-mapped to SDR by another part of the system, so the two are only
    /// expected to be close, not equal: the tolerance is the measured difference plus a margin.
    /// What this guards is the size of the difference, so a later change that makes HDR clips
    /// visibly lighter or darker in the Studio fails here.
    func testAnHDRClipIsExportedAsSDRCloseToItsOwnSDRPicture() async throws {
        let directory = StudioGoldenRenderer.newFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture: StudioGoldenRenderer.Fixture
        do {
            fixture = try StudioGoldenRenderer.makeFixture([.hdr], in: directory)
        } catch {
            throw XCTSkip("this machine cannot write a 10-bit HEVC file: \(error.localizedDescription)")
        }
        try await assertPassesThrough(.hdr, fixture: fixture, tolerance: Self.hdrTolerance)
    }

    /// Measured on the simulator: brightness up to 19 on a handful of pixels, a region's mean up
    /// to 6.8, the largest in the regions that straddle the line between two colours (the conversion
    /// from Display P3 smears colour across an edge a little differently on the two routes).
    static let wideColourTolerance = StudioGoldenTolerance(luma: 20, chroma: 10, maxFraction: 0.002,
                                                           maxCellFraction: 0.06, mean: 9)

    /// Measured on the simulator: brightness up to 22 on a few pixels, a region's mean up to 12.1,
    /// again largest across the line between two colours (10-bit 4:2:0 colour, tone-mapped on two
    /// routes). Loose, so this pins "no large shift", not exact colour.
    static let hdrTolerance = StudioGoldenTolerance(luma: 24, chroma: 12, maxFraction: 0.002,
                                                    maxCellFraction: 0.08, mean: 15)
}
