import Foundation
import AVFoundation
import Photos
import os
import HighlightEngine

private let logger = Logger(subsystem: "com.snappet", category: "ReelExporter")

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

    /// Build the playable composition and a normalising `AVVideoComposition` for a plan.
    /// The composition is an `AVAsset` reused for BOTH in-app preview (wrap in an `AVPlayer`)
    /// and export. The `AVVideoComposition` orients and letterboxes mixed-orientation clips
    /// into a single canvas (first segment's oriented size), fixing VideoToolbox -12902 that
    /// fires when segments of differing `naturalSize`/`preferredTransform` are exported with
    /// no explicit composition (#139). `sending` lets the freshly-built values cross to the
    /// `@MainActor` view model under Swift 6 isolation.
    func makeComposition(for plan: ReelPlan) async throws
        -> sending (AVMutableComposition, AVVideoComposition) {

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
        // Per-segment orientation data used below to build the normalising AVVideoComposition.
        var segmentInfos: [(prefT: CGAffineTransform, natSize: CGSize, start: CMTime)] = []

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
                let natSize = (try? await src.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
                let prefT = (try? await src.load(.preferredTransform)) ?? .identity
                let segStart = cursor
                do {
                    try vTrack?.insertTimeRange(range, of: src, at: cursor)
                    segmentInfos.append((prefT: prefT, natSize: natSize, start: segStart))
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
                let natSize = (try? await src.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
                let prefT = (try? await src.load(.preferredTransform)) ?? .identity
                let segStart = cursor
                do { try vTrack?.insertTimeRange(range, of: src, at: cursor) }
                catch { continue }
                if let srcA = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? aTrack?.insertTimeRange(range, of: srcA, at: cursor)
                }
                segmentInfos.append((prefT: prefT, natSize: natSize, start: segStart))
                cursor = cursor + range.duration
                inserted += 1
            }
        }
        guard inserted > 0 else { throw ExportError.noVideoSegments }

        // Build a normalising AVVideoComposition so VideoToolbox sees a consistent output format
        // regardless of how many different clip orientations and sizes are in the reel (#139).
        // Canvas = first segment's oriented size; later clips are letterboxed/pillarboxed in.
        let canvas: CGSize
        if let first = segmentInfos.first {
            canvas = Self.orientedSize(first.natSize, transform: first.prefT)
        } else {
            canvas = CGSize(width: 1920, height: 1080)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let fullInstruction = AVMutableVideoCompositionInstruction()
        fullInstruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        if let track = vTrack {
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let canvasRect = CGRect(origin: .zero, size: canvas)
            for info in segmentInfos {
                let oriented = Self.orientedSize(info.natSize, transform: info.prefT)
                let fit = ClipEditGeometry.fitTransform(sourceSize: oriented, into: canvasRect)
                // preferredTransform orients the raw naturalSize frame; fit aspect-fits (letterboxes)
                // the oriented result into the canvas. Step-constant across each segment's time range.
                layerInstruction.setTransform(info.prefT.concatenating(fit), at: info.start)
            }
            fullInstruction.layerInstructions = [layerInstruction]
        }

        videoComposition.instructions = [fullInstruction]
        return (composition, videoComposition)
    }

    func export(_ plan: ReelPlan) async throws -> URL {
        let (composition, videoComposition) = try await makeComposition(for: plan)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportFailed("could not create export session")
        }
        session.videoComposition = videoComposition
        let out: URL
        do { out = try exportDestination() }
        catch { throw ExportError.exportFailed(error.localizedDescription) }
        // Modern async export (iOS 18+): throws on failure, no continuation/data-race.
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            let nsErr = error as NSError
            let under = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError
            logger.error(
                "reel export failed — domain: \(nsErr.domain, privacy: .public) code: \(nsErr.code) underlying: \(under?.domain ?? "-", privacy: .public) \(under?.code ?? 0)"
            )
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

    /// Apply a track's `preferredTransform` to its natural size to get the display size
    /// (swaps width/height for 90°/270° rotations). Mirrors `VideoStudio.orientedSize`.
    private static func orientedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }
}
