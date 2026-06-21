import Foundation
import AVFoundation
import Photos
import OSLog
import HighlightEngine

private let reelLog = Logger(subsystem: "com.snappet.app", category: "ReelExporter")

/// Wraps a non-Sendable value so it can cross an async continuation boundary.
/// Safe here because each boxed value is produced and consumed exactly once, serially.
private struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Turns a platform-free `ReelPlan` into an actual video using AVFoundation
/// (#60 §5), entirely on-device. Resolves each segment's source `AVAsset` from its
/// PHAsset id, stitches the trimmed ranges into an `AVMutableComposition`, and
/// exports an .mp4 to `Application Support/Reels` (see `exportDestination()`).
///
/// Photos (still segments) are skipped in v1's video stitch — a follow-up can render
/// a Ken-Burns still for `photoStill` seconds. Videos are the core of the reel.
/// Stateless → `Sendable`.
final class ReelExporter: Sendable {

    enum ExportError: LocalizedError {
        case noVideoSegments, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoSegments: return "This reel has no video clips to assemble yet."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    /// Geometry captured per inserted segment so the `AVVideoComposition` can orient + fit each one.
    private struct SegmentLayout {
        let start: CMTime              // segment start on the composition timeline
        let orientedSize: CGSize       // natural size AFTER the preferredTransform is applied
        let preferredTransform: CGAffineTransform
    }

    /// Build the playable composition for a plan, plus a normalizing `AVVideoComposition`. An
    /// `AVMutableComposition` is an `AVAsset`, so this is reused for BOTH in-app preview (wrap in an
    /// `AVPlayer`, no export) and export. The video composition orients each segment via its
    /// `preferredTransform` and aspect-fits it into one render canvas — WITHOUT it, a reel that mixes
    /// clip dimensions/orientations fails to export on device (`AVFoundationErrorDomain -11800 /
    /// OSStatus -12902`): the exporter can't resolve a single output format across the segments.
    /// `sending` lets the freshly-built, otherwise-unreferenced values cross to the `@MainActor`
    /// view model under Swift 6 isolation.
    func makeComposition(for plan: ReelPlan) async throws
        -> sending (AVMutableComposition, AVVideoComposition?) {
        let renderable = plan.segments.filter {
            ($0.kind == .video && $0.duration > 0.1) || $0.kind == .photo
        }
        guard !renderable.isEmpty else { throw ExportError.noVideoSegments }

        let composition = AVMutableComposition()
        let vTrack = composition.addMutableTrack(withMediaType: .video,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTrack = composition.addMutableTrack(withMediaType: .audio,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
        let photoRenderer = PhotoClipRenderer()
        var cursor = CMTime.zero
        var inserted = 0
        var layouts: [SegmentLayout] = []

        // Iterate segments IN ORDER so photos interleave with videos correctly.
        for seg in renderable {
            if seg.kind == .photo {
                // Render the still to a Ken-Burns clip, then insert it like a video.
                guard let url = await photoRenderer.renderClip(assetId: seg.mediaItemId,
                                                               duration: plan.photoStill) else { continue }
                let asset = AVURLAsset(url: url)
                guard let src = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                let dur = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: dur)
                do {
                    try vTrack?.insertTimeRange(range, of: src, at: cursor)
                    layouts.append(await layout(for: src, start: cursor))
                    cursor = cursor + dur
                    inserted += 1
                } catch { continue }   // skip a bad photo clip, keep the reel
            } else {
                guard let asset = await avAsset(forLocalIdentifier: seg.mediaItemId) else { continue }
                let range = CMTimeRange(
                    start: CMTime(seconds: seg.startWithinMedia, preferredTimescale: 600),
                    duration: CMTime(seconds: seg.duration, preferredTimescale: 600)
                )
                guard let src = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                do { try vTrack?.insertTimeRange(range, of: src, at: cursor) }
                catch { continue }
                layouts.append(await layout(for: src, start: cursor))
                if let srcA = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? aTrack?.insertTimeRange(range, of: srcA, at: cursor)
                }
                cursor = cursor + range.duration
                inserted += 1
            }
        }
        guard inserted > 0, let vTrack else { throw ExportError.noVideoSegments }

        let videoComposition = makeVideoComposition(track: vTrack, layouts: layouts,
                                                    totalDuration: composition.duration)
        return (composition, videoComposition)
    }

    /// Capture a segment's oriented size + transform from its source video track.
    private func layout(for track: AVAssetTrack, start: CMTime) async -> SegmentLayout {
        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1080, height: 1920)
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        return SegmentLayout(start: start,
                             orientedSize: orientedSize(natural, transform: transform),
                             preferredTransform: transform)
    }

    /// One `AVVideoComposition` over the single composition video track: a render canvas sized to the
    /// FIRST segment's oriented size (so a same-orientation reel keeps native resolution), with a
    /// piecewise `setTransform` per segment that orients then aspect-fits (letterboxes) into the canvas.
    private func makeVideoComposition(track: AVCompositionTrack, layouts: [SegmentLayout],
                                      totalDuration: CMTime) -> AVMutableVideoComposition? {
        guard let first = layouts.first else { return nil }
        // Even dimensions keep the encoder happy.
        let renderSize = CGSize(width: (first.orientedSize.width / 2).rounded() * 2,
                                height: (first.orientedSize.height / 2).rounded() * 2)
        guard renderSize.width >= 2, renderSize.height >= 2 else { return nil }

        let vc = AVMutableVideoComposition()
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        for seg in layouts {
            layer.setTransform(fitTransform(orientedSize: seg.orientedSize,
                                            preferred: seg.preferredTransform,
                                            renderSize: renderSize), at: seg.start)
        }
        instruction.layerInstructions = [layer]
        vc.instructions = [instruction]
        return vc
    }

