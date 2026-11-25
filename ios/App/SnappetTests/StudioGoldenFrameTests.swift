import XCTest
import AVFoundation
@testable import Snappet

/// Golden frames for the Studio compositor (prompt 304). Each test renders one
/// `StudioGoldenScene` twice — through the export (a real file from `StudioComposer.export`) and
/// through the preview's video composition — and compares every listed frame with a PNG in
/// `SnappetTests/GoldenFrames/`. The check itself is `StudioGoldenRenderer.check`, the function
/// the debug "Studio render check" screen runs on a phone.
///
/// The source videos are not in the repo; `StudioGoldenRenderer.makeFixture` writes them once
/// for the whole class.
///
/// **A change to how a Studio frame looks must change a golden image in the same PR.**
///
/// To record: create the empty file `SnappetTests/GoldenFrames/.record`, run this class, delete
/// the file, run again. While the file is there every scene's export frames are written as the
/// new golden images and `testRecordModeIsOff` fails, so a recording run is never green. (A file
/// and not an environment variable: `xcodebuild` does not pass the shell's environment to a
/// hosted unit test.)
final class StudioGoldenFrameTests: XCTestCase {

    /// `SnappetTests/GoldenFrames`, found from this file's own path.
    static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("GoldenFrames", isDirectory: true)

    static var isRecording: Bool {
        FileManager.default.fileExists(atPath: goldenDirectory.appendingPathComponent(".record").path)
    }

    nonisolated(unsafe) private static var fixture: StudioGoldenRenderer.Fixture?
    nonisolated(unsafe) private static var fixtureError: String?

    override class func setUp() {
        super.setUp()
        do {
            fixture = try StudioGoldenRenderer.makeFixture(StudioGoldenSource.golden,
                                                           in: StudioGoldenRenderer.newFixtureDirectory())
        } catch {
            fixtureError = error.localizedDescription
        }
    }

    override class func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func fixture() throws -> StudioGoldenRenderer.Fixture {
        try XCTUnwrap(Self.fixture, "the fixture videos were not written: \(Self.fixtureError ?? "?")")
    }

    private static func storedGolden(_ name: String) -> StudioGoldenImage? {
        guard let data = try? Data(contentsOf: goldenDirectory.appendingPathComponent(name)) else { return nil }
        return StudioGoldenRenderer.image(pngData: data)
    }

    // MARK: The check

    private func assertScene(_ id: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let scene = try XCTUnwrap(StudioGoldenScene.all.first { $0.id == id }, "no scene \(id)", file: file, line: line)
        let fixture = try fixture()
        if Self.isRecording {
            let images = try await StudioGoldenRenderer.frames(of: scene, fixture: fixture, path: .export)
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
            for (frame, image) in zip(scene.frames, images) {
                let data = try XCTUnwrap(StudioGoldenRenderer.pngData(image))
                try data.write(to: Self.goldenDirectory.appendingPathComponent(scene.fileName(frame: frame)))
            }
        }
        let result = await StudioGoldenRenderer.check(scene, fixture: fixture, machine: .simulator) {
            Self.storedGolden($0)
        }
        guard result.status != .passed else { return }
        for check in result.frames where !check.passed {
            print("StudioGoldenFrameTests: \(id) \(check.line)")
            attach(check.actualPNG, "\(id)-f\(check.frame)-\(check.path.rawValue)-actual")
            attach(check.diffPNG, "\(id)-f\(check.frame)-\(check.path.rawValue)-diff")
            attach(try? Data(contentsOf: Self.goldenDirectory.appendingPathComponent(check.goldenName)),
                   "\(id)-f\(check.frame)-golden")
        }
        let lines = result.frames.filter { !$0.passed }.map(\.line)
        if case .failed(let reason) = result.status {
            XCTFail("\(scene.title): \(reason)\n" + lines.joined(separator: "\n"), file: file, line: line)
        }
    }

