import Foundation
import AVFoundation
import Photos
import CoreGraphics
import CoreImage
import UIKit

/// Turns a `StudioProjectSnapshot` (multi-clip timeline) into a playable/exportable AVFoundation
/// composition — the full studio's render engine (S1), generalizing `VideoStudio` from one clip to
/// many. Like `VideoStudio`, the single `makeComposition(for:sourceDurations:)` builds the
/// `(AVMutableComposition, AVVideoComposition?)` reused for **both** preview (`AVPlayer`) and export,
/// reusing the same `Box`/`avAsset` PHAsset-resolution and `ClipEditGeometry` transform math.
///
/// **S1 scope (this file):** ordered **video** clips inserted sequentially (trim + speed) with a
/// shared output canvas (`renderSize`) and per-clip orientation+crop transforms — the mixed-
/// orientation normalization, now across many clips. **Device-only** (PHAsset → AVAsset needs a real
/// Photos library; nothing renders on the simulator), so it is exercised by build + the pure
/// `StudioGeometry`/`StudioProjectEditor` tests, not a simulator run.
///
/// **Deferred to S2+ (extension points, intentionally not yet rendered):** Core-Image filters/LUTs
/// (`TimelineClip.filter`) via a custom `AVVideoCompositing`; transitions (`StudioTransition`) as
/// opacity/transform ramps; overlays (`OverlayItem`) via `AVVideoCompositionCoreAnimationTool`;
/// Ken-Burns photos via `PhotoClipRenderer`; the audio mix (`AudioTrack`). The model already carries
/// all of these — only the compositor pass is pending (gated by the S0 device-profiling spike).
final class StudioComposer: Sendable {

