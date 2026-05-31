import Foundation
import Photos
import HighlightEngine

/// Auto-finds the media shot DURING the workout window (the core "minimize manual
/// work" magic, #60 §A). Needs full-library read to scan by time window; the app
/// primes this with a value-first screen and falls back to a manual picker on
/// limited access.
/// Stateless → `Sendable`, so it can be called across actor boundaries.
final class PhotoLibraryService: Sendable {

    enum PhotoError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Photo access is needed to auto-find the clips you shot during your workout."
        }
    }

    /// Request access. `.authorized` enables auto-discovery; `.limited` means we must
    /// fall back to a manual picker (PHPicker) since we can't scan the whole library.
    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Current access without prompting (drives the auto-discover vs manual-pick choice).
    var currentStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Map manually-selected asset identifiers (from the `.limited` PHPicker fallback)
    /// to engine `MediaItem`s, using the same creationDate→offset mapping as auto-discovery.
    func media(forIdentifiers ids: [String], workoutStart: Date) -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var items: [MediaItem] = []
        result.enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate else { return }
            let kind: MediaItem.Kind = asset.mediaType == .video ? .video : .photo
            items.append(MediaItem(
                id: asset.localIdentifier,
                kind: kind,
                startOffset: created.timeIntervalSince(workoutStart),
                duration: kind == .video ? asset.duration : 0
            ))
        }
        return items.sorted { $0.startOffset < $1.startOffset }
    }

    /// All photos/videos whose creation date falls inside the workout window,
    /// converted to engine `MediaItem`s with offsets relative to the workout start.
    func media(in interval: DateInterval, workoutStart: Date) async throws -> [MediaItem] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotoError.denied }

        let options = PHFetchOptions()
        // device-local wall-clock window; small grace padding for clock drift (#60 §3)
        let pad: TimeInterval = 90
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            interval.start.addingTimeInterval(-pad) as NSDate,
            interval.end.addingTimeInterval(pad) as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        var items: [MediaItem] = []
        result.enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate else { return }
            let kind: MediaItem.Kind = asset.mediaType == .video ? .video : .photo
            items.append(MediaItem(
                id: asset.localIdentifier,
                kind: kind,
                startOffset: created.timeIntervalSince(workoutStart),
                duration: kind == .video ? asset.duration : 0
            ))
        }
        return items
    }
}