    private func attach(_ png: Data?, _ name: String) {
        guard let png else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Scenes — what the compositor draws today

    func testPlainCut() async throws { try await assertScene("cut") }
    func testTrimAndSpeed() async throws { try await assertScene("trim-speed") }
    func testCrop() async throws { try await assertScene("crop") }
    func testBaseFrameOverAWhiteBackground() async throws { try await assertScene("base-frame") }
    func testBaseFrameOverABlurredBackground() async throws { try await assertScene("base-frame-blur") }
    func testFiltersAndAdjust() async throws { try await assertScene("filters") }
    func testTransitionDissolve() async throws { try await assertScene("transition-dissolve") }
    func testTransitionFadeThroughBlack() async throws { try await assertScene("transition-fadeThroughBlack") }
    func testTransitionSlideLeft() async throws { try await assertScene("transition-slideLeft") }
    func testTransitionSlideRight() async throws { try await assertScene("transition-slideRight") }
    func testTransitionZoomIn() async throws { try await assertScene("transition-zoomIn") }
    func testPictureInPicture() async throws { try await assertScene("pip") }
    func testRotatedSource() async throws { try await assertScene("rotated") }
    func testZoomKeyframes() async throws { try await assertScene("ken-burns") }
    func testFilterTransitionAndPictureInPictureTogether() async throws { try await assertScene("combined") }

    // MARK: Placeholders — not drawn by the compositor yet

    func testText() throws { throw XCTSkip(StudioGoldenScene.pendingOverlays) }
    func testStickers() throws { throw XCTSkip(StudioGoldenScene.pendingOverlays) }
    func testClimbTags() throws { throw XCTSkip(StudioGoldenScene.pendingOverlays) }
    func testHeartRateTile() throws { throw XCTSkip(StudioGoldenScene.pendingHeartRate) }
    func testHeartRateTileAcrossATransition() throws { throw XCTSkip(StudioGoldenScene.pendingHeartRate) }

    // MARK: The suite itself

    /// Every rendered scene has a test above, and every placeholder is one of the skipped tests.
    func testEverySceneHasATest() {
        XCTAssertEqual(StudioGoldenScene.rendered.map(\.id), [
            "cut", "trim-speed", "crop", "base-frame", "base-frame-blur", "filters",
            "transition-dissolve", "transition-fadeThroughBlack", "transition-slideLeft",
            "transition-slideRight", "transition-zoomIn", "pip", "rotated", "ken-burns", "combined"])
    }

    func testRecordModeIsOff() {
        XCTAssertFalse(Self.isRecording,
                       "Golden images were recorded in this run. Delete SnappetTests/GoldenFrames/.record and run again.")
    }

    /// The folder holds exactly the images the scenes name: none missing, none left over.
    func testGoldenFolderHoldsExactlyTheScenesImages() throws {
        let present = try FileManager.default.contentsOfDirectory(atPath: Self.goldenDirectory.path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(Set(present), Set(StudioGoldenScene.fileNames))
    }

    /// The Debug app carries the same images (the self-check screen reads them from the bundle).
    func testTheAppBundleCarriesTheSameGoldenImages() throws {
        for name in StudioGoldenScene.fileNames {
            let bundled = try XCTUnwrap(StudioGoldenRenderer.bundledGoldenURL(name).flatMap { try? Data(contentsOf: $0) },
                                        "\(name) is not in the app bundle")
            let stored = try Data(contentsOf: Self.goldenDirectory.appendingPathComponent(name))
            XCTAssertEqual(bundled, stored, "\(name) in the app is not the one in the repo; build again")
        }
    }

    /// The export and the preview are built from the same plan: the same time ranges, the same
    /// layers. Only the export has the overlay tool.
    func testPreviewAndExportCompositionsHaveTheSameInstructions() async throws {
        let fixture = try fixture()
        for scene in StudioGoldenScene.rendered {
            let composer = StudioComposer()
            let (_, exportVC, _) = try await StudioGoldenRenderer.assemble(scene, fixture: fixture, composer: composer,
                                                                          forPlayback: false)
            let (_, previewVC, _) = try await StudioGoldenRenderer.assemble(scene, fixture: fixture, composer: composer,
                                                                           forPlayback: true)
            let a = try XCTUnwrap(exportVC?.instructions as? [StudioCompositionInstruction], scene.id)
            let b = try XCTUnwrap(previewVC?.instructions as? [StudioCompositionInstruction], scene.id)
            XCTAssertNil(previewVC?.animationTool, scene.id)
            XCTAssertEqual(exportVC?.renderSize, previewVC?.renderSize, scene.id)
            XCTAssertEqual(exportVC?.frameDuration, previewVC?.frameDuration, scene.id)
            XCTAssertEqual(a.count, b.count, scene.id)
            for (x, y) in zip(a, b) {
                XCTAssertEqual(x.timeRange, y.timeRange, scene.id)
                XCTAssertEqual(x.canvas, y.canvas, scene.id)
                XCTAssertEqual(x.background, y.background, scene.id)
                XCTAssertEqual(x.main.map(\.layer), y.main.map(\.layer), scene.id)
                XCTAssertEqual(x.pips.map(\.layer), y.pips.map(\.layer), scene.id)
            }
        }
    }

    // MARK: The fixture

    /// Two writes of the same source decode to the same pixels, so a golden image does not
    /// depend on which run wrote the source.
    func testWritingASourceTwiceGivesTheSamePictures() async throws {
        let first = try fixture()
        let second = try StudioGoldenRenderer.makeFixture([.portraitA, .rotated],
                                                          in: StudioGoldenRenderer.newFixtureDirectory())
        defer { second.remove() }
        for source in [StudioGoldenSource.portraitA, .rotated] {
            for frame in [0, 17, 29] {
                let a = try await decoded(first.url(source), frame: frame)
                let b = try await decoded(second.url(source), frame: frame)
                XCTAssertEqual(a, b, "\(source) frame \(frame)")
            }
        }
    }

    /// A source file shows what `StudioGoldenPattern` describes: the block is where the frame
    /// number puts it, the quarters have their colours, and a rotated file comes out upright.
    func testSourceFilesShowThePattern() async throws {
        let fixture = try fixture()
        let loose = StudioGoldenTolerance(luma: 24, chroma: 20, maxFraction: 0.02, maxCellFraction: 0.2)
        for source in [StudioGoldenSource.portraitA, .portraitB, .landscape] {
            for frame in [0, 17, 29] {
                let image = try await decoded(fixture.url(source), frame: frame)
                let expected = StudioGoldenPattern.frame(source, index: frame)
                let result = StudioGoldenCompare.compare(actual: image, golden: expected, tolerance: loose)
                XCTAssertTrue(result.passed, "\(source) frame \(frame): \(result.summary)")
                let neighbour = StudioGoldenPattern.frame(source, index: frame + 1)
                XCTAssertFalse(StudioGoldenCompare.compare(actual: image, golden: neighbour, tolerance: loose).passed,
                               "\(source) frame \(frame) must not pass as frame \(frame + 1)")
            }
        }
        // The rotated file: 320×180 stored, 180×320 shown, turned a quarter clockwise — the stored
        // top-left quarter is at the top right.
        let upright = try await decoded(fixture.url(.rotated), frame: 0)
        XCTAssertEqual(upright.width, 180)
        XCTAssertEqual(upright.height, 320)
        let stored = StudioGoldenSource.rotated.palette[0]
        let i = (40 * 180 + 135) * 4
        XCTAssertEqual(Double(upright.rgba[i]), Double(stored.r), accuracy: 24)
        XCTAssertEqual(Double(upright.rgba[i + 1]), Double(stored.g), accuracy: 24)
        XCTAssertEqual(Double(upright.rgba[i + 2]), Double(stored.b), accuracy: 24)
        // Every source has sound.
        for source in StudioGoldenSource.golden {
            let asset = AVURLAsset(url: fixture.url(source))
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1, "\(source)")
            let video = try await asset.loadTracks(withMediaType: .video)
            let range = try await XCTUnwrap(video.first).load(.timeRange)
            XCTAssertEqual(range.duration.seconds, 1, accuracy: 0.001, "\(source)")
        }
    }

    /// The timed export's own code, on a small scene: it writes a file, times it and reads the
    /// app's memory. (The real one is 20 s at 1080×1920 and is for a phone.)
    func testTimedExportReportsItsNumbers() async throws {
        let scene = StudioGoldenScene.timedScene(source: .portraitA, transitionSec: 0.25)
        let timing = try await StudioGoldenRenderer.timedExport(scene, fixture: try fixture())
        XCTAssertEqual(timing.outputSeconds, 4, accuracy: 0.05)
        XCTAssertEqual(timing.width, 180)
        XCTAssertEqual(timing.height, 320)
        XCTAssertGreaterThan(timing.exportSeconds, 0)
        XCTAssertGreaterThan(timing.baselineBytes, 1_000_000)
        XCTAssertGreaterThanOrEqual(timing.peakBytes, timing.baselineBytes)
        XCTAssertGreaterThan(timing.fileBytes, 1_000)
        XCTAssertEqual(timing.lines.count, 3)
    }

    private func decoded(_ url: URL, frame: Int) async throws -> StudioGoldenImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let cgImage = try await generator.image(at: CMTime(value: CMTimeValue(frame) * 20, timescale: 600)).image
        return try XCTUnwrap(StudioGoldenRenderer.image(cgImage))
    }
}
