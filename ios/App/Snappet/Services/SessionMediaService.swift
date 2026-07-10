import Foundation
import Photos

/// Discovers the photos/videos shot **during a WorkoutTracker session** and maps them to
/// session-scoped `SessionMedia` rows (B1 of the live-workout-studio initiative).
///
/// Reuses `PhotoLibraryService`'s patterns: the same `[start, end] ± pad` capture-time
/// window, the same `.authorized`/`.limited` access handling (`.limited` can't be scanned
/// by time window → the UI falls back to the PHPicker), and the same `creationDate →
/// offset` alignment — now keyed on the `WorkoutSession` interval instead of an `HKWorkout`.
///
/// The bytes never leave Photos: a row stores only the asset `localIdentifier` + a
/// session-relative offset. Stateless → `Sendable`, callable across actor boundaries.
final class SessionMediaService: Sendable {

    /// Grace padding (seconds) around the session interval, matching `PhotoLibraryService`'s
    /// ±90 s for clock skew/drift between the recording device and the workout clock
    /// (decisions.md: ±90 s media↔window padding, reused here).
    static let padSec: TimeInterval = 90

    enum MediaError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Photo access is needed to find the photos and videos you took during this workout."
        }
    }

    // MARK: - Pure mapping (testable without Photos)

    /// A single discovered asset described in plain values — what the pure mapping produces
    /// and what `SessionMedia` rows are built from. No PhotoKit type crosses this boundary,
    /// so the mapping is unit-testable on any platform.
    struct Candidate: Equatable, Sendable {
        let localIdentifier: String
        let kind: SessionMedia.Kind
        let offsetSec: Double
        let durationSec: Double?
    }

    /// The padded `[startedAt − pad, end + pad]` window an asset's `creationDate` must fall
    /// inside to count as "shot during this workout". `end` is the session's `completedAt`
    /// (or `now` for a still-active session).
    static func window(startedAt: Date, completedAt: Date?, pad: TimeInterval = padSec) -> DateInterval {
        let end = completedAt ?? Date()
        return DateInterval(start: startedAt.addingTimeInterval(-pad),
                            end: max(end, startedAt).addingTimeInterval(pad))
    }

    /// Is `creationDate` inside the padded session window? (`±pad` boundaries are inclusive.)
    static func isInWindow(_ creationDate: Date, startedAt: Date, completedAt: Date?,
                           pad: TimeInterval = padSec) -> Bool {
        window(startedAt: startedAt, completedAt: completedAt, pad: pad).contains(creationDate)
    }

    /// Session-relative offset for an asset's `creationDate`, clamped ≥ 0 (an asset captured
    /// inside the leading pad — just before `startedAt` — pins to 0 rather than going negative).
    static func offset(of creationDate: Date, startedAt: Date) -> Double {
        max(0, creationDate.timeIntervalSince(startedAt))
    }

    /// Map raw `(localIdentifier, creationDate, isVideo, assetDuration)` tuples to `Candidate`s,
    /// keeping only those inside the window, skipping any whose `localIdentifier` is in
    /// `existingIdentifiers` (dedupe so re-running auto-discovery doesn't double-tag), sorted by
    /// offset. Pure — the in-window predicate + creationDate→offset math live here so they're
    /// tested without Photos (the prompt's "isolate the pure mapping" requirement).
    static func candidates(
        from assets: [(localIdentifier: String, creationDate: Date?, isVideo: Bool, duration: Double)],
        startedAt: Date, completedAt: Date?,
        existingIdentifiers: Set<String> = [],
        pad: TimeInterval = padSec
    ) -> [Candidate] {
        assets.compactMap { asset -> Candidate? in
            guard let created = asset.creationDate else { return nil }
            guard !existingIdentifiers.contains(asset.localIdentifier) else { return nil }
            guard isInWindow(created, startedAt: startedAt, completedAt: completedAt, pad: pad) else { return nil }
            return Candidate(
                localIdentifier: asset.localIdentifier,
                kind: asset.isVideo ? .video : .photo,
                offsetSec: offset(of: created, startedAt: startedAt),
                durationSec: asset.isVideo ? asset.duration : nil
            )
        }
        .sorted { $0.offsetSec < $1.offsetSec }
    }

    /// Map an in-session **camera recording** (`RecordedClip`, already saved to Photos) to a `Candidate`
    /// relative to `startedAt` — the same plain-value shape auto-discovery and manual picks produce, so a
    /// recorded clip attaches through the one funnel. Always `.video`; the offset clamps ≥ 0 (a clip whose
    /// recording began just before `startedAt` pins to 0). Pure (no Photos/SwiftData) → unit-tested.
    static func candidate(for clip: RecordedClip, startedAt: Date) -> Candidate {
        Candidate(localIdentifier: clip.localIdentifier,
                  kind: .video,
                  offsetSec: offset(of: clip.capturedAt, startedAt: startedAt),
                  durationSec: clip.durationSec)
    }

    // MARK: - Photos access (reuses PhotoLibraryService's value-first request)

    private let photos = PhotoLibraryService()

    /// `.authorized` enables auto-discovery; `.limited` means we can't scan the library by
    /// time window so the UI must use the PHPicker. Delegates to `PhotoLibraryService`.
    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus { await photos.requestAccess() }

    var currentStatus: PHAuthorizationStatus { photos.currentStatus }

    /// `true` when we can scan the whole library by time window (auto-discovery is possible).
    var canAutoDiscover: Bool { currentStatus == .authorized }

    // MARK: - Auto-discovery (PhotoKit I/O)

    /// Auto-discover assets whose `creationDate` ∈ the padded session window, mapped to
    /// `Candidate`s, skipping any already tagged for this session (`existingIdentifiers`).
    /// `.limited` access can only see user-picked assets — not a full-library time scan — so
    /// the caller should route `.limited` to the PHPicker instead; this throws `.denied`
    /// unless fully `.authorized`.
    func discover(startedAt: Date, completedAt: Date?,
                  existingIdentifiers: Set<String>) async throws -> [Candidate] {
        let status = photos.currentStatus
        guard status == .authorized else { throw MediaError.denied }

        let interval = Self.window(startedAt: startedAt, completedAt: completedAt)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            interval.start as NSDate, interval.end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        var raw: [(localIdentifier: String, creationDate: Date?, isVideo: Bool, duration: Double)] = []
        result.enumerateObjects { asset, _, _ in
            raw.append((asset.localIdentifier, asset.creationDate,
                        asset.mediaType == .video, asset.duration))
        }
        return Self.candidates(from: raw, startedAt: startedAt, completedAt: completedAt,
                               existingIdentifiers: existingIdentifiers)
    }

    /// A raw asset tuple (the plain-value shape `candidates(from:)` buckets) — one PhotoKit fetch over a
    /// wide interval, so the Apple Watch import can scan the whole library **once** and then bucket into
    /// per-workout windows in pure code, instead of one Photos query per workout (the unbounded first-run
    /// path could face hundreds of workouts). Throws `.denied` unless fully `.authorized` (`.limited`
    /// can't do a time-window library scan).
    func rawAssets(in interval: DateInterval) async throws
    -> [(localIdentifier: String, creationDate: Date?, isVideo: Bool, duration: Double)] {
        guard photos.currentStatus == .authorized else { throw MediaError.denied }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            interval.start as NSDate, interval.end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var raw: [(localIdentifier: String, creationDate: Date?, isVideo: Bool, duration: Double)] = []
        result.enumerateObjects { asset, _, _ in
            raw.append((asset.localIdentifier, asset.creationDate,
                        asset.mediaType == .video, asset.duration))
        }
        return raw
    }

    /// Map manually-picked asset identifiers (from the PHPicker) to `Candidate`s relative to
    /// `startedAt`. Manual picks bypass the window filter — the user chose them — but are still
    /// deduped and offset-aligned the same way. Offsets clamp ≥ 0.
    func candidates(forIdentifiers ids: [String], startedAt: Date,
                    existingIdentifiers: Set<String>) -> [Candidate] {
        let fresh = ids.filter { !existingIdentifiers.contains($0) }
        guard !fresh.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: fresh, options: nil)
        var out: [Candidate] = []
        result.enumerateObjects { asset, _, _ in
            let isVideo = asset.mediaType == .video
            out.append(Candidate(
                localIdentifier: asset.localIdentifier,
                kind: isVideo ? .video : .photo,
                offsetSec: Self.offset(of: asset.creationDate ?? startedAt, startedAt: startedAt),
                durationSec: isVideo ? asset.duration : nil))
        }
        return out.sorted { $0.offsetSec < $1.offsetSec }
    }
}
