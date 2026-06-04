import XCTest
import AVFoundation
@testable import Snappet

/// **S0 device-profiling spike** (live-workout-studio, Track S): measure the real on-device cost of
/// a multi-clip studio export, so we have a GO / scope-trim verdict *before* building the heavier
/// S2+ pixel compositor (custom `AVVideoCompositing` filters/transitions/keyframes). It synthesizes
/// a video on-device (no Photos needed) and exports a K-clip composition through the
/// `StudioComposer.assemble` seam, logging build + export wall-clock + a memory delta as
/// `S0-PROFILE …` (grep the test log). **Export timing is only meaningful on real hardware**, so the
/// body is skipped on the simulator.
final class StudioComposerProfilingTests: XCTestCase {

    func testProfileMultiClipExport() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Studio export profiling is device-only (S0).")
        #else
        let size = CGSize(width: 1080, height: 1920)          // portrait 1080p
        let clipSeconds = 4.0
        let clipCount = 4                                     // ~16 s output across 4 clips

        let srcURL = FileManager.default.temporaryDirectory.appendingPathComponent("s0-src-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: srcURL) }
        try makeSyntheticVideo(seconds: clipSeconds, size: size, to: srcURL)
        let asset = AVURLAsset(url: srcURL)

        // K clips, all backed by the synthetic asset (resolved directly — no PHAsset).
        var resolved: [(clip: TimelineClip, asset: AVAsset)] = []
        for i in 0..<clipCount {
            resolved.append((TimelineClip(sessionMediaID: nil, localIdentifier: "synthetic",
                                          isPhoto: false, order: i), asset))
        }

        let composer = StudioComposer()
        let (composition, videoComposition) = try await composer.assemble(resolved: resolved, aspect: .portrait9x16)

        // BASELINE (works on-device): a multi-clip **passthrough stitch** must export. Measured on
        // MrRobot (iPhone 13 Pro Max): ~0.08–0.10 s to remux a 16 s / 4-clip / 1080×1920 timeline —
        // the stitch is effectively free.
        let stitch = await export(composition, videoComposition: nil,
                                  preset: AVAssetExportPresetPassthrough, tag: "stitch")
        XCTAssertTrue(stitch.ok, "multi-clip passthrough stitch should export on-device (status \(stitch.status))")
        XCTAssertLessThan(stitch.sec, 30, "a 16 s stitch should remux quickly on-device")

        // TRANSFORM/EFFECTS path: applying our `AVMutableVideoComposition` (per-clip transform/crop,
        // and the surface S2+ filters/transitions/keyframes build on) must export on-device. This used
        // to fail -11838 until two fixes — one layer instruction per track (not per clip) + a LAZY
        // audio track (an empty audio track from an audio-less source was the actual culprit). Measured
        // on MrRobot: ~0.2× realtime (a 4 s clip ≈ 0.76 s). See RESULTS-S0.
        let transform = await export(composition, videoComposition: videoComposition,
                                     preset: AVAssetExportPresetHighestQuality, tag: "transform")
        XCTAssertTrue(transform.ok, "videoComposition (transform) export should succeed on-device (status \(transform.status), \(transform.err ?? ""))")
        XCTAssertLessThan(transform.sec, 60, "a 16 s transform export should finish well under 60 s on-device")

        // S2: a FILTERED export (CIFilter compositor path) must also work on-device.
        var filteredClips: [(clip: TimelineClip, asset: AVAsset)] = []
        for i in 0..<clipCount {
            filteredClips.append((TimelineClip(sessionMediaID: nil, localIdentifier: "synthetic",
                                               isPhoto: false, order: i, filter: .vivid), asset))
        }
        let (fComp, fVC) = try await composer.assemble(resolved: filteredClips, aspect: .portrait9x16)
        let filtered = await export(fComp, videoComposition: fVC,
                                    preset: AVAssetExportPresetHighestQuality, tag: "filtered")
        // Measured on MrRobot: a 16 s / 4-clip filtered (vivid) export ~3.0 s, vs ~2.6 s transform-only
        // — per-frame Core Image filtering adds ~15%, still ~0.2x realtime.
        XCTAssertTrue(filtered.ok, "filtered (CIFilter) export should succeed on-device (status \(filtered.status), \(filtered.err ?? ""))")
        XCTAssertLessThan(filtered.sec, 90, "a 16 s filtered export should finish well under 90 s on-device")

        // S3: a dissolve-transition export must work on-device (two-track opacity-ramp path).
        var transClips: [(clip: TimelineClip, asset: AVAsset)] = []
        var transitions: [StudioTransition] = []
        var prevID: UUID?
        for i in 0..<clipCount {
            let c = TimelineClip(sessionMediaID: nil, localIdentifier: "synthetic", isPhoto: false, order: i)
            transClips.append((c, asset))
            if let p = prevID { transitions.append(StudioTransition(afterClipID: p, kind: .dissolve, durationSec: 0.5)) }
            prevID = c.id
        }
        let (tComp, tVC) = try await composer.assemble(resolved: transClips, aspect: .portrait9x16, transitions: transitions)
        let dissolve = await export(tComp, videoComposition: tVC, preset: AVAssetExportPresetHighestQuality, tag: "dissolve")
        // Measured on MrRobot: a 16 s / 4-clip / 3-dissolve export ~2.8 s. (Export-success verifies the
        // two-track composition is valid + renders; the crossfade's *look* needs a visual check.)
        XCTAssertTrue(dissolve.ok, "dissolve-transition export should succeed on-device (status \(dissolve.status), \(dissolve.err ?? ""))")
        XCTAssertLessThan(dissolve.sec, 90, "a 16 s dissolve export should finish well under 90 s on-device")

        // S4: an export with a text overlay must work on-device (Core Animation overlay-tool path).
        var overlayClips: [(clip: TimelineClip, asset: AVAsset)] = []
        for i in 0..<clipCount {
            overlayClips.append((TimelineClip(sessionMediaID: nil, localIdentifier: "synthetic",
                                              isPhoto: false, order: i), asset))
        }
        let overlays = [OverlayItem(kind: .text, content: "REP PR", startSec: 0, endSec: 3)]
        let (oComp, oVC) = try await composer.assemble(resolved: overlayClips, aspect: .portrait9x16, overlays: overlays)
        let overlaid = await export(oComp, videoComposition: oVC, preset: AVAssetExportPresetHighestQuality, tag: "overlay")
        // Measured on MrRobot: a 16 s / 4-clip export with a text overlay ~4.9 s (the Core Animation
        // tool costs more than a CIFilter, still well under realtime). Export-success proves the
        // composition is valid + renders; the overlay's *look* needs a visual check.
        XCTAssertTrue(overlaid.ok, "text-overlay export should succeed on-device (status \(overlaid.status), \(overlaid.err ?? ""))")
        XCTAssertLessThan(overlaid.sec, 120, "a 16 s overlay export should finish well under 2 min on-device")

        // Slide transition (two-track transform-ramp path).
        var slideClips: [(clip: TimelineClip, asset: AVAsset)] = []
        var slides: [StudioTransition] = []
        var prevSlideID: UUID?
        for i in 0..<clipCount {
            let c = TimelineClip(sessionMediaID: nil, localIdentifier: "synthetic", isPhoto: false, order: i)
            slideClips.append((c, asset))
            if let p = prevSlideID { slides.append(StudioTransition(afterClipID: p, kind: .slideLeft, durationSec: 0.5)) }
            prevSlideID = c.id
        }
        let (slComp, slVC) = try await composer.assemble(resolved: slideClips, aspect: .portrait9x16, transitions: slides)
        let slide = await export(slComp, videoComposition: slVC, preset: AVAssetExportPresetHighestQuality, tag: "slide")
        XCTAssertTrue(slide.ok, "slide-transition export should succeed on-device (status \(slide.status), \(slide.err ?? ""))")

        // Filter + sticker overlay combined (CIFilter handler + Core Animation overlay tool).
        var fsClips: [(clip: TimelineClip, asset: AVAsset)] = []
        for i in 0..<clipCount {
            fsClips.append((TimelineClip(sessionMediaID: nil, localIdentifier: "synthetic",
                                         isPhoto: false, order: i, filter: .warm), asset))
        }
        let sticker = [OverlayItem(kind: .sticker, content: "star.fill", startSec: 0, endSec: 4)]
        let (fsComp, fsVC) = try await composer.assemble(resolved: fsClips, aspect: .portrait9x16, overlays: sticker)
        let filterSticker = await export(fsComp, videoComposition: fsVC, preset: AVAssetExportPresetHighestQuality, tag: "filter-sticker")
        XCTAssertTrue(filterSticker.ok, "filter+sticker export should succeed on-device (status \(filterSticker.status), \(filterSticker.err ?? ""))")
        #endif
    }