    private struct Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

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
    /// the live preview gets a tool-free composition (overlays don't show in preview; everything else
    /// — transforms / filters / transitions — does), while **export** (default `false`) keeps the
    /// tool so overlays render into the file.
    func makeComposition(for snapshot: StudioProjectSnapshot,
                         sourceDurations: [UUID: Double] = [:],
                         forPlayback: Bool = false) async throws
        -> sending (AVMutableComposition, AVVideoComposition?, AVAudioMix?) {

        // S1 renders video clips; photos are a Ken-Burns step in S2+.
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
                                  videoOverlays: videoOverlays, forPlayback: forPlayback)
    }

    /// Build the multi-clip composition from **already-resolved** `(clip, AVAsset)` pairs — the
    /// testable seam, decoupled from Photos. The S0 profiling spike drives this directly with a
    /// synthetic on-device video (no PHAsset needed), so on-device export cost can be measured.
    func assemble(resolved: sending [(clip: TimelineClip, asset: AVAsset)],
                  aspect: ClipEditGeometry.OutputAspect,
                  sourceDurations: [UUID: Double] = [:],
                  transitions: [StudioTransition] = [],
                  overlays: [OverlayItem] = [],
                  audioTracks: [AudioTrack] = [],
                  videoOverlays: sending [(overlay: OverlayItem, asset: AVAsset)] = [],
                  forPlayback: Bool = false) async throws
        -> sending (AVMutableComposition, AVVideoComposition?, AVAudioMix?) {
        guard !resolved.isEmpty else { throw ComposerError.noRenderableClips }

        // Transitions need two overlapping tracks (separate path); the CIFilter handler composites
        // tracks itself so it can't combine with them. Use the transition path when a transition is
        // set, NO clip has a filter, AND there's no PiP (PiP needs the instruction layer path). If
        // both are present, fall through — filters/PiP render and the transition is dropped (graceful
        // degradation; combining needs a custom AVVideoCompositing, deferred — decisions.md).
        if transitions.contains(where: { $0.kind != .none }),
           !resolved.contains(where: { $0.clip.filter != .none }), videoOverlays.isEmpty {
            return try await assembleWithTransitions(
                resolved: resolved, transitions: transitions, aspect: aspect,
                sourceDurations: sourceDurations, overlays: overlays, forPlayback: forPlayback)
        }
        return try await assembleSingleTrack(resolved: resolved, aspect: aspect,
                                             sourceDurations: sourceDurations, overlays: overlays,
                                             audioTracks: audioTracks, videoOverlays: videoOverlays,
                                             forPlayback: forPlayback)
    }

    /// The single-track path: clips inserted sequentially on one video track. No-filter clips use a
    /// per-clip transform/crop layer instruction; any filtered clip routes through a Core Image handler.
    private func assembleSingleTrack(resolved: sending [(clip: TimelineClip, asset: AVAsset)],
                                     aspect: ClipEditGeometry.OutputAspect,
                                     sourceDurations: [UUID: Double],
                                     overlays: [OverlayItem],
                                     audioTracks: [AudioTrack] = [],
                                     videoOverlays: sending [(overlay: OverlayItem, asset: AVAsset)] = [],
                                     forPlayback: Bool) async throws
        -> sending (AVMutableComposition, AVVideoComposition?, AVAudioMix?) {
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposerError.noRenderableClips
        }
        // Audio track is created LAZILY (only when a clip actually has audio) — an empty audio track
        // left in the composition makes the videoComposition export fail -11838 on-device, and real
        // clips can legitimately have no audio (S0 spike).
        var aTrack: AVMutableCompositionTrack?

        var cursor = CMTime.zero
        // ONE layer instruction for the single video track; each clip sets its transform at its own
        // start time (a piecewise-constant transform across the sequential cuts). Multiple layer
        // instructions for the same track in one instruction is malformed and fails export.
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        var renderSize: CGSize?
        // Per-clip colour filter + manual adjust, by output time range (drives the CIFilter path below).
        var filterRanges: [(range: CMTimeRange, filter: StudioFilter, intensity: Double, adjust: ClipAdjust?)] = []
        // Per-clip original-audio volume, by the audio segment's start time (drives the AVAudioMix).
        var audioVolumes: [(at: CMTime, volume: Double)] = []

        for (clip, source) in resolved {
            guard let srcVideo = try? await source.loadTracks(withMediaType: .video).first else {
                continue   // no video track → skip this clip, keep the rest
            }
            var assetDuration = sourceDurations[clip.id] ?? 0
            if assetDuration <= 0 { assetDuration = (try? await source.load(.duration).seconds) ?? 0 }
            guard let window = ClipEditGeometry.trimWindow(
                start: clip.trimStart, end: clip.trimEnd ?? assetDuration,
                assetDuration: assetDuration) else { continue }

            let naturalSize = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let preferred = (try? await srcVideo.load(.preferredTransform)) ?? .identity
            let orientedSize = orientedSize(naturalSize, transform: preferred)
            let canvas = renderSize ?? ClipEditGeometry.renderSize(for: aspect, sourceSize: orientedSize)
            renderSize = canvas

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: window.start, preferredTimescale: timescale),
                duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
            let insertAt = cursor
            do { try vTrack.insertTimeRange(sourceRange, of: srcVideo, at: insertAt) }
            catch { continue }

            // Speed-scale the just-inserted segment in place.
            let outDuration = ClipEditGeometry.scaledDuration(sourceDuration: window.duration, speed: clip.speed)
            if abs(clip.speed - 1.0) > 0.001 {
                let segment = CMTimeRange(start: insertAt,
                                          duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
                vTrack.scaleTimeRange(segment, toDuration: CMTime(seconds: outDuration, preferredTimescale: timescale))
            }

            // Original audio (also speed-scaled), if present — create the audio track on first use.
            if let srcAudio = try? await source.loadTracks(withMediaType: .audio).first {
                let track = aTrack ?? composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                aTrack = track
                if let track {
                    try? track.insertTimeRange(sourceRange, of: srcAudio, at: insertAt)
                    if abs(clip.speed - 1.0) > 0.001 {
                        let seg = CMTimeRange(start: insertAt,
                                              duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
                        track.scaleTimeRange(seg, toDuration: CMTime(seconds: outDuration, preferredTimescale: timescale))
                    }
                    audioVolumes.append((insertAt, max(0, min(1, clip.volume ?? 1))))
                }
            }

            // Per-clip transform (orientation THEN crop→canvas), set at this clip's start time on
            // the shared layer instruction — it holds until the next clip's transform.
            let crop = ClipEditGeometry.cropTransform(
                cropRect: clip.cropRect, sourceSize: orientedSize, renderSize: canvas)
            layerInstruction.setTransform(preferred.concatenating(crop), at: insertAt)

            let outRange = CMTimeRange(start: insertAt,
                                       duration: CMTime(seconds: outDuration, preferredTimescale: timescale))
            filterRanges.append((outRange, clip.filter, clip.filterIntensity, clip.adjust))
            cursor = outRange.end
        }

        guard cursor > .zero, let canvas = renderSize else { throw ComposerError.noRenderableClips }

        let hasPiP = !videoOverlays.isEmpty
        let videoComposition: AVMutableVideoComposition
        if !hasPiP, filterRanges.contains(where: { $0.filter != .none || ($0.adjust?.isNeutral == false) }) {
            // S2 — at least one clip has a colour filter or a manual adjust: composite through Core
            // Image. AVFoundation hands each frame to the handler as a CIImage; we aspect-fill it to
            // the canvas and apply the active clip's filter THEN its adjust. (This path supersedes the
            // per-clip transform/crop instruction; combining precise crop WITH a filter is a follow-up
            // — the layout here is aspect-fill.)
            let ranges = filterRanges
            videoComposition = AVMutableVideoComposition(asset: composition) { request in
                let t = request.compositionTime
                var image = StudioFilters.aspectFill(request.sourceImage, to: canvas)
                if let active = ranges.first(where: { $0.range.containsTime(t) }) {
                    if active.filter != .none {
                        image = StudioFilters.apply(active.filter, intensity: active.intensity, to: image)
                    }
                    image = StudioFilters.applyAdjust(active.adjust, to: image)
                }
                request.finish(with: image, context: nil)
            }
            videoComposition.renderSize = canvas
            // Overlays compose over the filtered frames too (text/sticker on a filtered clip) — but
            // the Core Animation tool is export-only (AVPlayerItem rejects it), so skip it for preview.
            if !forPlayback {
                videoComposition.animationTool = StudioOverlays.makeAnimationTool(
                    overlays: overlays, canvas: canvas, totalDuration: composition.duration.seconds)
            }
        } else {
            // No filters: the transform/crop path. Build from the composition's own properties (so
            // color/format tags + a valid source-track mapping are present) rather than a bare
            // `AVMutableVideoComposition()`, which the on-device encoder rejects with -11838 (S0).
            // Picture-in-picture: add a second video track per .video overlay BEFORE deriving the
            // videoComposition (so its tracks are present), composited on top of the main track.
            var pipLayerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
            for (ov, asset) in videoOverlays {
                if let li = await insertPiPTrack(ov, asset: asset, into: composition, canvas: canvas) {
                    pipLayerInstructions.append(li)
                }
            }
            videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
            videoComposition.renderSize = canvas
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            instruction.layerInstructions = pipLayerInstructions + [layerInstruction]   // PiP on top
            videoComposition.instructions = [instruction]
            // S4: time-gated text overlays via Core Animation (nil when there are none). Combining
            // overlays with a colour filter is a follow-up (the filter path composites differently).
            // The Core Animation tool is export-only (AVPlayerItem rejects it), so skip it for preview.
            if !forPlayback {
                videoComposition.animationTool = StudioOverlays.makeAnimationTool(
                    overlays: overlays, canvas: canvas, totalDuration: composition.duration.seconds)
            }
        }

        // Added **music** tracks (the edits "Add audio"): each is inserted on its own audio track at
        // its startSec and volume-mixed. Resolved from the app's Documents (where the importer copied
        // the picked file); a missing file is skipped so export never fails on it.
        var mixParams: [AVMutableAudioMixInputParameters] = []
        for music in audioTracks where music.kind != .original {
            guard let url = Self.musicURL(music.sourceRef),
                  let mAudio = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
                  let mTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let mAsset = AVURLAsset(url: url)
            let srcDur = (try? await mAsset.load(.duration)) ?? .zero
            let at = CMTime(seconds: max(0, music.startSec), preferredTimescale: timescale)
            let avail = composition.duration - at
            guard avail > .zero, srcDur > .zero else { continue }
            let dur = min(srcDur, avail)
            try? mTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: mAudio, at: at)
            let p = AVMutableAudioMixInputParameters(track: mTrack)
            p.setVolume(Float(max(0, min(1, music.volume))), at: at)
            mixParams.append(p)
        }

        // Per-clip original-audio volume → AVAudioMix params (only when a clip dials volume off 1).
        if let aTrack, audioVolumes.contains(where: { $0.volume < 0.999 }) {
            let params = AVMutableAudioMixInputParameters(track: aTrack)
            for v in audioVolumes { params.setVolume(Float(v.volume), at: v.at) }
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

    /// Insert a **picture-in-picture** clip on its own video track and return its layer instruction
    /// (aspect-filled into the PiP frame, oriented, time-gated to `[startSec, endSec]`). Returns nil if
    /// the source has no video track. The PiP frame's vertical centre is flipped to the video
    /// composition's bottom-left origin (matching the overlay `layerPoint` convention).
    private func insertPiPTrack(_ ov: OverlayItem, asset: AVAsset, into composition: AVMutableComposition,
                                canvas: CGSize) async -> AVMutableVideoCompositionLayerInstruction? {
        guard let pv = try? await asset.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let nat = (try? await pv.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let pref = (try? await pv.load(.preferredTransform)) ?? .identity
        let oriented = orientedSize(nat, transform: pref)
        let srcDur = ((try? await asset.load(.duration))?.seconds) ?? 0
        let winStart = max(0, ov.startSec)
        let winEnd = max(winStart + 0.1, ov.endSec)
        let insertDur = min(srcDur > 0 ? srcDur : (winEnd - winStart), winEnd - winStart)
        guard insertDur > 0 else { return nil }
        let at = CMTime(seconds: winStart, preferredTimescale: timescale)
        if at > .zero { track.insertEmptyTimeRange(CMTimeRange(start: .zero, end: at)) }
        do {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: insertDur, preferredTimescale: timescale)),
                                      of: pv, at: at)
        } catch { return nil }

        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let center = CGPoint(x: ov.normalizedX, y: 1 - ov.normalizedY)   // flip Y to bottom-left origin
        let rect = ClipEditGeometry.pipRect(normalizedCenter: center, scale: ov.scale, canvas: canvas)
        li.setTransform(pref.concatenating(ClipEditGeometry.fillTransform(sourceSize: oriented, into: rect)), at: .zero)
        // Visible only within the window (opacity 0 outside).
        let op = Float(min(1, max(0, ov.opacity == 0 ? 1 : ov.opacity)))
        if at > .zero { li.setOpacity(0, at: .zero); li.setOpacity(op, at: at) } else { li.setOpacity(op, at: .zero) }
        let endTime = CMTime(seconds: winEnd, preferredTimescale: timescale)
        if endTime < composition.duration { li.setOpacity(0, at: endTime) }
        return li
    }

    /// Resolve a music track's `sourceRef` (the filename the importer copied) to a URL in the app's
    /// Documents directory.
    private static func musicURL(_ ref: String) -> URL? {
        guard !ref.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent(ref)
    }

    /// Build a **dissolve-transition** composition (S3). Clips alternate between two video tracks
    /// (A = even, B = odd) placed with the `StudioGeometry.timeline` overlaps; B is composited on top
    /// and its opacity is ramped over each overlap — fading B IN when it's the incoming clip, OUT when
    /// it's outgoing — so A (always opaque, underneath) is revealed/covered to cross-dissolve. Only
    /// dissolve for now (slide/zoom = transform ramps, and combining with filters, are follow-ups).
    func assembleWithTransitions(
        resolved: sending [(clip: TimelineClip, asset: AVAsset)],
        transitions: [StudioTransition],
        aspect: ClipEditGeometry.OutputAspect,
        sourceDurations: [UUID: Double],
        overlays: [OverlayItem] = [],
        forPlayback: Bool = false) async throws
        -> sending (AVMutableComposition, AVVideoComposition?, AVAudioMix?) {

        let ordered = StudioGeometry.ordered(resolved.map(\.clip))
        let assetByID = Dictionary(resolved.map { ($0.clip.id, $0.asset) }, uniquingKeysWith: { a, _ in a })

        var durations: [UUID: Double] = [:]
        for clip in ordered {
            var d = sourceDurations[clip.id] ?? 0
            if d <= 0, let a = assetByID[clip.id] { d = (try? await a.load(.duration).seconds) ?? 0 }
            durations[clip.id] = d
        }
        let placed = StudioGeometry.timeline(clips: ordered, sourceDurations: durations, transitions: transitions)
        let placeByID = Dictionary(placed.map { ($0.clip.id, $0) }, uniquingKeysWith: { a, _ in a })

        let composition = AVMutableComposition()
        guard let trackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposerError.noRenderableClips
        }
        let liA = AVMutableVideoCompositionLayerInstruction(assetTrack: trackA)
        let liB = AVMutableVideoCompositionLayerInstruction(assetTrack: trackB)
        var aTrack: AVMutableCompositionTrack?
        var endA = CMTime.zero, endB = CMTime.zero
        var canvas: CGSize?
        var transformByID: [UUID: CGAffineTransform] = [:]   // each clip's base transform

        for (i, clip) in ordered.enumerated() {
            guard let asset = assetByID[clip.id], let p = placeByID[clip.id],
                  let srcVideo = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let dur = durations[clip.id] ?? 0
            guard let window = ClipEditGeometry.trimWindow(
                start: clip.trimStart, end: clip.trimEnd ?? dur, assetDuration: dur) else { continue }
            let nat = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let pref = (try? await srcVideo.load(.preferredTransform)) ?? .identity
            let oriented = orientedSize(nat, transform: pref)
            let cv = canvas ?? ClipEditGeometry.renderSize(for: aspect, sourceSize: oriented)
            canvas = cv

            let isA = (i % 2 == 0)
            let vtrack = isA ? trackA : trackB
            let li = isA ? liA : liB
            let at = CMTime(seconds: p.startSec, preferredTimescale: timescale)
            // Pad with an empty range so the clip lands exactly at its placed (overlapped) start.
            let curEnd = isA ? endA : endB
            if at > curEnd { vtrack.insertEmptyTimeRange(CMTimeRange(start: curEnd, end: at)) }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: window.start, preferredTimescale: timescale),
                duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
            do { try vtrack.insertTimeRange(sourceRange, of: srcVideo, at: at) } catch { continue }
            let outDur = ClipEditGeometry.scaledDuration(sourceDuration: window.duration, speed: clip.speed)
            if abs(clip.speed - 1.0) > 0.001 {
                let seg = CMTimeRange(start: at, duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
                vtrack.scaleTimeRange(seg, toDuration: CMTime(seconds: outDur, preferredTimescale: timescale))
            }
            let newEnd = CMTimeAdd(at, CMTime(seconds: outDur, preferredTimescale: timescale))
            if isA { endA = newEnd } else { endB = newEnd }

            if let aSrc = try? await asset.loadTracks(withMediaType: .audio).first {
                let track = aTrack ?? composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                aTrack = track
                try? track?.insertTimeRange(sourceRange, of: aSrc, at: at)
            }

            let crop = ClipEditGeometry.cropTransform(cropRect: clip.cropRect, sourceSize: oriented, renderSize: cv)
            let xform = pref.concatenating(crop)
            li.setTransform(xform, at: at)
            transformByID[clip.id] = xform
        }

        guard let cv = canvas, composition.duration > .zero else { throw ComposerError.noRenderableClips }

        // Each transition animates track B (always on top): IN when B is the incoming clip, OUT when
        // outgoing, over the overlap [next.start, current.end]. Dissolve/fade ramp opacity; slide/zoom
        // ramp B's transform between its in-place pose and an off-canvas pose.
        for i in 0 ..< (ordered.count - 1) {
            guard let t = transitions.first(where: { $0.afterClipID == ordered[i].id && $0.kind != .none }),
                  let cur = placeByID[ordered[i].id], let nxt = placeByID[ordered[i + 1].id] else { continue }
            let start = CMTime(seconds: nxt.startSec, preferredTimescale: timescale)
            let end = CMTime(seconds: cur.endSec, preferredTimescale: timescale)
            guard end > start else { continue }
            let range = CMTimeRange(start: start, end: end)
            let bIncoming = (i + 1) % 2 == 1                         // the incoming clip (i+1) is on track B
            let base = transformByID[bIncoming ? ordered[i + 1].id : ordered[i].id] ?? .identity
            switch t.kind {
            case .dissolve, .fadeThroughBlack:
                liB.setOpacityRamp(fromStartOpacity: bIncoming ? 0 : 1,
                                   toEndOpacity: bIncoming ? 1 : 0, timeRange: range)
            case .slideLeft, .slideRight, .zoomIn:
                let off = Self.offCanvasTransform(kind: t.kind, base: base, canvas: cv, incoming: bIncoming)
                liB.setTransformRamp(fromStart: bIncoming ? off : base,
                                     toEnd: bIncoming ? base : off, timeRange: range)
            case .none:
                break
            }
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [liB, liA]   // B on top

        let vc = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        vc.renderSize = cv
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [instruction]
        // S4 text overlays via the Core Animation tool — export-only (AVPlayerItem rejects it), so
        // skip it for the live preview.
        if !forPlayback {
            vc.animationTool = StudioOverlays.makeAnimationTool(
                overlays: overlays, canvas: cv, totalDuration: composition.duration.seconds)
        }
        // Per-clip volume on the transition path is a follow-up (audio here is a plain stitch).
        return (composition, vc, nil)
    }

    /// Export the composed timeline to a temp `.mp4` (same async export path as `VideoStudio`).
    /// `quality` picks the `AVAssetExportSession` preset; an unsupported preset for this composition
    /// falls back to HighestQuality so export never fails on an over-ambitious 4K request.
    func export(_ snapshot: StudioProjectSnapshot, sourceDurations: [UUID: Double] = [:],
                quality: StudioExportQuality = .highest) async throws -> URL {
        let (composition, videoComposition, audioMix) = try await makeComposition(
            for: snapshot, sourceDurations: sourceDurations)
        let session = AVAssetExportSession(asset: composition, presetName: quality.presetName)
            ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        guard let session else {
            throw ComposerError.exportFailed("could not create export session")
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-studio-\(UUID().uuidString).mp4")
        try await session.export(to: out, as: .mp4)
        return out
    }

    /// The source clip's full duration (for trim handles), or `nil` if unresolved (e.g. simulator).
    func sourceDuration(localIdentifier id: String) async -> Double? {
        guard let asset = await avAsset(forLocalIdentifier: id),
              let d = try? await asset.load(.duration).seconds, d > 0 else { return nil }
        return d
    }

    /// The off-canvas pose for a slide/zoom transition, relative to a clip's in-place `base` transform.
    /// slide = a full-width translation (enter-from / exit-to a side); zoom = a small scale about the
    /// canvas centre. `incoming` flips the side so the clip enters from the opposite edge it exits to.
    private static func offCanvasTransform(kind: StudioTransitionKind, base: CGAffineTransform,
                                           canvas: CGSize, incoming: Bool) -> CGAffineTransform {
        switch kind {
        case .slideLeft:
            return base.concatenating(CGAffineTransform(translationX: incoming ? canvas.width : -canvas.width, y: 0))
        case .slideRight:
            return base.concatenating(CGAffineTransform(translationX: incoming ? -canvas.width : canvas.width, y: 0))
        case .zoomIn:
            let cx = canvas.width / 2, cy = canvas.height / 2
            let scaleAboutCentre = CGAffineTransform(translationX: cx, y: cy)
                .scaledBy(x: 0.2, y: 0.2).translatedBy(x: -cx, y: -cy)
            return base.concatenating(scaleAboutCentre)
        default:
            return base
        }
    }

    private func orientedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func avAsset(forLocalIdentifier id: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        return boxed.value
    }
}
