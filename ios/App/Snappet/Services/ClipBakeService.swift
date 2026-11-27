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

/// What Photos says about a baked asset (revert detection). A value only so the view model's
/// revert handling can be tested with a stand-in (prompt 305).
struct BakedAssetProbe: Sendable {
    /// `ClipBakeService.hasEditedRendition`: `false` = reverted, `nil` = the asset was not found.
    var hasEditedRendition: Bool?
    /// `ClipBakeService.currentDuration`: the length of the video the asset plays now.
    var currentDuration: Double?
}

/// The two Photos writes of a bake. A protocol only so the view model's bake can be tested with a
/// stand-in (prompt 303): the real writes need a device and a real asset.
@MainActor
protocol ClipBaking {
    func saveToOriginal(renderedURL: URL, localIdentifier: String, projectID: UUID) async throws
    func replaceOriginal(renderedURL: URL, oldLocalIdentifier: String) async throws -> String
}

@MainActor
final class ClipBakeService: ClipBaking {

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
        // A test launch bakes only into an asset it made (prompt 320).
        guard TestLaunchAssets.mayChange([localIdentifier]) else { throw BakeError.writeFailed("not this test's clip") }
        try await ensureAuthorized()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { throw BakeError.assetNotFound }

        // The editing input carries the container the output must be built from. We REPLACE the
        // rendition wholesale (our render already starts from the original bytes via the composer),
        // so prior third-party adjustment data is irrelevant — decline it and Photos hands us the
        // original-based input.
        let input = try await Self.editingInput(for: asset).value
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.snappet.app.bake",
                                                 formatVersion: "1",
                                                 data: Data(projectID.uuidString.utf8))
        // Photos vends `renderedContentURL` with the container IT expects (.mov for video) and
        // validates the rendition on commit — a byte copy of the composer's .mp4 can be rejected.
        // Passthrough-remux into the vended URL: no re-encode, just the right container.
        try await remux(renderedURL, to: output.renderedContentURL)
        do {
            try await PHPhotoLibrary.shared().performChanges(PhotosChange.setRendition(output, on: asset))
        } catch {
            throw BakeError.writeFailed(error.localizedDescription)
        }
    }

    /// DESTRUCTIVE bake: save `renderedURL` as a NEW asset, delete the original (iOS confirms), and
    /// return the new asset's `localIdentifier` for the caller's re-pointing transaction. The deletion
    /// runs in a SECOND change block: if the user cancels the system dialog, the new asset survives
    /// and the caller still re-points to it (the original just lingers in the library).
    func replaceOriginal(renderedURL: URL, oldLocalIdentifier: String) async throws -> String {
        // A test launch replaces (deletes) only an asset it made (prompt 320); refused before anything is created.
        guard TestLaunchAssets.mayChange([oldLocalIdentifier]) else {
            throw BakeError.writeFailed("not this test's clip")
        }
        try await ensureAuthorized()
        var placeholderID: String?
        do {
            let created = PhotosChange.IDBox()
            try await PHPhotoLibrary.shared().performChanges(PhotosChange.createVideo(at: renderedURL, into: created))
            placeholderID = created.value
        } catch {
            throw BakeError.writeFailed(error.localizedDescription)
        }
        guard let newID = placeholderID else { throw BakeError.writeFailed("no asset was created") }
        TestLaunchAssets.noteCreated(newID)

        if let old = PHAsset.fetchAssets(withLocalIdentifiers: [oldLocalIdentifier], options: nil).firstObject {
            do {
                try await PHPhotoLibrary.shared().performChanges(PhotosChange.deleteAssets([old]))
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

    /// The asset's editing input, requested OFF the main actor (prompt 322). The SDK's completion and
    /// `canHandleAdjustmentData` blocks aren't `@Sendable`, so closures written in this main-actor
    /// class would be main-actor closures — and Swift 6 stops the app if Photos calls one on its own
    /// queue. Built here, in a `nonisolated` function, they belong to no actor.
    /// `PHContentEditingInput` isn't Sendable — boxed across the continuation (produced + consumed once).
    nonisolated private static func editingInput(for asset: PHAsset) async throws -> Box<PHContentEditingInput> {
        try await withCheckedThrowingContinuation { cont in
            let options = PHContentEditingInputRequestOptions()
            // We REPLACE the rendition wholesale (see `saveToOriginal`): decline prior adjustment data.
            options.canHandleAdjustmentData = { _ in false }
            // An iCloud-evicted original (Optimize iPhone Storage) needs a download to edit — allowed:
            // a bake is an explicit user action already behind a progress overlay.
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input { cont.resume(returning: Box(input)) }
                else { cont.resume(throwing: BakeError.editingInputFailed) }
            }
        }
    }

    /// The bake's Photos change blocks (prompt 322). Photos runs a change block on its own queue
    /// (`com.apple.PHPhotoLibrary.transaction…`), and the SDK types it as a plain `dispatch_block_t`
    /// (not `@Sendable`). A block written inside this main-actor class was therefore a main-actor
    /// closure, and Swift 6's run-time check stopped the app the moment Photos ran it: "Save to
    /// original" and "Replace original" quit on the phone. Each block is built here, in a
    /// `nonisolated` function, typed `@Sendable`, and captures only Sendable values.
    enum PhotosChange {
        /// Carries the created asset's identifier out of a change block (written once, on Photos'
        /// queue, read after `performChanges` returns).
        final class IDBox: @unchecked Sendable { var value: String? }

        /// Revertible bake: `output` becomes `asset`'s edited rendition.
        nonisolated static func setRendition(_ output: PHContentEditingOutput,
                                             on asset: PHAsset) -> @Sendable () -> Void {
            let output = Box(output)
            return {
                let request = PHAssetChangeRequest(for: asset)
                request.contentEditingOutput = output.value
            }
        }

        /// Destructive bake, step 1: save the video at `url` as a new asset; its identifier goes to `id`.
        nonisolated static func createVideo(at url: URL, into id: IDBox) -> @Sendable () -> Void {
            {
                let creation = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                id.value = creation?.placeholderForCreatedAsset?.localIdentifier
            }
        }

        /// Destructive bake, step 2: delete the original (iOS asks the user first).
        nonisolated static func deleteAssets(_ assets: [PHAsset]) -> @Sendable () -> Void {
            { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
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

    /// The length of the video the asset plays now (its current version). `nil` when the asset
    /// can't be found. Read after a revert, when the original video is the current one again.
    nonisolated static func currentDuration(localIdentifier: String) -> Double? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject?.duration
    }
}
