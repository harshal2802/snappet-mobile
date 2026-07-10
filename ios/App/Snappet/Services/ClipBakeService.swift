import Foundation
import AVFoundation
import Photos

// MARK: - Bake lane (prompt 117) — write a Studio edit INTO the Photos asset
//
// Two variants, both explicit Export-menu actions (never automatic — each bake is a full re-render):
//
// - **Save to original (revertible)**: the rendered video becomes the asset's edited RENDITION via
//   `PHContentEditingOutput`. Photos keeps the original bytes — "Revert to Original" always works —
//   which also means a trim NEVER frees space (original + rendition both persist). Every app that
//   shows the asset (this feed, Messages, Photos) sees the baked pixels.
// - **Replace original (destructive)**: the rendered video is saved as a NEW asset and the original
//   is deleted (iOS shows its own confirmation; the original sits in Recently Deleted ~30 days before
//   space frees). The caller re-points `SessionMedia`/`StudioProject` at the returned identifier
//   (`ClipBakePlan` owns that pure math).
//
// Device-only (Photos + a real asset); the Studio's export render itself comes from `StudioComposer`.

@MainActor
final class ClipBakeService {

    enum BakeError: LocalizedError {
        case notAuthorized
        case assetNotFound
        case editingInputFailed
        case writeFailed(String)
        case deletionCancelled

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Photos access is needed to update the original video. Enable access in Settings."
            case .assetNotFound: return "Couldn't find the original video in your library."
            case .editingInputFailed: return "Photos wouldn't allow editing this video."
            case .writeFailed(let detail): return "Couldn't save to the original video: \(detail)"
            case .deletionCancelled:
                return "Deletion was cancelled — nothing changed in the app. The exported copy was saved to Photos."
            }
        }
    }

    /// Read-write Photos access — a bake WRITES to the library. `.limited` passes: modifying an asset
    /// in the allowed set is permitted, and Photos fails naturally if this one isn't. Prompts once
    /// when undetermined.
    func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited: return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard granted == .authorized || granted == .limited else { throw BakeError.notAuthorized }
        default:
            throw BakeError.notAuthorized
        }
    }

    /// REVERTIBLE bake: write `renderedURL` onto the original asset as its edited rendition.
    /// `projectID` rides in the adjustment data so a future Studio session can recognize its own bake.
    func saveToOriginal(renderedURL: URL, localIdentifier: String, projectID: UUID) async throws {
        try await ensureAuthorized()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { throw BakeError.assetNotFound }

        // The editing input carries the container the output must be built from. We REPLACE the
        // rendition wholesale (our render already starts from the original bytes via the composer),
        // so prior third-party adjustment data is irrelevant — decline it and Photos hands us the
        // original-based input.
        // `PHContentEditingInput` isn't Sendable and the completion arrives on a background queue —
        // box it across the continuation (the ReelExporter/ClipMediaSurface pattern).
        let inputBox: Box<PHContentEditingInput> = try await withCheckedThrowingContinuation { cont in
            let options = PHContentEditingInputRequestOptions()
            options.canHandleAdjustmentData = { _ in false }
            // An iCloud-evicted original (Optimize iPhone Storage) needs a download to edit — allowed:
            // a bake is an explicit user action already behind a progress overlay.
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input { cont.resume(returning: Box(input)) }
                else { cont.resume(throwing: BakeError.editingInputFailed) }
            }
        }
        let input = inputBox.value
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.snappet.app.bake",
                                                 formatVersion: "1",
                                                 data: Data(projectID.uuidString.utf8))
        // Photos vends `renderedContentURL` with the container IT expects (.mov for video) and
        // validates the rendition on commit — a byte copy of the composer's .mp4 can be rejected.
        // Passthrough-remux into the vended URL: no re-encode, just the right container.
        try await remux(renderedURL, to: output.renderedContentURL)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.contentEditingOutput = output
            }
        } catch {
            throw BakeError.writeFailed(error.localizedDescription)
        }
    }

    /// DESTRUCTIVE bake: save `renderedURL` as a NEW asset, delete the original (iOS confirms), and
    /// return the new asset's `localIdentifier` for the caller's re-pointing transaction. The deletion
    /// runs in a SECOND change block: if the user cancels the system dialog, the new asset survives
    /// and the caller still re-points to it (the original just lingers in the library).
    func replaceOriginal(renderedURL: URL, oldLocalIdentifier: String) async throws -> String {
        try await ensureAuthorized()
        var placeholderID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: renderedURL)
                placeholderID = creation?.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw BakeError.writeFailed(error.localizedDescription)
        }
        guard let newID = placeholderID else { throw BakeError.writeFailed("no asset was created") }

        if let old = PHAsset.fetchAssets(withLocalIdentifiers: [oldLocalIdentifier], options: nil).firstObject {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([old] as NSArray)
                }
            } catch {
                // Cancelled system dialog (or deletion failure): the app's records must stay on the
                // ORIGINAL — re-pointing while the original survives would let auto-discovery
                // re-import it as a duplicate row. The rendered copy stays in Photos as a normal
                // saved video (harmless); the caller surfaces `deletionCancelled` and changes nothing.
                throw BakeError.deletionCancelled
            }
        }
        return newID
    }

    /// Passthrough-remux `source` into `destination`, honouring the destination's container (Photos
    /// vends `.mov` for video renditions). No re-encode — track-level copy, seconds not minutes.
    private func remux(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw BakeError.writeFailed("couldn't prepare the rendition") }
        do {
            try? FileManager.default.removeItem(at: destination)
            try await session.export(to: destination, as: .mov)
        } catch {
            throw BakeError.writeFailed(error.localizedDescription)
        }
    }

    /// Wraps a non-Sendable value so it can cross an async continuation boundary (produced + consumed
    /// once — the ReelExporter/ClipMediaSurface pattern).
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Whether the asset currently carries an edited rendition — the revert-detection probe: a baked
    /// asset the user "Revert to Original"-ed in Photos loses its `fullSizeVideo` resource, and the
    /// caller clears `SessionMedia.isBaked`. Returns `nil` when the asset can't be found (don't clear
    /// a flag on a transient miss — e.g. the simulator, or iCloud eviction).
    ///
    /// Deliberately loose: ANY edited rendition counts as "still baked" — a user who reverts and then
    /// edits the video IN PHOTOS keeps the flag (the feed then shows their Photos edit with no live
    /// overlay, which is the right degrade). Verifying the rendition is OURS needs a full
    /// `requestContentEditingInput` round-trip per probe (network for iCloud originals) — not worth it
    /// at Studio-open frequency; the adjustment-data check is a follow-up if this ever confuses.
    /// `nonisolated static`: PHAsset fetches + resource enumeration are thread-safe, and the caller
    /// probes from a background task.
    nonisolated static func hasEditedRendition(localIdentifier: String) -> Bool? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }
        return PHAssetResource.assetResources(for: asset).contains { $0.type == .fullSizeVideo }
    }
}
