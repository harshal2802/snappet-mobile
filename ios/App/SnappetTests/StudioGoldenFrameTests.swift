import XCTest
import AVFoundation
import CoreImage
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
/// new golden images and then EVERY golden test fails, so a recording run is never green. (A
/// file and not an environment variable: `xcodebuild` does not pass the shell's environment to a
/// hosted unit test.)
final class StudioGoldenFrameTests: StudioFixtureTestCase {

    // MARK: The check

    private func assertScene(_ id: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let scene = try scene(id, file: file, line: line)
        let fixture = try fixture()
        if Self.isRecording {
            let images = try await StudioGoldenRenderer.frames(of: scene, fixture: fixture, path: .export)
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
            for (frame, image) in zip(scene.frames, images) {
                let data = try XCTUnwrap(StudioGoldenRenderer.pngData(image))
                try data.write(to: Self.goldenDirectory.appendingPathComponent(scene.fileName(frame: frame)))
            }
            XCTFail(Self.recordingMessage, file: file, line: line)
            return
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
    func testPhotoClip() throws { throw XCTSkip(StudioGoldenScene.pendingPhotos) }

    // MARK: The suite itself

    /// Every rendered scene has a test above, and every placeholder is one of the skipped tests,
    /// with the reason it carries. Adding a scene or filling a placeholder in changes this list.
    func testEverySceneHasATest() {
        XCTAssertEqual(StudioGoldenScene.rendered.map(\.id), [
            "cut", "trim-speed", "crop", "base-frame", "base-frame-blur", "filters",
            "transition-dissolve", "transition-fadeThroughBlack", "transition-slideLeft",
            "transition-slideRight", "transition-zoomIn", "pip", "rotated", "ken-burns", "combined"])
        let pending = StudioGoldenScene.all.filter(\.isPending)
        XCTAssertEqual(pending.map(\.id), ["text", "stickers", "climb-tags", "hr-tile", "hr-tile-transition", "photo-clip"])
        XCTAssertEqual(pending.map(\.pendingReason), [
            StudioGoldenScene.pendingOverlays, StudioGoldenScene.pendingOverlays, StudioGoldenScene.pendingOverlays,
            StudioGoldenScene.pendingHeartRate, StudioGoldenScene.pendingHeartRate, StudioGoldenScene.pendingPhotos])
        XCTAssertTrue(pending.allSatisfy { $0.frames.isEmpty && $0.clips.isEmpty })
    }

    func testRecordModeIsOff() {
        XCTAssertFalse(Self.isRecording, Self.recordingMessage)
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

    // MARK: The Studio's own entry points

    /// A scene as the project the editor would hold. `reversed` hands the clips over in the
    /// wrong order: the composer must put them back by their `order`.
    private func snapshot(_ scene: StudioGoldenScene, reversed: Bool = false) -> StudioProjectSnapshot {
        StudioProjectSnapshot(title: scene.title, aspectRaw: scene.aspect.rawValue,
                              backgroundRaw: scene.background.rawValue,
                              clips: reversed ? scene.clips.reversed() : scene.clips,
                              transitions: scene.transitions, overlays: scene.overlays, audioTracks: [],
                              baseFrame: scene.baseFrame)
    }

    /// A composer that finds the fixture files where the Studio finds Photos videos.
    private static func composer(knowing fixture: StudioGoldenRenderer.Fixture) async -> StudioComposer {
        let composer = StudioComposer()
        for source in StudioGoldenSource.golden {
            await composer.remember(url: fixture.url(source), localIdentifier: source.rawValue)
        }
        return composer
    }

    private func durations(_ scene: StudioGoldenScene) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for clip in scene.clips { out[clip.id] = StudioGoldenSource(rawValue: clip.localIdentifier)?.seconds }
        return out
    }

    /// The export the Studio's Export button runs — `StudioComposer.export(_ snapshot:)`, which
    /// orders the clips, maps the background, finds each clip's and each picture-in-picture's
    /// video and builds the composition — gives the golden frames too. (The other tests start
    /// one step later, at `assemble`.)
    func testTheStudiosOwnExportGivesTheGoldenFrames() async throws {
        if Self.isRecording { return XCTFail(Self.recordingMessage) }
        let composer = try await Self.composer(knowing: fixture())
        for (id, reversed) in [("combined", true), ("base-frame", false)] {
            let scene = try scene(id)
            let url = try await composer.export(snapshot(scene, reversed: reversed), sourceDurations: durations(scene))
            defer { try? FileManager.default.removeItem(at: url) }
            let images = try await StudioGoldenRenderer.frames(scene.frames, ofFile: url)
            for (frame, image) in zip(scene.frames, images) {
                let result = StudioGoldenCompare.compare(actual: image, golden: try golden(scene, frame: frame),
                                                         tolerance: production(.export))
                if !result.passed { attach(image, "\(id)-f\(frame)-own-export") }
                XCTAssertTrue(result.passed, "\(id) frame \(frame): \(result.summary)")
            }
        }
    }

    /// The preview the editor plays: `makeComposition(forPlayback:)`, put on an `AVPlayerItem`
    /// exactly as `StudioEditorViewModel` does, and the frame the player shows after a seek.
    @MainActor
    func testThePlayerItemTheEditorBuildsShowsTheGoldenFrames() async throws {
        if Self.isRecording { return XCTFail(Self.recordingMessage) }
        let composer = try await Self.composer(knowing: fixture())
        let scene = try scene("pip")
        let (composition, videoComposition, audioMix) = try await composer.makeComposition(
            for: snapshot(scene), sourceDurations: durations(scene), forPlayback: true)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        item.videoComposition = try XCTUnwrap(videoComposition)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0 ..< 200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "")

        let context = CIContext()
        for frame in [22, 35] {
            let time = CMTime(value: CMTimeValue(frame) * 20, timescale: 600)
            _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            // The output still holds the frame from before the seek for a moment: take buffers
            // until one is stamped with the time that was asked for.
            var buffer: CVPixelBuffer?
            for _ in 0 ..< 200 where buffer == nil {
                let now = item.currentTime()
                var shownAt = CMTime.invalid
                if output.hasNewPixelBuffer(forItemTime: now),
                   let candidate = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &shownAt),
                   abs(shownAt.seconds - time.seconds) < 1.0 / 120 {
                    buffer = candidate
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let shown = try XCTUnwrap(buffer, "the player showed no frame at \(frame)")
            let picture = CIImage(cvPixelBuffer: shown)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let cgImage = try XCTUnwrap(context.createCGImage(picture, from: picture.extent, format: .RGBA8,
                                                              colorSpace: space))
            let image = try XCTUnwrap(StudioGoldenRenderer.image(cgImage))
            let result = StudioGoldenCompare.compare(actual: image, golden: try golden(scene, frame: frame),
                                                     tolerance: production(.preview))
            if !result.passed { attach(image, "pip-f\(frame)-player") }
            XCTAssertTrue(result.passed, "frame \(frame) from the player: \(result.summary)")
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
                let a = try await StudioGoldenRenderer.sourceFrame(first.url(source), frame: frame)
                let b = try await StudioGoldenRenderer.sourceFrame(second.url(source), frame: frame)
                XCTAssertEqual(a, b, "\(source) frame \(frame)")
            }
        }
    }

    /// A source file shows what `StudioGoldenPattern` describes, in the pattern's own numbers:
    /// the block is where the frame number puts it, the quarters have their colours to within a
    /// few levels (the frames are stored with the values a BT.709 video keeps for them), and a
    /// rotated file comes out upright.
    func testSourceFilesShowThePattern() async throws {
        let fixture = try fixture()
        // Measured: brightness up to 19 on one or two pixels, colour up to 6, a region's mean up to
        // 5.9 (where a region straddles the line between two quarters; 4:2:0 colour blurs it).
        let close = StudioGoldenTolerance(luma: 14, chroma: 8, maxFraction: 0.002, maxCellFraction: 0.06, mean: 7)
        for source in [StudioGoldenSource.portraitA, .portraitB, .landscape] {
            for frame in [0, 17, 29] {
                let image = try await StudioGoldenRenderer.sourceFrame(fixture.url(source), frame: frame)
                let expected = StudioGoldenPattern.frame(source, index: frame)
                let result = StudioGoldenCompare.compare(actual: image, golden: expected, tolerance: close)
                XCTAssertTrue(result.passed, "\(source) frame \(frame): \(result.summary)")
                let neighbour = StudioGoldenPattern.frame(source, index: frame + 1)
                XCTAssertFalse(StudioGoldenCompare.compare(actual: image, golden: neighbour, tolerance: close).passed,
                               "\(source) frame \(frame) must not pass as frame \(frame + 1)")
            }
            // Well inside each quarter (clear of the corner mark and the block) the colour is the
            // palette's, to within 2.
            let image = try await StudioGoldenRenderer.sourceFrame(fixture.url(source), frame: 0)
            let w = image.width, h = image.height
            let spots = [(w / 4, 3 * h / 8), (3 * w / 4, h / 8), (w / 4, 7 * h / 8), (3 * w / 4, 7 * h / 8)]
            for (index, at) in spots.enumerated() {
                let i = (at.1 * w + at.0) * 4, colour = source.palette[index]
                XCTAssertEqual(Double(image.rgba[i]), Double(colour.r), accuracy: 2, "\(source) quarter \(index) red")
                XCTAssertEqual(Double(image.rgba[i + 1]), Double(colour.g), accuracy: 2, "\(source) quarter \(index) green")
                XCTAssertEqual(Double(image.rgba[i + 2]), Double(colour.b), accuracy: 2, "\(source) quarter \(index) blue")
            }
        }
        // The rotated file: 320×180 stored, 180×320 shown, turned a quarter clockwise — the stored
        // top-left quarter is at the top right.
        let upright = try await StudioGoldenRenderer.sourceFrame(fixture.url(.rotated), frame: 0)
        XCTAssertEqual(upright.width, 180)
        XCTAssertEqual(upright.height, 320)
        let stored = StudioGoldenSource.rotated.palette[0]
        let i = (60 * 180 + 135) * 4
        XCTAssertEqual(Double(upright.rgba[i]), Double(stored.r), accuracy: 2)
        XCTAssertEqual(Double(upright.rgba[i + 1]), Double(stored.g), accuracy: 2)
        XCTAssertEqual(Double(upright.rgba[i + 2]), Double(stored.b), accuracy: 2)
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

    /// The numbers a video stores for the pattern's colours: black and white stay, the middle
    /// moves down (a video's curve is steeper than sRGB's), and the order never changes.
    func testVideoValuesForThePattern() {
        XCTAssertEqual(StudioGoldenPattern.videoValue(forSRGB: 0), 0)
        XCTAssertEqual(StudioGoldenPattern.videoValue(forSRGB: 255), 255)
        XCTAssertEqual(Double(StudioGoldenPattern.videoValue(forSRGB: 120)), 109, accuracy: 1)
        XCTAssertEqual(Double(StudioGoldenPattern.videoValue(forSRGB: 200)), 193, accuracy: 1)
        XCTAssertLessThan(StudioGoldenPattern.videoValue(forSRGB: 60), 60)
        var last = 0
        for value in 1 ... 255 {
            let stored = Int(StudioGoldenPattern.videoValue(forSRGB: UInt8(value)))
            XCTAssertGreaterThanOrEqual(stored, last)
            last = stored
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
        // A baseline handed in (the memory before the source was written) is the one reported.
        let given = try await StudioGoldenRenderer.timedExport(scene, fixture: try fixture(), baselineBytes: 12_345)
        XCTAssertEqual(given.baselineBytes, 12_345)
        XCTAssertGreaterThan(given.addedBytes, 1_000_000)
    }

    /// Folders a killed run left behind are removed, and nothing else is.
    func testLeftoverFixtureFoldersAreRemoved() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("leftover-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stale = scratch.appendingPathComponent(StudioGoldenRenderer.fixturePrefix + "old", isDirectory: true)
        let other = scratch.appendingPathComponent("snappet-studio-export.mp4")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data([1]).write(to: stale.appendingPathComponent("portraitA.mp4"))
        try Data([1]).write(to: other)
        XCTAssertEqual(StudioGoldenRenderer.removeLeftovers(in: scratch), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(StudioGoldenRenderer.removeLeftovers(in: scratch), 0)
        XCTAssertTrue(StudioGoldenRenderer.newFixtureDirectory().lastPathComponent
            .hasPrefix(StudioGoldenRenderer.fixturePrefix))
    }
}