    /// Size of a track's frame after its `preferredTransform` (rotation) is applied.
    private func orientedSize(_ natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Orient (preferredTransform) → uniform-scale to fit the canvas → center. Aspect-preserving, so
    /// a differently-oriented clip letterboxes rather than distorting.
    private func fitTransform(orientedSize o: CGSize, preferred: CGAffineTransform,
                              renderSize r: CGSize) -> CGAffineTransform {
        guard o.width > 0, o.height > 0 else { return preferred }
        let scale = min(r.width / o.width, r.height / o.height)
        let tx = (r.width - o.width * scale) / 2
        let ty = (r.height - o.height * scale) / 2
        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// A burned-in HR overlay for the export, sourced from a session's HR window. Reusing the EDITOR's
    /// overlay system (`HROverlayValues` → `HRTile.make(template:)` → `StudioOverlays.makeAnimationTool`)
    /// keeps a single source of truth — the recap-feed "Animate" clip matches the studio's scorebug.
    /// `Sendable` value-type snapshot so it crosses into the AVFoundation export with no `@Model`.
    struct HROverlay: Sendable {
        var hrSeries: [HRPoint]
        var maxHR: Double?
        var restHR: Double?
        var clipName: String? = nil
    }

    func export(_ plan: ReelPlan) async throws -> URL {
        try await export(plan, hrOverlay: nil)
    }

    /// Export, optionally burning a scorebug HR overlay over the stitched reel. When `hrOverlay != nil`,
    /// the editor's Core-Animation overlay tool is attached to the (mutable) video composition. Any miss
    /// (no mutable composition / no resolvable tile / no tool) silently exports WITHOUT the overlay — the
    /// share offer never crashes or blocks on the overlay being renderable.
    func export(_ plan: ReelPlan, hrOverlay: HROverlay?) async throws -> URL {
        let (composition, videoComposition) = try await makeComposition(for: plan)
        var exportVideoComposition = videoComposition

        if let hrOverlay, let mvc = videoComposition as? AVMutableVideoComposition {
            let values = HROverlayValues(samples: hrOverlay.hrSeries,
                                         durationSec: composition.duration.seconds,
                                         maxHR: hrOverlay.maxHR,
                                         restHR: hrOverlay.restHR)
            if let tile = values.resolveTile(HRTile.make(template: .scorebug)),
               let tool = StudioOverlays.makeAnimationTool(
                    overlays: [], canvas: mvc.renderSize,
                    totalDuration: composition.duration.seconds,
                    hrSamples: hrOverlay.hrSeries, hrTile: tile) {
                mvc.animationTool = tool
                exportVideoComposition = mvc
            }
        }

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportFailed("could not create export session")
        }
        session.videoComposition = exportVideoComposition
        let out: URL
        do { out = try exportDestination() }
        catch { throw ExportError.exportFailed(error.localizedDescription) }
        // Modern async export (iOS 18+): throws on failure, no continuation/data-race.
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            // The bare localizedDescription is "The operation could not be completed" — useless for
            // diagnosis. Capture domain/code/underlying so a device failure is actionable.
            let ns = error as NSError
            let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
            let detail = "\(ns.domain) \(ns.code)"
                + (underlying.map { " · underlying \($0.domain) \($0.code): \($0.localizedDescription)" } ?? "")
            // Developer-facing diagnosis goes to Console (os_log); the user sees only the clean message.
            reelLog.error("Reel export failed: \(detail, privacy: .public) — segments=\(plan.segments.count, privacy: .public)")
            throw ExportError.exportFailed(error.localizedDescription)
        }
        return out
    }

    /// Where a finished reel lands: `Application Support/Reels` — **not** `tmp`, which the system
    /// purges and which made backing out / "Make another cut" destroy the artifact mid-flow
    /// (issue #72 §4). Excluded from backup (regenerable, potentially large full-length renders);
    /// renders beyond the newest `ReelFlowPolicy.keepLatestExports` are swept before each new
    /// export. The kept files are an internal safety net only — nothing in the UI lists or
    /// reopens them — so Save to Photos stays the one durable home the user-facing copy promises
    /// (review fix: no copy may imply a replaced cut is retrievable here).
    private func exportDestination() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        var dir = ReelFlowPolicy.exportsDirectory(under: support)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        sweepOldExports(in: dir)
        return ReelFlowPolicy.exportURL(in: dir, id: UUID())
    }

    /// Best-effort cleanup; which files go is the pure `ReelFlowPolicy.sweepableExports` decision.
    private func sweepOldExports(in dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let existing = contents.map { url in
            (url: url,
             modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast)
        }
        for url in ReelFlowPolicy.sweepableExports(existing: existing) {
            try? fm.removeItem(at: url)
        }
    }

    private func avAsset(forLocalIdentifier id: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        return boxed.value
    }
}
