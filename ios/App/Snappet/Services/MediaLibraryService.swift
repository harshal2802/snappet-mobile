import Foundation
import Photos
import AVFoundation

/// Saves a generated/edited video (the B3 edited clip or the B4 highlight reel) into the user's
/// **own** Photos library — entirely on-device (B5, RESEARCH §3.6). This is the "download" half of
/// "every generated video could be sharable or downloadable to local/Photos"; sharing goes through
/// the shared `ShareSheet` (`UIActivityViewController`).
///
/// Defaults to **add-only** authorization (`PHAccessLevel.addOnly`) — the narrowest grant that lets the
/// app write a new asset without read access to the whole library — for the pure "download" callers (reel /
/// edited-clip export) that never read the asset back. The in-app **recording** path (`saveRecording`) asks
/// for **read-write** instead, because that clip is displayed back in the app (set strip, Clips feed, Studio)
/// and every read-back path needs read access — see `saveRecording`. The save is `PHPhotoLibrary.performChanges`
/// adding the file as a `.video` resource. No bytes ever leave the device — the privacy manifest's
/// "no data collection" claim stays accurate (saving to your own library is on-device).
/// Stateless → `Sendable`, so it can be called across actor boundaries.
final class MediaLibraryService: Sendable {

    /// Wraps a non-Sendable PhotoKit value (PHAsset / editing input·output) so it can cross a
    /// continuation / `performChanges` closure boundary under Swift 6 — same pattern as `StudioComposer`.
    private struct Box<T>: @unchecked Sendable { let value: T }

    /// A mutable reference cell for carrying a value **out** of a `performChanges` change block (which can't
    /// return one). Written inside the block, read after the `await` completes (the block has finished, so
    /// there's no concurrent access) — the OUT-param sibling of `Box`.
    private final class MutableBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

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

    /// Save the video at `url` (a temp `.mp4` from `StudioComposer.export` / `ReelExporter.export`, or a
    /// fresh camera recording) into the Photos library. Requests `accessLevel` authorization first (**add-only**
    /// by default — narrowest for write-and-forget download callers; pass `.readWrite` when the saved asset must
    /// be read back, e.g. an in-app recording that's displayed afterwards); throws `SaveError.denied` if the user
    /// declines, or `SaveError.failed` if the change-block fails. Returns the created asset's `localIdentifier`
    /// (from its in-block placeholder, which matches the committed asset) so a caller can tag the new clip to a
    /// session; existing callers ignore it (`@discardableResult`). On-device only.
    @discardableResult
    func saveVideoToPhotos(_ url: URL, accessLevel: PHAccessLevel = .addOnly) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: accessLevel)
        guard status == .authorized || status == .limited else { throw SaveError.denied }

        let idBox = MutableBox<String?>(nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
                idBox.value = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw SaveError.failed(error.localizedDescription)
        }
        return idBox.value
    }

    /// Save a freshly **camera-recorded** movie at `url` into Photos and describe it as a `RecordedClip`: the
    /// saved asset id + the wall-clock instant recording began (→ a session-relative offset when the caller
    /// attaches it) + its measured duration (read from the file via `AVURLAsset`). Saving the recording
    /// immediately means the clip is preserved in the user's own library even if the set is never logged.
    ///
    /// Requests **read-write** (not add-only): the whole point is to display this clip back afterwards (the set
    /// strip, the Clips feed, the Studio editor), and every read-back path resolves the asset via
    /// `PHAsset.fetchAssets(withLocalIdentifiers:)` + `PHImageManager`, which need read access. Add-only is
    /// write-only — an add-only-only user would save the clip but then see a permanent grey placeholder. This
    /// mirrors `PhotoLibraryService`, which the rest of the media pipeline already uses.
    ///
    /// `openedAt` is when the recorder was *presented*; the recording itself only began once the user framed and
    /// tapped record. Since the recording has just finished, its true start ≈ `now − duration`, which is a more
    /// faithful session offset — floored at `openedAt` (a recording can't have begun before the recorder opened).
    /// On-device only.
    func saveRecording(at url: URL, capturedAt openedAt: Date) async throws -> RecordedClip {
        let cmDuration = try? await AVURLAsset(url: url).load(.duration)
        let durationSec = cmDuration
            .map(CMTimeGetSeconds)
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let id = try await saveVideoToPhotos(url, accessLevel: .readWrite) else {
            throw SaveError.failed("no asset id")
        }
        let startedAt = durationSec.map { max(openedAt, Date().addingTimeInterval(-$0)) } ?? openedAt
        return RecordedClip(localIdentifier: id, capturedAt: startedAt, durationSec: durationSec)
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
            // `renderedContentURL` is a path Photos already reserved on disk — copying ONTO it throws
            // "file exists". Replace its contents instead.
            try? FileManager.default.removeItem(at: output.renderedContentURL)
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
