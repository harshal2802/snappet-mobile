import XCTest
@testable import Snappet

/// The pure decisions of the Studio render check (prompt 304): the fixture pattern, the scene
/// list, the tolerances, the pass / fail roll-up and the report text.
final class StudioSelfCheckPlanTests: XCTestCase {

    // MARK: Fixture pattern

    func testTheBlockMovesAFixedStepEveryFrameAndStartsAgain() {
        // 180 wide: a 30-pixel block, 6 pixels a frame, 151 places to be.
        XCTAssertEqual(StudioGoldenPattern.blockSide(width: 180, height: 320), 30)
        XCTAssertEqual(StudioGoldenPattern.blockStep(width: 180), 6)
        XCTAssertEqual(StudioGoldenPattern.blockOrigin(frame: 0, width: 180, height: 320).x, 0)
        XCTAssertEqual(StudioGoldenPattern.blockOrigin(frame: 17, width: 180, height: 320).x, 102)
        XCTAssertEqual(StudioGoldenPattern.blockOrigin(frame: 25, width: 180, height: 320).x, 150)
        XCTAssertEqual(StudioGoldenPattern.blockOrigin(frame: 26, width: 180, height: 320).x, 5)
        XCTAssertEqual(StudioGoldenPattern.blockOrigin(frame: 17, width: 180, height: 320).y, 145)
        // 320 wide: 10 pixels a frame.
        XCTAssertEqual(StudioGoldenPattern.blockStep(width: 320), 10)
        XCTAssertEqual(StudioGoldenPattern.blockOrigin(frame: 10, width: 320, height: 180).x, 100)
        // No two frames that are next to each other look the same.
        for index in 0 ..< 59 {
            XCTAssertNotEqual(StudioGoldenPattern.blockOrigin(frame: index, width: 180, height: 320).x,
                              StudioGoldenPattern.blockOrigin(frame: index + 1, width: 180, height: 320).x)
        }
    }

