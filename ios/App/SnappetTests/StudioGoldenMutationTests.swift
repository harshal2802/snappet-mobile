import XCTest
import AVFoundation
@testable import Snappet

/// Proof that the golden frames catch what they are there to catch (prompt 304). Each test renders
/// a golden scene with ONE thing wrong — the regression a later change could introduce — through
/// the real export and the real preview, compares it with the stored golden image at the same
/// tolerance the golden tests use, and requires the comparison to FAIL.
///
/// These are the changes that are small everywhere and large nowhere, which the "is any pixel
/// far off?" rules let through; the per-region mean colour (`StudioGoldenTolerance.mean`) is
/// what catches them. Measured sizes are in `pdd/context/decisions.md`.
final class StudioGoldenMutationTests: StudioFixtureTestCase {

    private func assertCaught(_ id: String, frames: [Int], _ what: String,
                              on paths: [StudioSelfCheck.RenderPath] = StudioSelfCheck.RenderPath.allCases,
                              file: StaticString = #filePath, line: UInt = #line,
                              change: (inout StudioGoldenScene) -> Void) async throws {
        if Self.isRecording { return XCTFail(Self.recordingMessage, file: file, line: line) }
        var mutant = try scene(id, file: file, line: line)
        change(&mutant)
        for path in paths {
            let images = try await StudioGoldenRenderer.frames(of: mutant, fixture: try fixture(), path: path)
            for frame in frames {
                let index = try XCTUnwrap(mutant.frames.firstIndex(of: frame), file: file, line: line)
                let result = StudioGoldenCompare.compare(actual: images[index], golden: try golden(mutant, frame: frame),
                                                         tolerance: production(path))
                XCTAssertFalse(result.passed, "\(what): frame \(frame) passed the \(path.rawValue) comparison — "
                               + result.summary, file: file, line: line)
            }
        }
    }

    // The "filters" scene is nine 0.2 s pieces; piece n is frame 6 n + 3.

    func testAMissingWarmFilterIsCaught() async throws {
        try await assertCaught("filters", frames: [33], "warm not applied") { $0.clips[5].filter = .none }
    }

    func testAMissingCoolFilterIsCaught() async throws {
        try await assertCaught("filters", frames: [39], "cool not applied") { $0.clips[6].filter = .none }
    }

    /// The smallest of them: the filter at 0.7 for 1 moves a region's mean colour by about 5,
    /// and at 1 for 0.7 (under an adjust) by about 4. Above the export's 3; under the preview's 6,
    /// which has to leave room for the 4 that the preview itself differs by at a colour edge.
    func testAFilterAtTheWrongStrengthIsCaughtOnExport() async throws {
        try await assertCaught("filters", frames: [33], "warm at 0.7 for 1", on: [.export]) {
            $0.clips[5].filterIntensity = 0.7
        }
        try await assertCaught("filters", frames: [51], "warm at 1 for 0.7, under an adjust", on: [.export]) {
            $0.clips[8].filterIntensity = 1
        }
    }

    func testAFilterDroppedFromUnderAnAdjustIsCaught() async throws {
        try await assertCaught("filters", frames: [51], "warm dropped, adjust kept") { $0.clips[8].filter = .none }
    }

    func testAMissingFilterOnTheSecondClipOfTheCombinedSceneIsCaught() async throws {
        try await assertCaught("combined", frames: [21, 35], "cool not applied to the second clip") {
            $0.clips[1].filter = .none
        }
    }

    /// The picture-in-picture is at 20 % until 0.5 s and at 100 % from 1 s.
    func testAPictureInPictureATenthTooOpaqueIsCaught() async throws {
        try await assertCaught("pip", frames: [9, 22], "opacity 0.3 for 0.2") {
            $0.overlays[0].opacityKeyframes[0].value = 0.3
        }
    }

    func testAPictureInPictureATenthTooFaintIsCaught() async throws {
        try await assertCaught("pip", frames: [22, 35, 38], "opacity 0.9 for 1") {
            $0.overlays[0].opacityKeyframes[1].value = 0.9
        }
    }

