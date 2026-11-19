import Foundation
import OSLog
import Photos
import SwiftData

private let mediaLinkLog = Logger(subsystem: "com.snappet.app", category: "MediaLink")

/// The PhotoKit edge of media link resilience (cloud-connect P1, prompt 265). The decisions live in
/// the pure `MediaLinkPlanner` (`Features/WorkoutTracker/MediaLink.swift`); this type only gathers a
/// `MediaLibrarySnapshot` from Photos and writes the planner's actions back to the store.
///
/// One pass, safe to repeat (idempotent — a settled store produces no writes):
///   1. **Stamp** — every `SessionMedia` whose asset still resolves gets its cross-device
///      `cloudIdentifier` and a fingerprint, so the link can be rebuilt later.
///   2. **Re-link** — every row whose `localIdentifier` is dead is pointed back at its asset via
///      the cloud identifier, else a unique fingerprint match.
///
/// Nothing leaves the phone: these are Photos-library lookups, not network calls of ours.
/// Runs ONLY with full `.authorized` access and never prompts — under `.limited` an unresolvable id
/// may simply be an asset the user has not shared, which must not be treated as missing.
@MainActor
struct MediaLinkService {

    @discardableResult
    func reconcile(context: ModelContext) async -> MediaLinkPlanner.Summary {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return .init() }
        guard let media = try? context.fetch(FetchDescriptor<SessionMedia>()), !media.isEmpty else { return .init() }

        let starts = Self.sessionStarts(in: context)
        let rows = media.map { Self.row(for: $0, sessionStart: starts[$0.sessionID]) }

        let library = await Task.detached(priority: .utility) { Self.scan(rows: rows) }.value
        let actions = MediaLinkPlanner.plan(rows: rows, library: library)
        guard !actions.isEmpty else { return .init() }

        var wrote = false
        for item in media {
            // The row may have been deleted while the scan ran off-main.
            guard !item.isDeleted, let action = actions[item.id] else { continue }
            switch action {
            case let .stamp(cloudIdentifier, fingerprint):
                item.cloudIdentifier = cloudIdentifier
                item.linkFingerprint = fingerprint
                wrote = true
            case let .relink(localIdentifier, route):
                mediaLinkLog.info("re-linked a clip via \(route.rawValue, privacy: .public)")
                item.localIdentifier = localIdentifier
                wrote = true
            case .missing:
                break   // surfaced by the feed's "Not on this phone" placeholder; nothing to store yet
            }
        }
        if wrote { try? context.save() }

        let summary = MediaLinkPlanner.summary(of: actions)
        mediaLinkLog.info("media links: stamped \(summary.stamped), re-linked \(summary.relinked), missing \(summary.missing)")
        return summary
    }

    // MARK: - Store → plain values

    /// `sessionID` can point at a gym `WorkoutSession` or a `KilterSession` (both key clips by id).
    private static func sessionStarts(in context: ModelContext) -> [UUID: Date] {
        var out: [UUID: Date] = [:]
        for session in (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? [] {
            out[session.id] = session.startedAt
        }
        for session in (try? context.fetch(FetchDescriptor<KilterSession>())) ?? [] {
            out[session.id] = session.startedAt
        }
        return out
    }

    private static func row(for media: SessionMedia, sessionStart: Date?) -> MediaLinkRow {
        // `offsetSec` is clamped ≥ 0, so an offset of exactly 0 may hide a capture inside the leading
        // pad — the true instant is unknowable and a fallback would mis-search. Skip it.
        var fallback: MediaFingerprint?
        if let sessionStart, media.offsetSec > 0 {
            fallback = MediaFingerprint(capturedAt: sessionStart.addingTimeInterval(media.offsetSec),
                                        isVideo: media.kind == .video,
                                        durationSec: media.kind == .video ? media.durationSec : nil,
                                        pixelWidth: nil, pixelHeight: nil, originalFilename: nil)
        }
        return MediaLinkRow(id: media.id, localIdentifier: media.localIdentifier,
                            cloudIdentifier: media.cloudIdentifier,
                            fingerprint: media.linkFingerprint, fallbackFingerprint: fallback)
    }

    // MARK: - PhotoKit scan (synchronous library queries → called off the main actor)

    nonisolated private static func scan(rows: [MediaLinkRow]) -> MediaLibrarySnapshot {
        var snapshot = MediaLibrarySnapshot()

        // Already-stamped rows keep their stored fingerprint (no per-asset resource query, no
        // re-stamp churn); only never-stamped identifiers are fingerprinted from the live asset.
        var stored: [String: MediaFingerprint] = [:]
        var needsFingerprint = Set<String>()
        var needsCloud = Set<String>()
        for row in rows {
            if let fingerprint = row.fingerprint { stored[row.localIdentifier] = fingerprint }
            else { needsFingerprint.insert(row.localIdentifier) }
            if row.cloudIdentifier == nil { needsCloud.insert(row.localIdentifier) }
        }

        let identifiers = Array(Set(rows.map(\.localIdentifier)))
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var present: [String: MediaFingerprint] = [:]
        var unstampable = Set<String>()
        fetched.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            if needsFingerprint.contains(id), let live = makeFingerprint(of: asset) {
                present[id] = live
            } else if let kept = stored[id] {
                present[id] = kept
            } else {
                unstampable.insert(id)   // resolves, but has no creation date to fingerprint
            }
        }
        snapshot.present = present
        snapshot.unstampable = unstampable

        // local → cloud, for live rows that have no cloud id yet.
        let toMap = needsCloud.filter { present[$0] != nil }
        if !toMap.isEmpty {
            let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: Array(toMap))
            for (local, result) in mappings {
                if case let .success(cloud) = result { snapshot.cloudIdentifiers[local] = cloud.stringValue }
            }
        }

        // cloud → local, for dead rows that were stamped on another device / before a re-import.
        let dead = MediaLinkPlanner.deadRows(rows, present: Set(present.keys).union(unstampable))
        let deadCloud = Set(dead.compactMap(\.cloudIdentifier))
        if !deadCloud.isEmpty {
            let mappings = PHPhotoLibrary.shared()
                .localIdentifierMappings(for: deadCloud.map { PHCloudIdentifier(stringValue: $0) })
            for (cloud, result) in mappings {
                if case let .success(local) = result { snapshot.localForCloud[cloud.stringValue] = local }
            }
        }

        // Fingerprint search pool: assets captured at the dead rows' capture instants.
        for window in MediaLinkPlanner.searchWindows(for: dead) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                            window.start as NSDate, window.end as NSDate)
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                guard let fingerprint = makeFingerprint(of: asset) else { return }
                snapshot.candidates.append(MediaLinkCandidate(localIdentifier: asset.localIdentifier,
                                                              fingerprint: fingerprint))
            }
        }
        return snapshot
    }

    nonisolated private static func makeFingerprint(of asset: PHAsset) -> MediaFingerprint? {
        guard let created = asset.creationDate else { return nil }
        let isVideo = asset.mediaType == .video
        return MediaFingerprint(capturedAt: created, isVideo: isVideo,
                                durationSec: isVideo ? asset.duration : nil,
                                pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                originalFilename: PHAssetResource.assetResources(for: asset).first?.originalFilename)
    }
}