    func testAFrameHasFourQuartersAMarkAndTheBlock() {
        let image = StudioGoldenPattern.frame(.portraitA, index: 17)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(image.rgba[(y * 180 + x) * 4 ..< (y * 180 + x) * 4 + 3]) }
        XCTAssertEqual(pixel(60, 60), [200, 60, 60])
        XCTAssertEqual(pixel(120, 60), [60, 170, 80])
        XCTAssertEqual(pixel(60, 260), [60, 90, 200])
        XCTAssertEqual(pixel(120, 260), [215, 185, 60])
        XCTAssertEqual(pixel(15, 15), [0, 0, 0], "the corner mark")
        XCTAssertEqual(pixel(102, 145), [255, 255, 255], "the block's first pixel")
        XCTAssertEqual(pixel(131, 174), [255, 255, 255], "the block's last pixel")
        XCTAssertEqual(pixel(101, 150), [60, 170, 80], "left of the block")
        XCTAssertEqual(pixel(132, 170), [215, 185, 60], "right of the block")
    }

    func testSourcesHaveDifferentColoursAndEvenSizes() {
        let sources = StudioGoldenSource.golden
        XCTAssertEqual(sources.count, 4)
        var seen: Set<[UInt8]> = []
        for source in sources {
            XCTAssertEqual(source.bufferWidth % 2, 0)
            XCTAssertEqual(source.bufferHeight % 2, 0)
            XCTAssertEqual(source.frameCount, 30)
            for colour in source.palette {
                XCTAssertTrue(seen.insert([colour.r, colour.g, colour.b]).inserted, "\(source) repeats a colour")
            }
        }
        XCTAssertTrue(StudioGoldenSource.rotated.isRotated)
        XCTAssertFalse(sources.contains(.large))
        XCTAssertEqual(StudioGoldenSource.large.frameCount, 150)
    }

    // MARK: Scenes

    func testSceneIDsAndFileNamesAreUnique() {
        let scenes = StudioGoldenScene.all
        XCTAssertEqual(Set(scenes.map(\.id)).count, scenes.count)
        let names = StudioGoldenScene.fileNames
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(StudioGoldenScene.all.first { $0.id == "cut" }?.fileName(frame: 29), "cut-f029.png")
        XCTAssertEqual(names.count, 56)
    }

    /// The list covers what the compositor draws today.
    func testScenesCoverEveryFilterAndEveryTransition() {
        let rendered = StudioGoldenScene.rendered
        let filters = Set(rendered.flatMap(\.clips).map(\.filter))
        XCTAssertEqual(filters, Set(StudioFilter.allCases))
        XCTAssertTrue(rendered.flatMap(\.clips).contains { $0.adjust != nil && $0.filter == .none })
        let kinds = Set(rendered.flatMap(\.transitions).map(\.kind))
        XCTAssertEqual(kinds, Set(StudioTransitionKind.allCases).subtracting([.none]))
        XCTAssertTrue(rendered.contains { $0.clips.contains { $0.speed != 1 && $0.trimStart > 0 } })
        XCTAssertTrue(rendered.contains { $0.baseFrame != nil && $0.background == .white })
        XCTAssertTrue(rendered.contains { $0.baseFrame != nil && $0.background == .blur && $0.aspect == .square1x1 })
        XCTAssertTrue(rendered.contains { $0.clips.contains { !$0.scaleKeyframes.isEmpty } })
        XCTAssertTrue(rendered.contains { $0.clips.contains { $0.localIdentifier == StudioGoldenSource.rotated.rawValue } })
        XCTAssertTrue(rendered.contains { scene in
            scene.overlays.contains { $0.kind == .video && $0.rotationDegrees != 0 && !$0.opacityKeyframes.isEmpty
                && $0.endSec < scene.durationSec }
        })
    }

    func testEveryFrameIsInsideItsSceneAndEverySourceExists() {
        for scene in StudioGoldenScene.rendered + [StudioGoldenScene.timed] {
            XCTAssertFalse(scene.clips.isEmpty, scene.id)
            for clip in scene.clips { XCTAssertNotNil(StudioGoldenSource(rawValue: clip.localIdentifier), scene.id) }
            for overlay in scene.overlays { XCTAssertNotNil(StudioGoldenSource(rawValue: overlay.content), scene.id) }
            let lastFrame = Int((scene.durationSec * 30).rounded()) - 1
            for frame in scene.frames { XCTAssertTrue((0 ... lastFrame).contains(frame), "\(scene.id) frame \(frame)") }
            XCTAssertEqual(Set(scene.frames).count, scene.frames.count, scene.id)
        }
        XCTAssertFalse(StudioGoldenScene.rendered.isEmpty)
        for scene in StudioGoldenScene.rendered { XCTAssertFalse(scene.frames.isEmpty, scene.id) }
    }

    func testSceneLengths() throws {
        func scene(_ id: String) throws -> StudioGoldenScene { try XCTUnwrap(StudioGoldenScene.all.first { $0.id == id }) }
        XCTAssertEqual(try scene("cut").durationSec, 2, accuracy: 1e-9)
        XCTAssertEqual(try scene("trim-speed").durationSec, 1.3, accuracy: 1e-9)
        XCTAssertEqual(try scene("filters").durationSec, 1.8, accuracy: 1e-9)
        XCTAssertEqual(try scene("transition-dissolve").durationSec, 1.4, accuracy: 1e-9)
        XCTAssertEqual(StudioGoldenScene.timed.durationSec, 20, accuracy: 1e-9)
        let overlay = try XCTUnwrap(StudioGoldenScene.timed.overlays.first)
        XCTAssertEqual(overlay.startSec, 2, accuracy: 1e-9)
        XCTAssertEqual(overlay.endSec, 18, accuracy: 1e-9)
        XCTAssertEqual(StudioGoldenScene.timedScene(source: .portraitA, transitionSec: 0.25).durationSec, 4, accuracy: 1e-9)
        XCTAssertTrue(StudioGoldenScene.timed.frames.isEmpty, "the timed export has no golden frames")
    }

    func testPlaceholdersNameThePromptThatFillsThemIn() {
        let pending = StudioGoldenScene.all.filter(\.isPending)
        XCTAssertEqual(pending.map(\.id), ["text", "stickers", "climb-tags", "hr-tile", "hr-tile-transition", "photo-clip"])
        XCTAssertEqual(pending.first { $0.id == "text" }?.pendingReason, "drawn by the compositor from prompt 305")
        XCTAssertEqual(pending.first { $0.id == "hr-tile" }?.pendingReason, "drawn by the compositor from prompt 306")
        for scene in pending { XCTAssertTrue(scene.frames.isEmpty && scene.clips.isEmpty) }
    }

    func testHeartRateFixtureIsFortySamplesOneASecond() {
        let series = StudioGoldenScene.heartRate
        XCTAssertEqual(series.count, 40)
        XCTAssertEqual(series.map(\.t), (0 ..< 40).map(Double.init))
        XCTAssertEqual(series.first?.bpm, 96)
        XCTAssertEqual(series.map(\.bpm).max(), 172)
        XCTAssertEqual(series.last?.bpm, 112)
    }

    // MARK: Tolerances

    func testEveryToleranceIsLooserThanTheOneBeforeIt() {
        let order: [(StudioSelfCheck.Machine, StudioSelfCheck.RenderPath)] = [
            (.simulator, .export), (.simulator, .preview), (.device, .export), (.device, .preview)]
        let values = order.map { StudioSelfCheck.tolerance(for: $0.1, on: $0.0) }
        for (tight, loose) in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(tight.luma, loose.luma)
            XCTAssertLessThanOrEqual(tight.chroma, loose.chroma)
            XCTAssertLessThanOrEqual(tight.maxFraction, loose.maxFraction)
            XCTAssertLessThanOrEqual(tight.maxCellFraction, loose.maxCellFraction)
        }
        XCTAssertNotEqual(values.first, values.last)
    }

    /// Whatever the tolerance, the mistakes the goldens are for still fail: the block one frame
    /// out of place, and the block missing.
    func testTheLoosestToleranceStillFailsAOneFrameShiftAndAMissingBlock() {
        let golden = StudioGoldenPattern.frame(.portraitA, index: 17)
        let shifted = StudioGoldenPattern.frame(.portraitA, index: 18)
        let missing = StudioGoldenPattern.background(width: 180, height: 320, palette: StudioGoldenSource.portraitA.palette)
        for machine in [StudioSelfCheck.Machine.simulator, .device] {
            for path in StudioSelfCheck.RenderPath.allCases {
                let tolerance = StudioSelfCheck.tolerance(for: path, on: machine)
                XCTAssertFalse(StudioGoldenCompare.compare(actual: shifted, golden: golden, tolerance: tolerance).passed,
                               "\(machine) \(path): one frame late")
                XCTAssertFalse(StudioGoldenCompare.compare(actual: missing, golden: golden, tolerance: tolerance).passed,
                               "\(machine) \(path): no block")
                XCTAssertTrue(StudioGoldenCompare.compare(actual: golden, golden: golden, tolerance: tolerance).passed)
            }
        }
    }

    // MARK: Roll-up

    private let tight = StudioGoldenTolerance(luma: 12, chroma: 12, maxFraction: 0.002, maxCellFraction: 0.08)

    private func check(_ frame: Int, _ path: StudioSelfCheck.RenderPath, passes: Bool) -> StudioSelfCheck.FrameCheck {
        let golden = StudioGoldenImage(width: 32, height: 32, r: 10, g: 10, b: 10)
        let actual = passes ? golden : StudioGoldenImage(width: 32, height: 32, r: 200, g: 10, b: 10)
        return .init(frame: frame, path: path, goldenName: "s-f\(frame).png",
                     outcome: .compared(StudioGoldenCompare.compare(actual: actual, golden: golden, tolerance: tight)))
    }

    func testASceneNeedsEveryFrameOnBothPaths() {
        let both = [check(1, .export, passes: true), check(2, .export, passes: true),
                    check(1, .preview, passes: true), check(2, .preview, passes: true)]
        XCTAssertEqual(StudioSelfCheck.status(frames: both, expectedFrames: 2), .passed)
        XCTAssertEqual(StudioSelfCheck.status(frames: Array(both.prefix(2)), expectedFrames: 2),
                       .failed("2 of 4 frames were checked"))
        XCTAssertEqual(StudioSelfCheck.status(frames: [], expectedFrames: 2), .failed("no frame was rendered"))
        XCTAssertEqual(StudioSelfCheck.status(frames: both, expectedFrames: 2, error: "boom"), .failed("boom"))
    }

    func testOneFailingFrameFailsTheSceneAndIsNamed() {
        var frames = [check(1, .export, passes: true), check(1, .preview, passes: false)]
        guard case .failed(let reason) = StudioSelfCheck.status(frames: frames, expectedFrames: 1) else {
            return XCTFail("a differing frame must fail the scene")
        }
        XCTAssertTrue(reason.hasPrefix("frame 1 (preview): FAIL — 1024 of 1024 pixels differ"), reason)

        frames.append(.init(frame: 2, path: .export, goldenName: "s-f002.png", outcome: .missingGolden))
        guard case .failed(let two) = StudioSelfCheck.status(frames: frames, expectedFrames: 1) else {
            return XCTFail("still failing")
        }
        XCTAssertTrue(two.hasPrefix("2 frames differ; first: frame 1 (preview)"), two)
        XCTAssertEqual(frames[2].line, "frame 2 (export): FAIL — no golden image s-f002.png")
        XCTAssertFalse(frames[2].passed)
    }

    func testSummaryCountsAndNeedsSomethingChecked() {
        let passed = StudioSelfCheck.SceneResult(id: "a", title: "A", status: .passed)
        let failed = StudioSelfCheck.SceneResult(id: "b", title: "B", status: .failed("x"))
        let skipped = StudioSelfCheck.skipped(StudioGoldenScene(id: "text", title: "Text",
                                                               pendingReason: StudioGoldenScene.pendingOverlays))
        XCTAssertEqual(skipped.status, .skipped("drawn by the compositor from prompt 305"))
        XCTAssertEqual(StudioSelfCheck.summary([passed, passed, skipped]),
                       .init(passed: 2, failed: 0, skipped: 1))
        XCTAssertTrue(StudioSelfCheck.summary([passed, skipped]).allPassed)
        XCTAssertFalse(StudioSelfCheck.summary([passed, failed, skipped]).allPassed)
        XCTAssertFalse(StudioSelfCheck.summary([skipped]).allPassed, "nothing was checked")
        XCTAssertFalse(StudioSelfCheck.summary([]).allPassed)
        XCTAssertEqual(StudioSelfCheck.summary([passed, failed, skipped]).line, "1 passed, 1 failed, 1 skipped")
        XCTAssertEqual(StudioSelfCheck.summary([passed]).line, "1 passed, 0 failed")
        XCTAssertEqual([passed, failed, skipped].map(\.status.word), ["pass", "fail", "skipped"])
    }

    // MARK: Timing and report

    private let timing = StudioSelfCheck.Timing(outputSeconds: 20, width: 1080, height: 1920, exportSeconds: 8,
                                                baselineBytes: 200 * 1_048_576, peakBytes: 452 * 1_048_576,
                                                fileBytes: 31_457_280)

    func testTimingLines() {
        XCTAssertEqual(timing.speed, 2.5, accuracy: 1e-9)
        XCTAssertEqual(timing.addedBytes, 252 * 1_048_576)
        XCTAssertEqual(timing.lines, [
            "20.0 s at 1080×1920 exported in 8.00 s (2.5× real time)",
            "Peak memory 452.0 MB (252.0 MB above the 200.0 MB before the export)",
            "File 30.0 MB"])
        var odd = timing
        odd.peakBytes = 100
        odd.exportSeconds = 0
        XCTAssertEqual(odd.addedBytes, 0)
        XCTAssertEqual(odd.speed, 0)
    }

    func testReportText() {
        var passed = StudioSelfCheck.SceneResult(id: "cut", title: "Plain cut", status: .passed)
        passed.frames = [check(1, .export, passes: true), check(1, .preview, passes: true)]
        passed.seconds = 0.5
        let bad = check(3, .preview, passes: false)
        var failed = StudioSelfCheck.SceneResult(id: "pip", title: "Picture-in-picture",
                                                 status: StudioSelfCheck.status(frames: [bad], expectedFrames: 1))
        failed.frames = [bad]
        let skipped = StudioSelfCheck.SceneResult(id: "text", title: "Text",
                                                  status: .skipped(StudioGoldenScene.pendingOverlays))
        let machine = StudioSelfCheck.Machine.device
        let report = StudioSelfCheck.report(header: ["iPhone 15 Pro, iOS 18.1"], machine: machine,
                                            results: [passed, failed, skipped], timing: timing)
        let lines = report.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Snappet Studio render check")
        XCTAssertEqual(lines[1], "iPhone 15 Pro, iOS 18.1")
        XCTAssertEqual(lines[2], "Result: FAIL — 1 passed, 1 failed, 1 skipped")
        let export = StudioSelfCheck.tolerance(for: .export, on: machine)
        XCTAssertEqual(lines[3], "Tolerance, export on device: brightness \(export.luma), colour \(export.chroma), "
            + "frame \(StudioGoldenCompare.Result.percent(export.maxFraction)), "
            + "one region \(StudioGoldenCompare.Result.percent(export.maxCellFraction))")
        XCTAssertTrue(lines[4].hasPrefix("Tolerance, preview on device: brightness "), lines[4])
        XCTAssertTrue(lines.contains("pass     cut — 2 frames, 0.50 s"), report)
        XCTAssertTrue(lines.contains { $0.hasPrefix("FAIL     pip — frame 3 (preview): FAIL — 1024 of 1024 pixels differ") }, report)
        XCTAssertTrue(lines.contains { $0.hasPrefix("         frame 3 (preview): FAIL") }, report)
        XCTAssertTrue(lines.contains("skipped  text — drawn by the compositor from prompt 305"), report)
        XCTAssertTrue(lines.contains("Timed export"), report)
        XCTAssertEqual(lines.last, "File 30.0 MB")

        let good = StudioSelfCheck.report(header: [], machine: .simulator, results: [passed, skipped], timing: nil)
        XCTAssertTrue(good.contains("Result: PASS — 1 passed, 0 failed, 1 skipped"), good)
        XCTAssertTrue(good.hasSuffix("Timed export: not run"), good)
        let broken = StudioSelfCheck.report(header: [], machine: .simulator, results: [passed], timing: nil,
                                            timingError: "no space")
        XCTAssertTrue(broken.hasSuffix("Timed export failed: no space"), broken)
    }
}
