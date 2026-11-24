import XCTest
import AVFoundation
import CoreGraphics
import SwiftData
@testable import Snappet

/// The one Studio compositor, rendered for real (prompt 300). Each test writes small solid-colour
/// videos with `AVAssetWriter`, builds a composition through `StudioComposer.assemble(resolved:)`
/// (no Photos), reads frames back with `AVAssetImageGenerator` and checks pixel colours. The export
/// test writes a file with `AVAssetExportSession` and reads its video and audio. Runs on the
/// simulator at 180×320.
final class StudioCompositorRenderTests: XCTestCase {

    private let size = CGSize(width: 180, height: 320)          // portrait 9:16 → the canvas
    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    // MARK: A filter and a picture-in-picture together

    /// Before prompt 300 a picture-in-picture forced the layer path, which dropped filters.
    func testFilteredClipIsFilteredWhileAPictureInPictureIsPresent() async throws {
        let red = try video(.red), green = try video(.green, size: CGSize(width: 160, height: 90))
        let pip = cornerPiP()
        let (comp, vc, _) = try await StudioComposer().assemble(
            resolved: [(clip(0, filter: .mono), red)], aspect: .portrait9x16,
            overlays: [pip], videoOverlays: [(pip, green)], forPlayback: true)
        let image = try await frame(comp, vc, at: 1)
        let main = pixel(image, 0.5, 0.8)
        XCTAssertLessThan(main.spread, 30, "mono must remove the red: \(main)")
        XCTAssertGreaterThan(main.r, 20, "the frame is not black: \(main)")
        assertColour(pixel(image, 0.75, 0.2), .green, "picture-in-picture")

        // The same project with no filter is red: the assertion above is the filter's doing.
        let (plain, plainVC, _) = try await StudioComposer().assemble(
            resolved: [(clip(0), red)], aspect: .portrait9x16,
            overlays: [pip], videoOverlays: [(pip, green)], forPlayback: true)
        assertColour(pixel(try await frame(plain, plainVC, at: 1), 0.5, 0.8), .red, "unfiltered")
    }

    // MARK: A transition, a filter and a picture-in-picture together

    /// Before prompt 300 a filter or a picture-in-picture dropped the transition.
    func testDissolveMidpointIsABlendWithAFilterAndAPictureInPicture() async throws {
        let red = try video(.red), blue = try video(.blue)
        let green = try video(.green, size: CGSize(width: 160, height: 90), seconds: 3)
        let a = clip(0, filter: .mono), b = clip(1)
        let pip = cornerPiP(end: 3)
        let (comp, vc, _) = try await StudioComposer().assemble(
            resolved: [(a, red), (b, blue)], aspect: .portrait9x16,
            transitions: [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)],
            overlays: [pip], videoOverlays: [(pip, green)], forPlayback: true)
        XCTAssertEqual(comp.duration.seconds, 3, accuracy: 0.02)          // 2 + 2 − 1

