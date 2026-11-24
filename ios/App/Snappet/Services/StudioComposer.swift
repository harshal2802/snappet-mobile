import Foundation
import AVFoundation
import Photos
import CoreGraphics
import CoreImage
import UIKit

/// Turns a `StudioProjectSnapshot` (multi-clip timeline) into a playable/exportable AVFoundation
/// composition — the Studio's one render engine. `makeComposition(for:)` builds the
/// `(AVMutableComposition, AVVideoComposition?, AVAudioMix?)` used for **both** the preview
/// (`AVPlayer`) and the export.
///
/// One path since prompt 300: the pure `StudioRenderPlan` says what is on screen when, this class
/// resolves the Photos assets and puts them on composition tracks, and `StudioCompositor` (a custom
/// `AVVideoCompositing`) draws every frame with Core Image — crop, base frame, filter, adjust,
/// transitions, picture-in-picture and background together. Text, climb tags and the HR tile are
/// drawn over that by the Core Animation tool (`StudioOverlays`), in the export only.
///
/// Photos-bound (`PHAsset → AVAsset`), so `makeComposition`/`export` need a device; `assemble`
/// takes already-resolved assets and is rendered on the simulator by `StudioCompositorRenderTests`.
/// Not rendered: photo clips (left out, as before).
final class StudioComposer: Sendable {

    private struct Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    /// Memoizes `PHAsset → AVAsset` resolution for the lifetime of one editor session. Resolving an
    /// asset goes through `PHImageManager.requestAVAsset` (slow + async); without caching, EVERY
    /// preview rebuild (one per edit) re-resolves every clip, which is the visible "flicker"/reload
    /// when nudging a PiP. The cache makes a rebuild after the first load near-instant. `AVAsset` isn't
    /// `Sendable`, so it's wrapped in the `@unchecked Sendable` `Box` to cross the actor boundary.
    private actor AssetCache {
        private var store: [String: Box<AVAsset>] = [:]
        func get(_ id: String) -> Box<AVAsset>? { store[id] }
        func set(_ id: String, _ box: Box<AVAsset>) { store[id] = box }
        func remove(_ ids: Set<String>) { for id in ids { store[id] = nil } }
    }
    private let assetCache = AssetCache()

    /// Forget the opened assets for these Photos identifiers, so the next preview or export opens
    /// them again. A "Save to original" bake changes an asset's video under the SAME identifier;
    /// without this the Studio kept showing the video from before the bake until it was reopened
    /// (prompt 303).
    func forget(localIdentifiers: Set<String>) async {
        await assetCache.remove(localIdentifiers)
    }

    enum ComposerError: LocalizedError {
        case noRenderableClips, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noRenderableClips: return "This project has no video clips to render yet."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    private let timescale: CMTimeScale = 600

    /// Build the multi-clip composition. `sourceDurations` (clip id → seconds) lets the caller pass
    /// already-resolved durations; any missing one is loaded from the asset here.
    ///
    /// `forPlayback`: when **true**, the returned videoComposition omits the Core Animation overlay
    /// tool (`AVVideoCompositionCoreAnimationTool`), which is **offline-render-only** —
    /// `AVPlayerItem.setVideoComposition` raises an NSException for any composition that uses it. So
    /// the live preview gets a tool-free composition (text, tags and the HR tile are drawn by the
    /// SwiftUI canvas there; everything the compositor draws shows), while **export** (default
    /// `false`) keeps the tool so they render into the file.
    func makeComposition(for snapshot: StudioProjectSnapshot,
                         sourceDurations: [UUID: Double] = [:],
                         hrSamples: [HRPoint] = [],
                         hrTile: ResolvedHRTile? = nil,
                         clipHRByID: [UUID: StudioClipHRContent] = [:],
                         forPlayback: Bool = false) async throws
        -> sending (AVMutableComposition, AVVideoComposition?, AVAudioMix?) {

        // Video clips only; photo clips are not rendered.
        let videoClips = StudioGeometry.ordered(snapshot.clips).filter { !$0.isPhoto }
        guard !videoClips.isEmpty else { throw ComposerError.noRenderableClips }
        // Resolve each clip's PHAsset → AVAsset (the device-only / Photos-bound step), then assemble.
        var resolved: [(clip: TimelineClip, asset: AVAsset)] = []
        for clip in videoClips {
            if let asset = await avAsset(forLocalIdentifier: clip.localIdentifier) {
                resolved.append((clip, asset))
            }
        }
        // Resolve picture-in-picture overlay sources (a second video, composited on top).
        var videoOverlays: [(overlay: OverlayItem, asset: AVAsset)] = []
        for ov in snapshot.overlays where ov.kind == .video {
            if let asset = await avAsset(forLocalIdentifier: ov.content) { videoOverlays.append((ov, asset)) }
        }
        return try await assemble(resolved: resolved, aspect: snapshot.aspect,
                                  sourceDurations: sourceDurations, transitions: snapshot.transitions,
                                  overlays: snapshot.overlays, audioTracks: snapshot.audioTracks,
                                  videoOverlays: videoOverlays, hrSamples: hrSamples,
                                  hrTile: hrTile, clipHRByID: clipHRByID,
                                  baseFrame: snapshot.baseFrame,
                                  background: StudioBackground(rawValue: snapshot.backgroundRaw) ?? .black,
                                  forPlayback: forPlayback)
    }

