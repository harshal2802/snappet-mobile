import Foundation
import Photos

/// Saves a generated/edited video (the B3 edited clip or the B4 highlight reel) into the user's
/// **own** Photos library — entirely on-device (B5, RESEARCH §3.6). This is the "download" half of
/// "every generated video could be sharable or downloadable to local/Photos"; sharing goes through
/// the shared `ShareSheet` (`UIActivityViewController`).
///
/// Uses **add-only** authorization (`PHAccessLevel.addOnly`) — the narrowest grant that lets the
/// app write a new asset without read access to the whole library, distinct from the read access
/// `PhotoLibraryService` requests for auto-discovery. The save is `PHPhotoLibrary.performChanges`
/// adding the file as a `.video` resource. No bytes ever leave the device — the privacy manifest's
/// "no data collection" claim stays accurate (saving to your own library is on-device).
/// Stateless → `Sendable`, so it can be called across actor boundaries.
final class MediaLibraryService: Sendable {

    /// Wraps a non-Sendable PhotoKit value (PHAsset / editing input·output) so it can cross a
    /// continuation / `performChanges` closure boundary under Swift 6 — same pattern as `VideoStudio`.
    private struct Box<T>: @unchecked Sendable { let value: T }

    enum SaveError: LocalizedError {
        case denied
        case notFound
        case notEditable
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .denied:
                return "Photos access is needed for this. You can grant it in Settings."
            case .notFound:
                return "The original video couldn't be found in your Photos library."
            case .notEditable:
                return "This video can't be edited in place (it may be shared or read-only). Try “Save a copy”."
            case .failed(let message):
                return "Photos operation failed: \(message)"
            }
        }
    }

    /// Save the video at `url` (a temp `.mp4` from `VideoStudio.export` / `ReelExporter.export`)
    /// into the Photos library. Requests **add-only** authorization first; throws `SaveError.denied`
    /// if the user declines, or `SaveError.failed` if the change-block fails. On-device only.
    func saveVideoToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }
        } catch {
            throw SaveError.failed(error.localizedDescription)
        }
    }

    /// **Overwrite in place**: replace the original Photos asset's video content with the edited
    /// render at `url`, via the Photos content-editing API (reversible — the user can "Revert to
    /// Original" in Photos). Needs **read-write** authorization (we're modifying an existing asset,
    /// not just adding). Throws `.notEditable` if the asset can't be edited (shared/read-only).
    /// The CALLER must confirm first — this is destructive to the original.
    func overwriteVideoAsset(localIdentifier: String, with url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { throw SaveError.notFound }
        guard asset.canPerform(.content) else { throw SaveError.notEditable }

        // Request the editable input, then commit a content-editing output whose rendered video is
        // our edited file. `adjustmentData` tags the edit as ours so Photos can offer Revert.
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        let inputBox: Box<PHContentEditingInput> = try await withCheckedThrowingContinuation { cont in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input { cont.resume(returning: Box(value: input)) }
                else { cont.resume(throwing: SaveError.failed(
                    (info[PHContentEditingInputErrorKey] as? Error)?.localizedDescription ?? "no editing input")) }
            }
        }
        let output = PHContentEditingOutput(contentEditingInput: inputBox.value)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "com.snappet.app.clip-edit", formatVersion: "1",
            data: Data("snappet-edit".utf8))
        do {
            try FileManager.default.copyItem(at: url, to: output.renderedContentURL)
        } catch { throw SaveError.failed(error.localizedDescription) }

        let assetBox = Box(value: asset), outputBox = Box(value: output)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetChangeRequest(for: assetBox.value)
                req.contentEditingOutput = outputBox.value
            }
        } catch { throw SaveError.failed(error.localizedDescription) }
    }

    /// **Delete from Photos**: permanently remove the assets from the user's library. iOS shows its
    /// own system confirmation as well; the CALLER should still confirm first (destructive).
    func deleteAssets(localIdentifiers: [String]) async throws {
        guard !localIdentifiers.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { throw SaveError.notFound }
        let assetsBox = Box(value: assets)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsBox.value)
            }
        } catch { throw SaveError.failed(error.localizedDescription) }
    }
}
