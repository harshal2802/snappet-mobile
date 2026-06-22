import Foundation
import Photos
import AVFoundation

// MARK: - Clips feed — share a single clip's video (prompt 87)
//
// Exports one Clips-feed clip to a temp file for the system share sheet (`ShareSheet`). The RAW clip
// (passthrough — no re-encode); the HR-overlay-burned share is the Studio's job (⋯ → Edit this clip →
// export), so this is the quick "send this clip" path. Device-only: needs the real `PHAsset`, so it
// returns nil on the simulator / for a missing or non-video asset (the caller skips the share sheet).

enum ClipShareService {

    /// Export the clip's video by Photos `localIdentifier` to a temp `.mov` for sharing, or nil on failure.
    static func exportForSharing(localIdentifier: String) async -> URL? {
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
        guard let avAsset = boxed.value else { return nil }

        // Try passthrough (no re-encode → fast, original quality) into a .mov first. Passthrough can
        // CONSTRUCT fine yet FAIL at export when the source codec/track layout can't remux into a QuickTime
        // container (e.g. some HEVC/HDR / multi-track captures) — so on failure, re-encode to a .mp4 (a
        // HighestQuality re-encode produces a compatible file), instead of silently giving up.
        if let url = await export(avAsset, preset: AVAssetExportPresetPassthrough, fileType: .mov) { return url }
        return await export(avAsset, preset: AVAssetExportPresetHighestQuality, fileType: .mp4)
    }

    /// Run one export attempt to a fresh temp file; nil if the session can't be made or the export throws.
    private static func export(_ asset: AVAsset, preset: String, fileType: AVFileType) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
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