    /// A dissolve that eases (smoothstep) where the plan says linear. The scene cannot say that,
    /// so the composition's instructions are rewritten: for the frame under test, each
    /// transition's time range is moved so that its progress at that instant is the eased one.
    /// Frames 17 and 25 are 0.278 and 0.722 of the way through (the nearest frames to a quarter
    /// and three quarters); frame 21 is the middle, where the two curves agree, and is not
    /// checked.
    func testADissolveAtTheWrongProgressIsCaught() async throws {
        if Self.isRecording { return XCTFail(Self.recordingMessage) }
        let dissolve = try scene("transition-dissolve")
        for path in StudioSelfCheck.RenderPath.allCases {
            for frame in [17, 25] {
                let composer = StudioComposer()
                let (composition, videoComposition, audioMix) = try await StudioGoldenRenderer.assemble(
                    dissolve, fixture: try fixture(), composer: composer, forPlayback: path == .preview)
                let mutable = try XCTUnwrap(videoComposition?.mutableCopy() as? AVMutableVideoComposition)
                let instructions = try XCTUnwrap(mutable.instructions as? [StudioCompositionInstruction])
                let t = Double(frame) / Double(StudioGoldenPattern.fps)
                mutable.instructions = instructions.map { Self.eased($0, at: t) }
                let images = try await StudioGoldenRenderer.frames(
                    [frame], composition: composition, videoComposition: mutable, audioMix: audioMix,
                    path: path, composer: composer)
                let result = StudioGoldenCompare.compare(actual: images[0], golden: try golden(dissolve, frame: frame),
                                                         tolerance: production(path))
                XCTAssertFalse(result.passed, "an eased dissolve passed the \(path.rawValue) comparison on frame "
                               + "\(frame) — \(result.summary)")
            }
        }
    }

    /// `instruction` with every transition's range moved so that at `t` its progress is
    /// smoothstep of what it was.
    private static func eased(_ instruction: StudioCompositionInstruction, at t: Double) -> StudioCompositionInstruction {
        func eased(_ phase: StudioRenderPlan.TransitionPhase?) -> StudioRenderPlan.TransitionPhase? {
            guard let phase else { return nil }
            let p = phase.progress(at: t), smooth = p * p * (3 - 2 * p), span = phase.endSec - phase.startSec
            return StudioRenderPlan.TransitionPhase(kind: phase.kind, startSec: t - smooth * span,
                                                    endSec: t - smooth * span + span)
        }
        return StudioCompositionInstruction(
            timeRange: instruction.timeRange, canvas: instruction.canvas, background: instruction.background,
            main: instruction.main.map { entry in
                let layer = entry.layer
                return (StudioRenderPlan.MainLayer(
                    clipID: layer.clipID, trackIndex: layer.trackIndex, placement: layer.placement,
                    filter: layer.filter, filterIntensity: layer.filterIntensity, adjust: layer.adjust,
                    scaleKeyframes: layer.scaleKeyframes, clipStartSec: layer.clipStartSec,
                    entering: eased(layer.entering), leaving: eased(layer.leaving)), entry.source)
            },
            pips: instruction.pips)
    }

    /// The rewrite above changes nothing but the progress: with the plan's own (linear) timing
    /// put back through the same code path, the frame is the golden one.
    func testTheRewrittenInstructionsDrawTheGoldenFrameWhenNothingIsChanged() async throws {
        if Self.isRecording { return XCTFail(Self.recordingMessage) }
        let dissolve = try scene("transition-dissolve")
        let composer = StudioComposer()
        let (composition, videoComposition, audioMix) = try await StudioGoldenRenderer.assemble(
            dissolve, fixture: try fixture(), composer: composer, forPlayback: false)
        let mutable = try XCTUnwrap(videoComposition?.mutableCopy() as? AVMutableVideoComposition)
        let instructions = try XCTUnwrap(mutable.instructions as? [StudioCompositionInstruction])
        // At the middle of the overlap smoothstep(0.5) is 0.5, so the rewrite is the identity there.
        mutable.instructions = instructions.map { Self.eased($0, at: 21.0 / 30) }
        let images = try await StudioGoldenRenderer.frames(
            [21], composition: composition, videoComposition: mutable, audioMix: audioMix,
            path: .export, composer: composer)
        let result = StudioGoldenCompare.compare(actual: images[0], golden: try golden(dissolve, frame: 21),
                                                 tolerance: production(.export))
        XCTAssertTrue(result.passed, result.summary)
    }
}
