import Foundation
import Photos
import AVFoundation
import UIKit

// MARK: - Clips feed — share a single clip's video (prompt 87)
//
// Exports one Clips-feed clip to a temp file for the system share sheet (`ShareSheet`). Two lanes:
// - `exportForSharing` — the RAW clip (passthrough, no re-encode): "Share original clip".
// - `exportWithHeartRate` (prompt 160) — the clip's kept range re-encoded with the feed's HR tile and
//   name lower-third burned in, via the Studio's own Core-Animation overlay tool: "Share with heart rate".
// Device-only: needs the real `PHAsset`, so both return nil on the simulator / for a missing or non-video
// asset (the caller shows the "couldn't prepare" alert).

enum ClipShareService {

    /// Export the clip's video by Photos `localIdentifier` to a temp `.mov` for sharing, or nil on failure.
    static func exportForSharing(localIdentifier: String) async -> URL? {
        guard let avAsset = await videoAsset(localIdentifier: localIdentifier) else { return nil }

        // Try passthrough (no re-encode → fast, original quality) into a .mov first. Passthrough can
        // CONSTRUCT fine yet FAIL at export when the source codec/track layout can't remux into a QuickTime
        // container (e.g. some HEVC/HDR / multi-track captures) — so on failure, re-encode to a .mp4 (a
        // HighestQuality re-encode produces a compatible file), instead of silently giving up.
        if let url = await export(avAsset, preset: AVAssetExportPresetPassthrough, fileType: .mov) { return url }
        return await export(avAsset, preset: AVAssetExportPresetHighestQuality, fileType: .mp4)
    }