        let early = pixel(try await frame(comp, vc, at: 0.5), 0.5, 0.8)
        let mid = pixel(try await frame(comp, vc, at: 1.5), 0.5, 0.8)
        let late = pixel(try await frame(comp, vc, at: 2.5), 0.5, 0.8)
        XCTAssertLessThan(early.spread, 30, "clip A is mono before the dissolve: \(early)")
        assertColour(late, .blue, "clip B after the dissolve")
        XCTAssertGreaterThan(mid.b, early.b + 20, "midpoint has some of B's blue: \(early) \(mid) \(late)")
        XCTAssertLessThan(mid.b, late.b - 10, "midpoint is not all B: \(early) \(mid) \(late)")
        XCTAssertLessThan(mid.r, early.r - 10, "midpoint has less of A: \(early) \(mid) \(late)")
        XCTAssertGreaterThan(mid.r, late.r + 15, "midpoint still has some of A: \(early) \(mid) \(late)")
        for t in [0.5, 1.5, 2.5] {
            assertColour(pixel(try await frame(comp, vc, at: t), 0.75, 0.2), .green, "picture-in-picture at \(t)")
        }
    }

    /// The other kinds, at the middle of the overlap.
    func testSlideZoomAndFadeThroughBlackAtTheMidpoint() async throws {
        let red = try video(.red), blue = try video(.blue)
        func mid(_ kind: StudioTransitionKind) async throws -> CGImage {
            let a = clip(0), b = clip(1)
            let (comp, vc, _) = try await StudioComposer().assemble(
                resolved: [(a, red), (b, blue)], aspect: .portrait9x16,
                transitions: [StudioTransition(afterClipID: a.id, kind: kind, durationSec: 1)], forPlayback: true)
            return try await frame(comp, vc, at: 1.5)
        }
        let left = try await mid(.slideLeft)                      // B pushes A off to the left
        assertColour(pixel(left, 0.25, 0.5), .red, "slide left, left half")
        assertColour(pixel(left, 0.75, 0.5), .blue, "slide left, right half")
        let right = try await mid(.slideRight)
        assertColour(pixel(right, 0.25, 0.5), .blue, "slide right, left half")
        assertColour(pixel(right, 0.75, 0.5), .red, "slide right, right half")
        let zoom = try await mid(.zoomIn)                         // B at 60 % over A
        assertColour(pixel(zoom, 0.5, 0.5), .blue, "zoom, centre")
        assertColour(pixel(zoom, 0.06, 0.06), .red, "zoom, corner")
        let black = pixel(try await mid(.fadeThroughBlack), 0.5, 0.5)
        XCTAssertLessThan(max(black.r, black.g, black.b), 50, "fade through black is black at the middle: \(black)")
    }

    // MARK: Picture-in-picture opacity keyframes

    /// Stored since the keyframe button existed, never rendered before prompt 300.
    func testPictureInPictureOpacityKeyframesChangeItsAlphaOverTime() async throws {
        let red = try video(.red), green = try video(.green, size: CGSize(width: 160, height: 90))
        var pip = cornerPiP()
        pip.opacityKeyframes = [StudioKeyframe(timeSec: 0, value: 0, easing: .linear),
                                StudioKeyframe(timeSec: 2, value: 1, easing: .linear)]
        let (comp, vc, _) = try await StudioComposer().assemble(
            resolved: [(clip(0), red)], aspect: .portrait9x16,
            overlays: [pip], videoOverlays: [(pip, green)], forPlayback: true)
        let p1 = pixel(try await frame(comp, vc, at: 0.2), 0.75, 0.2)
        let p2 = pixel(try await frame(comp, vc, at: 1.0), 0.75, 0.2)
        let p3 = pixel(try await frame(comp, vc, at: 1.8), 0.75, 0.2)
        XCTAssertGreaterThan(p1.r, 150, "mostly the main clip at the start: \(p1)")
        XCTAssertGreaterThan(p3.g, 150, "mostly the picture-in-picture at the end: \(p3)")
        XCTAssertGreaterThan(p2.g, p1.g + 20, "\(p1) \(p2) \(p3)")
        XCTAssertGreaterThan(p3.g, p2.g + 20, "\(p1) \(p2) \(p3)")
        XCTAssertLessThan(p2.r, p1.r - 20, "\(p1) \(p2) \(p3)")
        XCTAssertLessThan(p3.r, p2.r - 20, "\(p1) \(p2) \(p3)")

        // A fixed opacity of 0.5, no keyframes: a steady blend.
        var half = cornerPiP()
        half.opacity = 0.5
        let (hComp, hVC, _) = try await StudioComposer().assemble(
            resolved: [(clip(0), red)], aspect: .portrait9x16,
            overlays: [half], videoOverlays: [(half, green)], forPlayback: true)
        let h = pixel(try await frame(hComp, hVC, at: 1), 0.75, 0.2)
        XCTAssertTrue((40 ..< 235).contains(h.r) && (40 ..< 235).contains(h.g), "half-opaque: \(h)")
    }

    // MARK: Base frame, crop, orientation, background

    func testBaseFramePlacesTheMainVideoInItsCellOverTheBackground() async throws {
        let red = try video(.red)
        let (comp, vc, _) = try await StudioComposer().assemble(
            resolved: [(clip(0, filter: .warm), red)], aspect: .portrait9x16,
            baseFrame: .half, background: .white, forPlayback: true)
        let image = try await frame(comp, vc, at: 1)
        // The cell is the top half (y 0.02…0.52); the 9:16 clip is fitted into it, so it is the
        // middle half of the width.
        assertColour(pixel(image, 0.5, 0.27), .red, "inside the cell")
        assertColour(pixel(image, 0.08, 0.27), .white, "beside the fitted clip")
        assertColour(pixel(image, 0.5, 0.85), .white, "below the cell")
        // No base frame: the clip fills the canvas.
        let (full, fullVC, _) = try await StudioComposer().assemble(
            resolved: [(clip(0), red)], aspect: .portrait9x16, background: .white, forPlayback: true)
        let fullImage = try await frame(full, fullVC, at: 1)
        assertColour(pixel(fullImage, 0.08, 0.27), .red, "full frame, left")
        assertColour(pixel(fullImage, 0.5, 0.85), .red, "full frame, bottom")
    }

    /// Before prompt 300 the filter path ignored the crop and filled the frame with the whole clip.
    func testCropIsKeptWhenTheClipHasAFilter() async throws {
        let split = try video(.red, right: .green)                // left half red, right half green
        var cropped = clip(0, filter: .warm)
        cropped.cropRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let (comp, vc, _) = try await StudioComposer().assemble(
            resolved: [(cropped, split)], aspect: .portrait9x16, forPlayback: true)
        let image = try await frame(comp, vc, at: 1)
        for x in [0.1, 0.5, 0.9] {
            let p = pixel(image, x, 0.5)
            XCTAssertTrue(p.g > 150 && p.r < 110, "only the right (green) half shows at x \(x): \(p)")
        }
        // Uncropped, the left side is red.
        let (whole, wholeVC, _) = try await StudioComposer().assemble(
            resolved: [(clip(0, filter: .warm), split)], aspect: .portrait9x16, forPlayback: true)
        let w = pixel(try await frame(whole, wholeVC, at: 1), 0.1, 0.5)
        XCTAssertTrue(w.r > 150 && w.g < 110, "uncropped left is red: \(w)")
    }

    /// A clip filmed sideways (a landscape buffer with a 90° `preferredTransform`) comes out upright.
    func testSourceOrientationIsApplied() async throws {
        let rotated = try video(.red, right: .green, size: CGSize(width: 320, height: 180),
                                transform: CGAffineTransform(rotationAngle: .pi / 2))
        let (comp, vc, _) = try await StudioComposer().assemble(
            resolved: [(clip(0), rotated)], aspect: .portrait9x16, forPlayback: true)
        XCTAssertEqual(vc?.renderSize, size)
        let image = try await frame(comp, vc, at: 1)
        // Rotated a quarter turn clockwise, the buffer's left half is the top of the picture.
        assertColour(pixel(image, 0.5, 0.2), .red, "top")
        assertColour(pixel(image, 0.5, 0.8), .green, "bottom")
    }

    // MARK: Length

    func testOutputDurationMatchesThePlan() async throws {
        let red = try video(.red), blue = try video(.blue)
        var a = clip(0), b = clip(1), c = clip(2)
        a.trimStart = 0.5                                         // 1.5 s
        b.speed = 2                                               // 1 s
        c.trimEnd = 1.2                                           // 1.2 s
        let transitions = [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 0.5),
                           StudioTransition(afterClipID: c.id, kind: .zoomIn, durationSec: 0.5)]   // last clip: unused
        let expected = StudioGeometry.totalDuration(clips: [a, b, c],
                                                    sourceDurations: [a.id: 2, b.id: 2, c.id: 2],
                                                    transitions: transitions)
        XCTAssertEqual(expected, 3.2, accuracy: 1e-9)
        let (comp, vc, _) = try await StudioComposer().assemble(
            resolved: [(a, red), (b, blue), (c, red)], aspect: .portrait9x16,
            transitions: transitions, forPlayback: true)
        XCTAssertEqual(comp.duration.seconds, expected, accuracy: 0.01)
        let instructions = try XCTUnwrap(vc?.instructions)
        XCTAssertEqual(instructions.first?.timeRange.start, .zero)
        XCTAssertEqual(try XCTUnwrap(instructions.last).timeRange.end.seconds, expected, accuracy: 0.01)
        for (x, y) in zip(instructions, instructions.dropFirst()) {
            XCTAssertEqual(x.timeRange.end, y.timeRange.start, "instructions are back to back")
        }
        // Each instruction asks only for the tracks it draws: one, two during the dissolve.
        XCTAssertEqual(instructions.map { $0.requiredSourceTrackIDs?.count }, [1, 2, 1, 1])
        XCTAssertTrue(vc?.customVideoCompositorClass is StudioCompositor.Type)
        // The last frame is the last clip.
        assertColour(pixel(try await frame(comp, vc, at: 3.0), 0.5, 0.5), .red, "last clip")
        assertColour(pixel(try await frame(comp, vc, at: 1.7), 0.5, 0.5), .blue, "second clip")
    }

    // MARK: Audio

    /// Music is mixed whatever the project has. Before prompt 300 any stored transition — even an
    /// unused one on the last clip — took the transition path, which had no music.
    func testMusicIsMixedWithATransitionAndWithAnUnusedOne() async throws {
        let red = try video(.red), blue = try video(.blue)
        let music = try musicTrack(seconds: 5)
        for kind in [StudioTransitionKind.dissolve, .none] {
            let a = clip(0), b = clip(1)
            // `.none` case: the only stored transition is an unused one after the LAST clip.
            let transitions = kind == .none
                ? [StudioTransition(afterClipID: b.id, kind: .dissolve, durationSec: 1)]
                : [StudioTransition(afterClipID: a.id, kind: kind, durationSec: 1)]
            let (comp, _, mix) = try await StudioComposer().assemble(
                resolved: [(a, red), (b, blue)], aspect: .portrait9x16,
                transitions: transitions, audioTracks: [music], forPlayback: true)
            let audio = try await comp.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1, "the music track (\(kind))")
            XCTAssertEqual(mix?.inputParameters.count, 1)
            let length = try await audio[0].load(.timeRange).duration.seconds
            XCTAssertEqual(length, comp.duration.seconds, accuracy: 0.02, "music is cut to the video")
        }
    }

    /// Each clip's own sound, at its volume, cross-fades over the transition.
    func testClipAudioCrossFadesOverATransition() async throws {
        let tone = try toneFile(seconds: 2)
        let red = try await withSound(try video(.red), tone)
        let blue = try await withSound(try video(.blue), tone)
        var a = clip(0), b = clip(1)
        a.volume = 0.8
        b.volume = 0.4
        let (comp, _, mix) = try await StudioComposer().assemble(
            resolved: [(a, red), (b, blue)], aspect: .portrait9x16,
            transitions: [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)], forPlayback: true)
        let audio = try await comp.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 2, "one audio track per overlapping clip")
        let params = try XCTUnwrap(mix?.inputParameters)
        XCTAssertEqual(params.count, 2)
        var ramps: [(start: Float, end: Float)] = []
        for p in params {
            var s: Float = -1, e: Float = -1
            var range = CMTimeRange.zero
            XCTAssertTrue(p.getVolumeRamp(for: CMTime(seconds: 1.5, preferredTimescale: 600),
                                          startVolume: &s, endVolume: &e, timeRange: &range))
            XCTAssertEqual(range.start.seconds, 1, accuracy: 0.01)
            XCTAssertEqual(range.end.seconds, 2, accuracy: 0.01)
            ramps.append((s, e))
        }
        ramps.sort { $0.start > $1.start }
        XCTAssertEqual(ramps[0].start, 0.8, accuracy: 0.001)      // A falls to silence
        XCTAssertEqual(ramps[0].end, 0, accuracy: 0.001)
        XCTAssertEqual(ramps[1].start, 0, accuracy: 0.001)        // B rises to its volume
        XCTAssertEqual(ramps[1].end, 0.4, accuracy: 0.001)

        // Cuts with full volume need no mix at all.
        let (_, _, none) = try await StudioComposer().assemble(
            resolved: [(clip(0), red), (clip(1), blue)], aspect: .portrait9x16, forPlayback: true)
        XCTAssertNil(none)
    }

    // MARK: Export (a real file)

    /// A transition + a filter + a picture-in-picture + music + a text overlay, exported. The file
    /// has the plan's length, the blended midpoint, the text drawn by the Core Animation tool over
    /// the custom compositor's frames, and an audio track that is not silent.
    func testExportedFileHasTheBlendTheTextAndTheMusic() async throws {
        let red = try video(.red), blue = try video(.blue)
        let green = try video(.green, size: CGSize(width: 160, height: 90), seconds: 3)
        let music = try musicTrack(seconds: 5)
        let a = clip(0, filter: .vivid), b = clip(1)
        let pip = cornerPiP(end: 3)
        // A text with a green highlight chip behind it. The chip is what is checked: the
        // simulator's offline Core Animation renderer does not draw layers that need a bitmap
        // (the glyphs), only solid ones, so the glyphs are a device check.
        let text = OverlayItem(kind: .text, content: "SNAPPET", startSec: 0, endSec: 3,
                               position: CGPoint(x: 0.5, y: 0.6), colorHex: "#FFFFFF", highlightHex: "#00FF00")
        let (comp, vc, mix) = try await StudioComposer().assemble(
            resolved: [(a, red), (b, blue)], aspect: .portrait9x16,
            transitions: [StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)],
            overlays: [pip, text], audioTracks: [music], videoOverlays: [(pip, green)])
        XCTAssertNotNil(vc?.animationTool, "the export composition keeps the overlay tool")

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("studio300-\(UUID().uuidString).mp4")
        scratch.append(out)
        let session = try XCTUnwrap(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality))
        session.videoComposition = vc
        session.audioMix = mix
        try await session.export(to: out, as: .mp4)

        let file = AVURLAsset(url: out)
        let fileSeconds = try await file.load(.duration).seconds
        XCTAssertEqual(fileSeconds, 3, accuracy: 0.1)
        let midFrame = try await frame(file, nil, at: 1.5)
        let mid = pixel(midFrame, 0.5, 0.9)
        XCTAssertTrue(mid.r > 40 && mid.b > 40, "the dissolve midpoint is a blend in the file: \(mid)")
        assertColour(pixel(midFrame, 0.75, 0.2), .green, "picture-in-picture in the file")
        assertColour(pixel(try await frame(file, nil, at: 0.3), 0.5, 0.9), .red, "clip A in the file")
        // The text's highlight chip is green on a red clip: its band has a high green value, and
        // the clip outside the band does not.
        let early = try await frame(file, nil, at: 0.3)
        var brightest = 0
        for x in stride(from: 0.3, through: 0.7, by: 0.02) {
            for y in stride(from: 0.55, through: 0.65, by: 0.01) { brightest = max(brightest, pixel(early, x, y, radius: 0).g) }
        }
        XCTAssertGreaterThan(brightest, 100, "the overlay tool drew the text's chip over the compositor's frames")
        XCTAssertLessThan(pixel(early, 0.5, 0.9).g, 60)

        let audio = try await file.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "the file has an audio track")
        let peak = try await peakAmplitude(of: file)
        XCTAssertGreaterThan(peak, 1000, "the music is audible (16-bit peak)")
    }

    // MARK: Compositor housekeeping

    func testCancelWithNothingPendingReturns() {
        let compositor = StudioCompositor()
        compositor.cancelAllPendingVideoCompositionRequests()
        compositor.cancelAllPendingVideoCompositionRequests()
        XCTAssertNotNil(compositor.sourcePixelBufferAttributes?[kCVPixelBufferPixelFormatTypeKey as String])
        XCTAssertNotNil(compositor.requiredPixelBufferAttributesForRenderContext[kCVPixelBufferPixelFormatTypeKey as String])
    }

    // MARK: View model — a picture-in-picture opacity drag rebuilds the preview once

    @MainActor
    func testPictureInPictureOpacityDragRebuildsThePreviewOnceAtTheEnd() async throws {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let project = StudioProject(sessionID: UUID(), title: "PiP")
        project.clips = [TimelineClip(sessionMediaID: UUID(), localIdentifier: "A", isPhoto: false,
                                      order: 0, trimStart: 0, trimEnd: nil)]
        container.mainContext.insert(project)
        let vm = StudioEditorViewModel(project: project, context: container.mainContext)
        vm.addPiP(localIdentifier: "B")
        vm.addText("Hello")
        let pipID = try XCTUnwrap(vm.overlays.first { $0.kind == .video }?.id)
        let textID = try XCTUnwrap(vm.overlays.first { $0.kind == .text }?.id)
        let counter = RebuildCounter()
        counter.watch(vm)
        try await settle(vm)
        let base = counter.count

        // A drag: the value follows every tick, the preview is not rebuilt until the finger lifts.
        vm.beginGesture()
        for tick in 1...20 { vm.setOverlayOpacity(pipID, 1 - Double(tick) * 0.02) }
        try await settle(vm)
        XCTAssertEqual(try XCTUnwrap(vm.overlays.first { $0.id == pipID }).opacity, 0.6, accuracy: 1e-9)
        XCTAssertEqual(counter.count, base, "no rebuild per tick")
        vm.endGesture()
        try await settle(vm)
        XCTAssertEqual(counter.count, base + 1, "one rebuild when the drag ends")
        vm.undoEdit()                                             // one step (and Undo's own rebuild)
        try await settle(vm)
        XCTAssertEqual(vm.overlays.first { $0.id == pipID }?.opacity, 1)
        let afterUndo = counter.count

        // A drag that ends where it began: nothing to rebuild.
        vm.beginGesture()
        vm.setOverlayOpacity(pipID, 0.5)
        vm.setOverlayOpacity(pipID, 1)
        vm.endGesture()
        try await settle(vm)
        XCTAssertEqual(counter.count, afterUndo)

        // Outside a drag (VoiceOver adjust) it is a plain edit, which rebuilds.
        vm.setOverlayOpacity(pipID, 0.7)
        try await settle(vm)
        XCTAssertEqual(counter.count, afterUndo + 1)

        // A text overlay is drawn by the canvas: no rebuild, in a drag or outside one.
        vm.beginGesture()
        for tick in 1...5 { vm.setOverlayOpacity(textID, 1 - Double(tick) * 0.1) }
        vm.endGesture()
        vm.setOverlayOpacity(textID, 0.9)
        try await settle(vm)
        XCTAssertEqual(counter.count, afterUndo + 1)
        withExtendedLifetime(container) {}
    }

    /// Counts preview rebuilds: `isBuildingPreview` is set at the start of each one.
    @MainActor
    private final class RebuildCounter {
        var count = 0
        func watch(_ vm: StudioEditorViewModel) {
            withObservationTracking { _ = vm.isBuildingPreview } onChange: { [weak self] in
                Task { @MainActor in
                    if vm.isBuildingPreview { self?.count += 1 }
                    self?.watch(vm)
                }
            }
        }
    }

    /// Wait until no preview rebuild is running or about to start.
    @MainActor
    private func settle(_ vm: StudioEditorViewModel) async throws {
        var quiet = 0
        for _ in 0 ..< 200 where quiet < 4 {
            try await Task.sleep(for: .milliseconds(25))
            quiet = vm.isBuildingPreview ? 0 : quiet + 1
        }
    }

    // MARK: - Helpers: project pieces

    private func clip(_ order: Int, filter: StudioFilter = .none) -> TimelineClip {
        TimelineClip(sessionMediaID: nil, localIdentifier: "synthetic-\(order)", isPhoto: false,
                     order: order, filter: filter)
    }

    /// A picture-in-picture in the top-right corner; a 160×90 source fits its frame as a strip
    /// through the frame's centre (0.75, 0.2).
    private func cornerPiP(end: Double = 2) -> OverlayItem {
        OverlayItem(kind: .video, content: "pip", startSec: 0, endSec: end,
                    position: CGPoint(x: 0.75, y: 0.2), normalizedWidth: 0.4, normalizedHeight: 0.3)
    }

    // MARK: - Helpers: reading frames and audio

    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var spread: Int { max(r, g, b) - min(r, g, b) }
        var description: String { "(\(r), \(g), \(b))" }
    }

    private enum Colour { case red, green, blue, white }

    private func assertColour(_ p: RGB, _ colour: Colour, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let hi = 170, lo = 90
        let ok: Bool
        switch colour {
        case .red:   ok = p.r > hi && p.g < lo && p.b < lo
        case .green: ok = p.g > hi && p.r < lo && p.b < lo
        case .blue:  ok = p.b > hi && p.r < lo && p.g < lo
        case .white: ok = p.r > hi && p.g > hi && p.b > hi
        }
        XCTAssertTrue(ok, "\(what): expected \(colour), got \(p)", file: file, line: line)
    }

    private func frame(_ asset: AVAsset, _ videoComposition: AVVideoComposition?, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The colour at a normalized point (top-left origin), averaged over a small square.
    private func pixel(_ image: CGImage, _ x: Double, _ y: Double, radius: Int = 2) -> RGB {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let cx = min(w - 1, max(0, Int(x * Double(w)))), cy = min(h - 1, max(0, Int(y * Double(h))))
        var r = 0, g = 0, b = 0, n = 0
        for py in max(0, cy - radius) ... min(h - 1, cy + radius) {
            for px in max(0, cx - radius) ... min(w - 1, cx + radius) {
                let i = (py * w + px) * 4
                r += Int(data[i]); g += Int(data[i + 1]); b += Int(data[i + 2]); n += 1
            }
        }
        return RGB(r: r / n, g: g / n, b: b / n)
    }

    /// The loudest 16-bit sample in the asset's first audio track.
    private func peakAmplitude(of asset: AVAsset) async throws -> Int {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var peak = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            bytes.withUnsafeBytes { raw in
                for s in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int(s))) }
            }
        }
        return peak
    }

    // MARK: - Helpers: synthetic sources

    /// BGRA bytes.
    private struct Fill { let b: UInt8, g: UInt8, r: UInt8
        static let red = Fill(b: 0, g: 0, r: 255), green = Fill(b: 0, g: 255, r: 0), blue = Fill(b: 255, g: 0, r: 0)
    }

    /// A solid-colour H.264 clip (or left half `left`, right half `right`), tagged BT.709, with an
    /// optional `preferredTransform`. Written synchronously (push + poll).
    private func video(_ left: Fill, right: Fill? = nil, size: CGSize? = nil, seconds: Double = 2,
                       transform: CGAffineTransform = .identity) throws -> AVURLAsset {
        let size = size ?? self.size
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("studio300-src-\(UUID().uuidString).mp4")
        scratch.append(url)
        let w = Int(size.width), h = Int(size.height), fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(input) else { throw Failure.writerSetup }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writerSetup }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        var index = 0
        while index < frames {
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { usleep(1_000); continue }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.pixelBuffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                for y in 0 ..< h {
                    for x in 0 ..< w {
                        let c = (x >= w / 2 ? right : nil) ?? left
                        let i = y * rowBytes + x * 4
                        pixels[i] = c.b; pixels[i + 1] = c.g; pixels[i + 2] = c.r; pixels[i + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
            index += 1
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw Failure.writerFinish }
        return AVURLAsset(url: url)
    }

    /// A 440 Hz tone as a WAV file at `url`.
    private func writeTone(to url: URL, seconds: Double) throws {
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let count = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0 ..< Int(count) { samples[i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / rate)) }
        try file.write(from: buffer)
    }

    private func toneFile(seconds: Double) throws -> AVURLAsset {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("studio300-tone-\(UUID().uuidString).wav")
        scratch.append(url)
        try writeTone(to: url, seconds: seconds)
        return AVURLAsset(url: url)
    }

    /// An added-music track whose file is in the app's Documents, where the composer looks.
    private func musicTrack(seconds: Double) throws -> AudioTrack {
        let name = "studio300-music-\(UUID().uuidString).wav"
        let docs = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let url = docs.appendingPathComponent(name)
        scratch.append(url)
        try writeTone(to: url, seconds: seconds)
        return AudioTrack(kind: .music, sourceRef: name, startSec: 0, volume: 1)
    }

    /// The video with the tone as its own sound (a composition is an asset like any other).
    private func withSound(_ video: AVURLAsset, _ tone: AVURLAsset) async throws -> AVAsset {
        let movie = AVMutableComposition()
        let videoTracks = try await video.loadTracks(withMediaType: .video)
        let toneTracks = try await tone.loadTracks(withMediaType: .audio)
        let v = try XCTUnwrap(videoTracks.first), a = try XCTUnwrap(toneTracks.first)
        let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
        try movie.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: v, at: .zero)
        try movie.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: a, at: .zero)
        return movie
    }

    private enum Failure: Error { case writerSetup, pixelBuffer, writerFinish }
}
