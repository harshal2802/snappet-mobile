import Foundation
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

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Photos access is needed to update the original video. Enable full access in Settings."
            case .assetNotFound: return "Couldn't find the original video in your library."
            case .editingInputFailed: return "Photos wouldn't allow editing this video."
            case .writeFailed(let detail): return "Couldn't save to the original video: \(detail)"
            }
        }
    }

    /// Full read-write Photos access — a bake WRITES to the library; limited/add-only access can't
    /// modify an existing asset. Prompts once when undetermined.
    func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized: return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard granted == .authorized else { throw BakeError.notAuthorized }
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
        do {
            // renderedContentURL for a video expects the movie file at that URL before the change block.
            try FileManager.default.copyItem(at: renderedURL, to: output.renderedContentURL)
        } catch {
            throw BakeError.writeFailed(error.localizedDescription)
        }
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
            // Best-effort: a cancelled system dialog (or any deletion failure) must not undo the bake —
            // the new asset exists and the caller re-points regardless.
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([old] as NSArray)
            }
        }
        return newID
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
    func hasEditedRendition(localIdentifier: String) -> Bool? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }
        return PHAssetResource.assetResources(for: asset).contains { $0.type == .fullSizeVideo }
    }
}