    /// Render the clip's kept range with its HR tile + title burned in (prompt 160 · style 163) to a temp `.mp4`,
    /// or nil on failure. One clip, native orientation + resolution — the share looks like the poster.
    static func exportWithHeartRate(_ plan: ClipSharePlan.Plan) async -> URL? {
        guard let avAsset = await videoAsset(localIdentifier: plan.localIdentifier),
              let srcVideo = try? await avAsset.loadTracks(withMediaType: .video).first,
              let assetDuration = try? await avAsset.load(.duration).seconds,
              let plan = ClipSharePlan.clamped(plan, assetDuration: assetDuration) else { return nil }

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: plan.start, preferredTimescale: 600),
                                duration: CMTime(seconds: plan.duration, preferredTimescale: 600))
        guard let vTrack = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? vTrack.insertTimeRange(range, of: srcVideo, at: .zero)) != nil else { return nil }
        // Audio only when the source has some — an EMPTY audio track fails the re-encode on device
        // (-11838 / -16976; the ReelExporter + StudioComposer lesson).
        if let srcAudio = try? await avAsset.loadTracks(withMediaType: .audio).first {
            let aTrack = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
            try? aTrack?.insertTimeRange(range, of: srcAudio, at: .zero)
        }

        #if targetEnvironment(simulator)
        // The simulator has no H.264 encoder (see ReelExporter.export) — passthrough, no overlay.
        return await export(composition, preset: AVAssetExportPresetPassthrough, fileType: .mp4)
        #else
        let natural = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1080, height: 1920)
        let transform = (try? await srcVideo.load(.preferredTransform)) ?? .identity
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let canvas = CGSize(width: (abs(oriented.width) / 2).rounded() * 2,
                            height: (abs(oriented.height) / 2).rounded() * 2)
        guard canvas.width >= 2, canvas.height >= 2,
              // From the composition's properties, NOT a bare init — a bare AVMutableVideoComposition
              // fails the device re-encode (-11838 / -16976; ReelExporter.makeVideoComposition).
              let vc = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        else { return nil }
        vc.renderSize = canvas
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        vc.instructions = [instruction]

        // Tile + title where the POST draws them (prompt 163): the design's poster size/alignment at the
        // style's edge, the title stacked beside it like the poster's VStack — one set of rules
        // (`ClipOverlayStyle.placed` / `titleOrigin`), scaled to the video's width.
        var hr = plan.hr
        hr.tile = hr.tile.map { ClipOverlayStyle.placed($0, edge: plan.style.hrEdge, canvas: canvas) }
        let tileHeight = hr.tile.map { CGFloat($0.height) * canvas.height }
        let titleLayers = plan.title.map { titleLayer($0, style: plan.style, canvas: canvas, tileHeight: tileHeight) }
        vc.animationTool = StudioOverlays.makeAnimationTool(
            overlays: [], canvas: canvas, totalDuration: composition.duration.seconds,
            clipHR: [hr], extraLayers: titleLayers.map { [$0] } ?? [])
        return await export(composition, preset: AVAssetExportPresetHighestQuality, fileType: .mp4,
                            videoComposition: vc)
        #endif
    }

    /// The title block as Core Animation layers — the export twin of `ClipOverlayChrome.titleView`: big
    /// line, small line, the attempt chip (chip look), on a dark rounded chip or as shadowed plain text.
    /// Sizes scale with the video width exactly as the poster's do with the card width. Bottom-left
    /// layer space (the animation tool's).
    private static func titleLayer(_ title: ClipOverlayStyle.TitleText, style: ClipOverlayStyle,
                                   canvas: CGSize, tileHeight: CGFloat?) -> CALayer {
        let k = canvas.width / ClipOverlayStyle.referenceWidth
        let maxW = canvas.width * (1 - 2 * ClipOverlayStyle.insetFraction)
        let pad = style.titleLook == .chip ? 10 * k : 0
        let plain = style.titleLook == .plain

        func text(_ s: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> CATextLayer {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let l = CATextLayer()
            l.string = attr; l.contentsScale = 2; l.isWrapped = false; l.truncationMode = .end
            let sz = attr.size()
            l.bounds = CGRect(x: 0, y: 0, width: min(ceil(sz.width), maxW - 2 * pad), height: ceil(sz.height))
            if plain {
                l.shadowColor = UIColor.black.cgColor; l.shadowOpacity = 0.9
                l.shadowRadius = 5 * k; l.shadowOffset = .zero
            }
            return l
        }
        // Build top-down (top-left coordinates), then flip into the tool's bottom-left space.
        var rows: [(CALayer, CGFloat)] = []          // (layer, gap above)
        rows.append((text(title.primary, size: 20 * k, weight: .heavy, color: .white), 0))
        if let s = title.secondary {
            rows.append((text(s, size: 15 * k, weight: .semibold, color: UIColor.white.withAlphaComponent(0.9)), 3 * k))
        }
        if let c = title.chip {
            let label = text(c, size: 11 * k, weight: .bold, color: .black)
            let chip = CALayer()
            chip.backgroundColor = UIColor.white.cgColor
            chip.cornerRadius = 6 * k
            chip.bounds = CGRect(x: 0, y: 0, width: label.bounds.width + 14 * k, height: label.bounds.height + 4 * k)
            label.position = CGPoint(x: chip.bounds.midX, y: chip.bounds.midY)
            chip.addSublayer(label)
            rows.append((chip, 6 * k))
        }
        let contentW = rows.map { $0.0.bounds.width }.max() ?? 0
        let contentH = rows.reduce(CGFloat(0)) { $0 + $1.0.bounds.height + $1.1 }
        let block = CGSize(width: contentW + 2 * pad, height: contentH + 2 * pad)

        let container = CALayer()
        let origin = style.titleOrigin(blockSize: block, canvas: canvas, tileHeight: tileHeight)
        container.frame = CGRect(x: origin.x, y: canvas.height - origin.y - block.height,
                                 width: block.width, height: block.height)
        if style.titleLook == .chip {
            container.backgroundColor = UIColor.black.withAlphaComponent(0.4).cgColor
            container.cornerRadius = 10 * k
        }
        var y = pad                                  // top-left y of the next row
        for (layer, gap) in rows {
            y += gap
            let h = layer.bounds.height
            layer.frame = CGRect(x: pad, y: block.height - y - h, width: layer.bounds.width, height: h)
            container.addSublayer(layer)
            y += h
        }
        return container
    }

    /// Resolve a Photos video by `localIdentifier` (iCloud download allowed), or nil.
    private static func videoAsset(localIdentifier: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let phAsset = assets.firstObject, phAsset.mediaType == .video else { return nil }

        // AVAsset isn't Sendable → box it across the continuation (mirrors StudioComposer.avAsset).
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true            // allow an iCloud-stored clip to download
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        return boxed.value
    }

    /// Run one export attempt to a fresh temp file; nil if the session can't be made or the export throws.
    private static func export(_ asset: AVAsset, preset: String, fileType: AVFileType,
                               videoComposition: AVVideoComposition? = nil) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        session.videoComposition = videoComposition
        let ext = fileType == .mp4 ? "mp4" : "mov"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-clip-\(UUID().uuidString).\(ext)")
        do { try await session.export(to: out, as: fileType) } catch { return nil }
        return out
    }

    /// Wraps a non-Sendable value so it can cross an async continuation boundary (produced + consumed once).
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