    /// Build the multi-clip composition from **already-resolved** `(clip, AVAsset)` pairs — the
    /// testable seam, decoupled from Photos (the render tests and the S0 profiling spike drive it
    /// with synthetic videos).
    ///
    /// There is ONE path (prompt 300). `StudioRenderPlan` lays the clips out with
    /// `StudioGeometry.timeline` and lists what is on screen in each stretch of time; this function
    /// puts the sources on composition tracks where the plan says, and hands each stretch to
    /// `StudioCompositor` as a `StudioCompositionInstruction`. Crop, base frame, filter, adjust,
    /// transitions, picture-in-picture and the background are all drawn there, together. Audio is
    /// every clip's own sound at its volume, cross-faded over a transition, plus the added music —
    /// in every case.
    ///
    /// A clip whose asset has no video track or no length is left out (as before), and the plan is
    /// made from the clips that are left, so a transition into a missing clip does not apply.
    func assemble(resolved: sending [(clip: TimelineClip, asset: AVAsset)],
                  aspect: ClipEditGeometry.OutputAspect,
                  sourceDurations: [UUID: Double] = [:],
                  transitions: [StudioTransition] = [],
                  overlays: [OverlayItem] = [],
                  audioTracks: [AudioTrack] = [],
                  videoOverlays: sending [(overlay: OverlayItem, asset: AVAsset)] = [],
                  hrSamples: [HRPoint] = [],
                  hrTile: ResolvedHRTile? = nil,
                  clipHRByID: [UUID: StudioClipHRContent] = [:],
                  baseFrame: StudioFrameRect? = nil,
                  background: StudioBackground = .black,
                  forPlayback: Bool = false) async throws
        -> sending (AVMutableComposition, AVVideoComposition?, AVAudioMix?) {
        guard !resolved.isEmpty else { throw ComposerError.noRenderableClips }

        // 1. Read what the plan needs from each source.
        struct MainInput { let video: AVAssetTrack; let audio: AVAssetTrack?; let orient: CGAffineTransform }
        var inputs: [UUID: MainInput] = [:]
        var clips: [TimelineClip] = []
        var durations: [UUID: Double] = [:]
        var orientedSizes: [UUID: CGSize] = [:]
        var renderSize: CGSize?
        for (clip, source) in resolved where inputs[clip.id] == nil {
            guard let video = try? await source.loadTracks(withMediaType: .video).first else { continue }
            var duration = sourceDurations[clip.id] ?? 0
            if duration <= 0 { duration = (try? await source.load(.duration).seconds) ?? 0 }
            guard duration > 0 else { continue }
            let o = await orientation(of: video)
            if renderSize == nil { renderSize = ClipEditGeometry.renderSize(for: aspect, sourceSize: o.size) }
            let audio = try? await source.loadTracks(withMediaType: .audio).first
            inputs[clip.id] = MainInput(video: video, audio: audio, orient: o.orient)
            clips.append(clip)
            durations[clip.id] = duration
            orientedSizes[clip.id] = o.size
        }
        guard let canvas = renderSize else { throw ComposerError.noRenderableClips }

        struct PiPInput { let video: AVAssetTrack; let orient: CGAffineTransform }
        var pipInputs: [UUID: PiPInput] = [:]
        var pipSources: [UUID: StudioRenderPlan.PiPSource] = [:]
        for (overlay, source) in videoOverlays where pipInputs[overlay.id] == nil {
            guard let video = try? await source.loadTracks(withMediaType: .video).first else { continue }
            let o = await orientation(of: video)
            let duration = (try? await source.load(.duration).seconds) ?? 0
            pipInputs[overlay.id] = PiPInput(video: video, orient: o.orient)
            pipSources[overlay.id] = StudioRenderPlan.PiPSource(orientedSize: o.size, durationSec: duration)
        }

        // 2. The plan: placement, segments, layers. Everything below only carries it out.
        let plan = StudioRenderPlan.make(clips: clips, sourceDurations: durations,
                                         orientedSizes: orientedSizes, transitions: transitions,
                                         overlays: overlays, pipSources: pipSources, canvas: canvas,
                                         baseFrame: baseFrame, background: background)
        guard plan.totalDuration > 0, !plan.clips.isEmpty else { throw ComposerError.noRenderableClips }

        // 3. Main clips onto their tracks. Audio tracks are created only when a clip has sound: an
        // empty audio track makes a videoComposition export fail -11838 on a device (S0 spike).
        let composition = AVMutableComposition()
        var videoTracks: [Int: AVMutableCompositionTrack] = [:], videoEnds: [Int: CMTime] = [:]
        var soundTracks: [Int: AVMutableCompositionTrack] = [:], soundEnds: [Int: CMTime] = [:]
        var soundParams: [Int: AVMutableAudioMixInputParameters] = [:]
        var soundNeedsMix: Set<Int> = []
        var mainSources: [UUID: StudioCompositionInstruction.Source] = [:]
        for placed in plan.clips {
            guard let input = inputs[placed.clip.id] else { continue }
            let index = placed.trackIndex
            guard let track = videoTracks[index] ?? composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            videoTracks[index] = track
            let start = time(placed.startSec), end = time(placed.endSec)
            let outDuration = end - start
            guard outDuration > .zero else { continue }
            // At speed 1 the source range IS the output range (no scale, so no audio time-stretch).
            let unscaled = abs(StudioGeometry.clampSpeed(placed.clip.speed) - 1) <= 0.001
            let sourceRange = CMTimeRange(start: time(placed.sourceStartSec),
                                          duration: unscaled ? outDuration : time(placed.sourceDurationSec))
            guard place(sourceRange, of: input.video, on: track, at: start, outDuration: outDuration,
                        trackEnd: &videoEnds[index, default: .zero]) else { continue }
            mainSources[placed.clip.id] = .init(trackID: track.trackID, orient: input.orient)

            guard let audio = input.audio, let sound = soundTracks[index] ?? composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            soundTracks[index] = sound
            guard place(sourceRange, of: audio, on: sound, at: start, outDuration: outDuration,
                        trackEnd: &soundEnds[index, default: .zero]) else { continue }
            // Volume: the clip's own level, rising over the transition into it and falling over
            // the transition out of it (a cross-fade with the neighbour on the other track).
            let params = soundParams[index] ?? AVMutableAudioMixInputParameters(track: sound)
            soundParams[index] = params
            let volume = Float(placed.volume)
            if let fade = placed.audioFadeIn {
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                     timeRange: CMTimeRange(start: time(fade.lowerBound), end: time(fade.upperBound)))
            } else {
                params.setVolume(volume, at: start)
            }
            if let fade = placed.audioFadeOut {
                params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: time(fade.lowerBound), end: time(fade.upperBound)))
            }
            if placed.volume < 0.999 || placed.audioFadeIn != nil || placed.audioFadeOut != nil {
                soundNeedsMix.insert(index)
            }
        }
        // A clip with sound only on some tracks can leave an audio track that got no content.
        for (index, sound) in soundTracks where soundEnds[index, default: .zero] == .zero {
            composition.removeTrack(sound)
            soundParams[index] = nil
        }
        guard !mainSources.isEmpty, composition.duration > .zero else { throw ComposerError.noRenderableClips }

        // 4. Each picture-in-picture on its own video track, inside its window.
        var pipTrackSources: [UUID: StudioCompositionInstruction.Source] = [:]
        for pip in plan.pips {
            guard let input = pipInputs[pip.overlay.id], let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let start = time(pip.startSec), end = time(pip.endSec)
            var trackEnd = CMTime.zero
            guard end > start,
                  place(CMTimeRange(start: .zero, duration: end - start), of: input.video, on: track,
                        at: start, outDuration: end - start, trackEnd: &trackEnd) else {
                composition.removeTrack(track)
                continue
            }
            pipTrackSources[pip.overlay.id] = .init(trackID: track.trackID, orient: input.orient)
        }

        // 5. One instruction per plan segment, back to back from zero to the end.
        var instructions: [StudioCompositionInstruction] = []
        let finalEnd = max(time(plan.totalDuration), composition.duration)
        for (i, segment) in plan.segments.enumerated() {
            let start = instructions.last?.timeRange.end ?? .zero
            let end = i == plan.segments.count - 1 ? finalEnd : time(segment.endSec)
            guard end > start else { continue }
            instructions.append(StudioCompositionInstruction(
                timeRange: CMTimeRange(start: start, end: end), canvas: canvas, background: plan.background,
                main: segment.main.compactMap { layer in mainSources[layer.clipID].map { (layer, $0) } },
                pips: segment.pips.compactMap { layer in pipTrackSources[layer.overlayID].map { (layer, $0) } }))
        }

        // Start from the composition's own properties (a bare video composition was rejected by
        // the on-device encoder, S0), then replace what this compositor decides. SDR BT.709 out.
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        // Text, climb tags and the HR tile: the Core Animation tool draws them over the
        // compositor's frames. Export only — `AVPlayerItem` rejects a composition that has it.
        if !forPlayback {
            let placedHR: [PlacedClipHR] = plan.clips.compactMap { placed in
                guard let content = clipHRByID[placed.clip.id] else { return nil }
                // The tile's values run over the clip's whole slot; it is SHOWN over the stretch
                // the clip owns, so two clips' tiles are never drawn on top of each other during
                // a transition (the plan's rule, prompt 303).
                return PlacedClipHR(startSec: placed.startSec, durationSec: placed.durationSec,
                                    samples: content.samples, tile: content.tile,
                                    visibleStartSec: placed.ownedStartSec,
                                    visibleEndSec: placed.ownedEndSec)
            }
            videoComposition.animationTool = StudioOverlays.makeAnimationTool(
                overlays: overlays, canvas: canvas, totalDuration: composition.duration.seconds,
                hrSamples: hrSamples, hrTile: hrTile, clipHR: placedHR)
        }

        // 6. Added **music** (the edits "Add audio"): each on its own audio track at its startSec,
        // cut to the end of the video. Resolved from the app's Documents (where the importer
        // copied the picked file); a missing file is skipped so export never fails on it.
        var mixParams: [AVMutableAudioMixInputParameters] = soundNeedsMix.sorted().compactMap { soundParams[$0] }
        let videoEnd = composition.duration
        for music in audioTracks where music.kind != .original {
            guard let url = Self.musicURL(music.sourceRef) else { continue }
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
            let sourceDuration = (try? await asset.load(.duration)) ?? .zero
            let at = time(max(0, music.startSec))
            let available = videoEnd - at
            guard available > .zero, sourceDuration > .zero,
                  let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: min(sourceDuration, available)),
                                          of: source, at: at)
            } catch {
                composition.removeTrack(track)   // never leave an empty audio track behind (-11838)
                continue
            }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(Float(max(0, min(1, music.volume))), at: at)
            mixParams.append(params)
        }

        let audioMix: AVAudioMix?
        if mixParams.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix(); mix.inputParameters = mixParams; audioMix = mix
        }
        return (composition, videoComposition, audioMix)
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }

    /// Put `sourceRange` of `source` on `track` so it plays over `[at, at + outDuration]`: pad the
    /// track with an empty range up to `at`, insert, and scale the inserted part when the two
    /// lengths differ (a speed change). `trackEnd` is where the track's content ends; it moves
    /// only when the insert succeeds. Returns false when the insert fails.
    private func place(_ sourceRange: CMTimeRange, of source: AVAssetTrack,
                       on track: AVMutableCompositionTrack, at requested: CMTime,
                       outDuration: CMTime, trackEnd: inout CMTime) -> Bool {
        let at = max(requested, trackEnd)
        if at > trackEnd { track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: at)) }
        do { try track.insertTimeRange(sourceRange, of: source, at: at) } catch { return false }
        if sourceRange.duration != outDuration {
            track.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration), toDuration: outDuration)
        }
        trackEnd = at + outDuration
        return true
    }

    /// A track's size after its `preferredTransform`, and that transform moved so the upright
    /// picture's corner is at the origin (some files carry a rotation with no translation).
    private func orientation(of track: AVAssetTrack) async -> (size: CGSize, orient: CGAffineTransform) {
        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let preferred = (try? await track.load(.preferredTransform)) ?? .identity
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        return (CGSize(width: abs(rect.width), height: abs(rect.height)),
                preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)))
    }

    /// Resolve a music track's `sourceRef` (the filename the importer copied) to a URL in the app's
    /// Documents directory.
    private static func musicURL(_ ref: String) -> URL? {
        guard !ref.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent(ref)
    }

    /// Export the composed timeline to a temp `.mp4` via an async `AVAssetExportSession`.
    /// `quality` picks the `AVAssetExportSession` preset; an unsupported preset for this composition
    /// falls back to HighestQuality so export never fails on an over-ambitious 4K request.
    ///
    /// `progress` (prompt 298) receives the session's fraction done, 0…1, on the main actor about
    /// five times a second. Cancelling the calling Task cancels the session (`export(to:as:)` does
    /// that itself) and this function then throws `CancellationError`. On any throw the partial
    /// output file is deleted; on success the caller owns the returned file and deletes it.
    func export(_ snapshot: StudioProjectSnapshot, sourceDurations: [UUID: Double] = [:],
                hrSamples: [HRPoint] = [],
                hrTile: ResolvedHRTile? = nil,
                clipHRByID: [UUID: StudioClipHRContent] = [:],
                quality: StudioExportQuality = .highest,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        let (composition, videoComposition, audioMix) = try await makeComposition(
            for: snapshot, sourceDurations: sourceDurations, hrSamples: hrSamples,
            hrTile: hrTile, clipHRByID: clipHRByID)
        // Building the composition does not stop on a cancel; do not start a render nobody wants.
        try Task.checkCancellation()
        let session = AVAssetExportSession(asset: composition, presetName: quality.presetName)
            ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        guard let session else {
            throw ComposerError.exportFailed("could not create export session")
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-studio-\(UUID().uuidString).mp4")
        // The sequence is Sendable, the session is not: take it here and read it in the watcher.
        let states = session.states(updateInterval: 0.2)
        let watcher = progress.map { report in
            Task { @MainActor in
                for await state in states {
                    if Task.isCancelled { break }
                    if case .exporting(let p) = state { report(p.fractionCompleted) }
                }
            }
        }
        defer { watcher?.cancel() }
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: out)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
        return out
    }

    /// The source clip's full duration (for trim handles), or `nil` if unresolved (e.g. simulator).
    func sourceDuration(localIdentifier id: String) async -> Double? {
        guard let asset = await avAsset(forLocalIdentifier: id),
              let d = try? await asset.load(.duration).seconds, d > 0 else { return nil }
        return d
    }

    /// The source clip's **oriented** aspect ratio (width / height, after `preferredTransform`), or
    /// `nil` if unresolved. The studio uses it to size a new PiP's frame to its footage so the editor
    /// outline matches the aspect-fit video (no letterbox), and to set the base-video cell.
    func sourceAspect(localIdentifier id: String) async -> CGFloat? {
        guard let asset = await avAsset(forLocalIdentifier: id),
              let v = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let nat = (try? await v.load(.naturalSize)) ?? .zero
        let pref = (try? await v.load(.preferredTransform)) ?? .identity
        let o = orientedSize(nat, transform: pref)
        guard o.width > 0, o.height > 0 else { return nil }
        return o.width / o.height
    }

    private func orientedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func avAsset(forLocalIdentifier id: String) async -> AVAsset? {
        if let cached = await assetCache.get(id) { return cached.value }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true   // an iCloud-offloaded original must still open in Studio (prompt 265)
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        if let asset = boxed.value { await assetCache.set(id, Box(asset)) }
        return boxed.value
    }
}