    /// REGRESSION: the studio PREVIEW assigns the composition to an `AVPlayerItem`. A videoComposition
    /// that uses `AVVideoCompositionCoreAnimationTool` (our overlay tool) is **offline-render-only** —
    /// `AVPlayerItem.setVideoComposition` raises an NSException ("…cannot be used with AVPlayerItem…"),
    /// which Swift can't catch → it aborted the app on opening the studio. So the playback composition
    /// (`forPlayback: true`) must OMIT the tool, while export keeps it (overlays render into the file).
    /// Builds an overlay + filtered project (the real crashing shape) and proves the playback path is
    /// accepted by AVPlayerItem — if the tool ever leaks back into playback, this test crashes.
    @MainActor
    func testPlaybackCompositionOmitsCoreAnimationToolAndExportKeepsIt() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Device-only (Photos/AV).")
        #else
        let srcURL = FileManager.default.temporaryDirectory.appendingPathComponent("prev-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: srcURL) }
        try makeSyntheticVideo(seconds: 3, size: CGSize(width: 1080, height: 1920), to: srcURL)
        let asset = AVURLAsset(url: srcURL)
        let overlays = [OverlayItem(kind: .text, content: "REP PR", startSec: 0, endSec: 3)]
        let composer = StudioComposer()
        // The crashing shape: clips WITH a colour filter AND a text overlay. `assemble` consumes its
        // `resolved` arg (Swift-6 `sending`), so build a fresh inline array for each call.

        // Export composition KEEPS the Core Animation tool (so overlays render into the file).
        var exportClips: [(clip: TimelineClip, asset: AVAsset)] = [
            (TimelineClip(sessionMediaID: nil, localIdentifier: "a", isPhoto: false, order: 0, filter: .vivid), asset),
            (TimelineClip(sessionMediaID: nil, localIdentifier: "b", isPhoto: false, order: 1, filter: .fade), asset)]
        let (_, exportVC) = try await composer.assemble(resolved: exportClips, aspect: .portrait9x16,
                                                        overlays: overlays, forPlayback: false)
        XCTAssertNotNil(exportVC?.animationTool, "export composition should keep the overlay tool")

        // Playback composition OMITS it, and AVPlayerItem must accept it without raising.
        var playClips: [(clip: TimelineClip, asset: AVAsset)] = [
            (TimelineClip(sessionMediaID: nil, localIdentifier: "a", isPhoto: false, order: 0, filter: .vivid), asset),
            (TimelineClip(sessionMediaID: nil, localIdentifier: "b", isPhoto: false, order: 1, filter: .fade), asset)]
        let (playComp, playVC) = try await composer.assemble(resolved: playClips, aspect: .portrait9x16,
                                                            overlays: overlays, forPlayback: true)
        XCTAssertNil(playVC?.animationTool, "playback composition must omit the offline-only overlay tool")
        let item = AVPlayerItem(asset: playComp)
        item.videoComposition = playVC   // would raise NSException (→ SIGABRT) if the tool leaked in
        _ = AVPlayer(playerItem: item)
        #endif
    }

