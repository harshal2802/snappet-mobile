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

    /// What one pass found. `missing` is only meaningful when `libraryVisible` (full Photos access).
    struct Report: Equatable, Sendable {
        var summary = MediaLinkPlanner.Summary()
        var missing: [MissingClip] = []
        var libraryVisible = false
    }

    @discardableResult
    func reconcile(context: ModelContext) async -> Report {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return .init() }
        guard let media = try? context.fetch(FetchDescriptor<SessionMedia>()), !media.isEmpty else {
            return Report(libraryVisible: true)
        }

        let sessions = Self.sessions(in: context)
        let rows = media.map { Self.row(for: $0, sessionStart: sessions[$0.sessionID]?.start) }

        let library = await Task.detached(priority: .utility) { Self.scan(rows: rows) }.value
        let actions = MediaLinkPlanner.plan(rows: rows, library: library)

        var wrote = false
        var missingIDs = Set<UUID>()
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
                // A fingerprint match is a DIFFERENT asset (a duplicate / re-import): the old cloud
                // identifier names the dead one, so drop it and let the next pass map the new asset.
                if route == .fingerprint { item.cloudIdentifier = nil }
                wrote = true
            case .missing:
                missingIDs.insert(item.id)   // surfaced by the feed + the "Find missing clips" sheet
            }
        }
        if wrote { try? context.save() }

        let summary = MediaLinkPlanner.summary(of: actions)
        if !actions.isEmpty {
            mediaLinkLog.info("media links: stamped \(summary.stamped), re-linked \(summary.relinked), missing \(summary.missing)")
        }
        let missing = media.filter { missingIDs.contains($0.id) && !$0.isDeleted }
            .map { Self.missingClip(for: $0, session: sessions[$0.sessionID]) }
        return Report(summary: summary, missing: Self.sorted(missing), libraryVisible: true)
    }

    // MARK: - Manual relink (prompt 266)

    /// Attach hand-picked library assets to the clips that are missing. Every pick is verified
    /// against the missing clip's fingerprint by the pure `MediaRelinkPlanner`; nothing is attached
    /// on a guess. Needs full Photos access (a picked identifier must resolve to be fingerprinted).
    func attach(pickedIdentifiers: [String], context: ModelContext) async -> MediaRelinkPlanner.Result {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized, !pickedIdentifiers.isEmpty,
              let media = try? context.fetch(FetchDescriptor<SessionMedia>()), !media.isEmpty else { return .init() }
        let sessions = Self.sessions(in: context)
        let rows = media.map { Self.row(for: $0, sessionStart: sessions[$0.sessionID]?.start) }

        let looked = await Task.detached(priority: .userInitiated) {
            Self.lookUp(picked: pickedIdentifiers, rows: rows)
        }.value
        let missing = MediaLinkPlanner.deadRows(rows, present: looked.present)
        let result = MediaRelinkPlanner.assign(missing: missing, picks: looked.picks, owned: looked.present)

        let fingerprints = Dictionary(looked.picks.map { ($0.localIdentifier, $0.fingerprint) },
                                      uniquingKeysWith: { first, _ in first })
        var wrote = false
        for item in media {
            guard !item.isDeleted, let local = result.relinks[item.id] else { continue }
            item.localIdentifier = local
            item.cloudIdentifier = nil                    // mapped again on the next pass
            item.linkFingerprint = fingerprints[local]
            wrote = true
        }
        if wrote { try? context.save() }
        mediaLinkLog.info("manual relink: attached \(result.attachedRowCount), unmatched picks \(result.unmatchedPickCount)")
        return result
    }

    /// Which row identifiers still resolve, and the fingerprints of the picked assets.
    nonisolated private static func lookUp(picked: [String], rows: [MediaLinkRow])
        -> (present: Set<String>, picks: [MediaLinkCandidate]) {
        var present = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(rows.map(\.localIdentifier))), options: nil)
            .enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        var picks: [MediaLinkCandidate] = []
        PHAsset.fetchAssets(withLocalIdentifiers: picked, options: nil).enumerateObjects { asset, _, _ in
            guard let fingerprint = makeFingerprint(of: asset) else { return }
            picks.append(MediaLinkCandidate(localIdentifier: asset.localIdentifier, fingerprint: fingerprint))
        }
        return (present, picks)
    }

    // MARK: - Store → plain values

    /// `sessionID` can point at a gym `WorkoutSession` or a `KilterSession` (both key clips by id).
    private static func sessions(in context: ModelContext) -> [UUID: (start: Date, title: String)] {
        var out: [UUID: (start: Date, title: String)] = [:]
        for session in (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? [] {
            out[session.id] = (session.startedAt, session.routineName)
        }
        for session in (try? context.fetch(FetchDescriptor<KilterSession>())) ?? [] {
            out[session.id] = (session.startedAt, "Kilter Board")
        }
        return out
    }

    private static func missingClip(for media: SessionMedia,
                                    session: (start: Date, title: String)?) -> MissingClip {
        // Same rule as `row(for:)`: a clamped offset of 0 hides the true capture instant.
        let derived = (session != nil && media.offsetSec > 0)
            ? session?.start.addingTimeInterval(media.offsetSec) : nil
        return MissingClip(id: media.id, localIdentifier: media.localIdentifier,
                           isVideo: media.kind == .video,
                           capturedAt: media.linkCapturedAt ?? derived ?? session?.start,
                           durationSec: media.kind == .video ? (media.linkDurationSec ?? media.durationSec) : nil,
                           sessionTitle: session?.title)
    }

    /// UI-test hook (`-uiTestAssumeMissingClips`): the simulator cannot hold Photos access under
    /// test, so no pass ever runs there. This reports EVERY clip in the store as missing so the
    /// notice + sheet are reachable. Read-only; never called without the launch argument.
    static let assumeMissingArgument = "-uiTestAssumeMissingClips"
    static func assumeAllMissing(in context: ModelContext) -> [MissingClip] {
        let sessions = sessions(in: context)
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []
        return sorted(media.map { missingClip(for: $0, session: sessions[$0.sessionID]) })
    }

    /// Newest first; undated clips last; stable by id.
    private static func sorted(_ clips: [MissingClip]) -> [MissingClip] {
        clips.sorted {
            switch ($0.capturedAt, $1.capturedAt) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id.uuidString < $1.id.uuidString
            }
        }
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
