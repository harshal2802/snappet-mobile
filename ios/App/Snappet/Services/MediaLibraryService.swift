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

    enum SaveError: LocalizedError {
        case denied
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .denied:
                return "Photos access is needed to save this video to your library. You can grant it in Settings."
            case .failed(let message):
                return "Couldn't save the video to Photos: \(message)"
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
}