    /// Export `composition` (optionally with `videoComposition`) to a throwaway file; returns the
    /// wall-clock seconds, whether it completed, the raw status, and any error string.
    private func export(_ composition: AVMutableComposition, videoComposition: AVVideoComposition?,
                        preset: String, tag: String) async -> (sec: Double, ok: Bool, status: Int, err: String?) {
        guard let s = AVAssetExportSession(asset: composition, presetName: preset) else {
            return (0, false, -1, "no session for preset \(preset)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s0-\(tag)-\(UUID()).mp4")
        s.outputURL = url
        s.outputFileType = .mp4
        s.videoComposition = videoComposition
        let start = Date()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            s.exportAsynchronously { cont.resume() }
        }
        let sec = Date().timeIntervalSince(start)
        try? FileManager.default.removeItem(at: url)
        return (sec, s.status == .completed, s.status.rawValue, s.error.map { String(describing: $0) })
    }

    // MARK: - Synthetic source video (on-device, no Photos)

    /// Write `seconds` of an animated solid-gray 1080p H.264 clip to `url` using `AVAssetWriter`,
    /// synchronously (push + poll, so there's no escaping non-Sendable capture under Swift 6).
    private func makeSyntheticVideo(seconds: Double, size: CGSize, fps: Int32 = 30, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            // Tag standard color metadata, else a videoComposition export rejects the source (-11838).
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)])
        guard writer.canAdd(input) else { throw Failure.writerSetup }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writerSetup }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        var frame = 0
        while frame < frames {
            guard input.isReadyForMoreMediaData else { usleep(1_000); continue }
            guard let pool = adaptor.pixelBufferPool else { usleep(1_000); continue }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw Failure.pixelBuffer }
            fill(pb, frame: frame, height: Int(size.height))
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
            frame += 1
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw Failure.writerFinish }
    }

    /// Fill a buffer with a flat gray whose value walks per frame (gives the encoder real motion).
    private func fill(_ pb: CVPixelBuffer, frame: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, Int32((frame * 7) % 240) + 8, CVPixelBufferGetBytesPerRow(pb) * height)
        }
    }

    private enum Failure: Error { case writerSetup, pixelBuffer, writerFinish }
}
