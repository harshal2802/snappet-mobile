import Foundation

// MARK: - Media link resilience (cloud-connect P1, prompt 265) — the PURE core
//
// A `SessionMedia` row points at its bytes with a PHAsset `localIdentifier`, which is only valid on
// ONE device's Photos library and dies when the asset is deleted (Google Photos "Free up space"),
// re-imported, or the store is restored onto a new phone. This file is the decision core that keeps
// those links alive — no Photos / SwiftData / UIKit imports, so it runs in `SnappetTests` on any
// machine. The PhotoKit edge is `Services/MediaLinkService.swift`.
//
// Two durable handles are stamped on a row WHILE its asset still resolves:
//   • `cloudIdentifier` — PhotoKit's cross-device id (iCloud Photos); the exact route back.
//   • a `MediaFingerprint` — capture instant + kind + duration + pixel size + original filename;
//     the fuzzy route back when there is no cloud id (iCloud Photos off, re-downloaded copy).
// When the `localIdentifier` later stops resolving, `MediaLinkPlanner` re-links through the cloud
// id first, then through a UNIQUE fingerprint match, and otherwise leaves the row alone (the feed
// shows "Not on this phone"). It never guesses: an ambiguous match is no match.

/// What we remember about an asset so we can recognise it again under a different identifier.
struct MediaFingerprint: Equatable, Hashable, Sendable {
    /// The asset's `creationDate` (the capture instant — identical across libraries/clouds).
    var capturedAt: Date
    var isVideo: Bool
    /// Video duration in seconds; `nil` for photos / unknown.
    var durationSec: Double?
    /// Stored (un-oriented) pixel size; `nil` when unknown.
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// e.g. `IMG_1234.MOV` — survives Google Photos / AirDrop round trips; `nil` when unknown.
    var originalFilename: String?
}

/// A library asset that might be the new home of a dead link.
struct MediaLinkCandidate: Equatable, Sendable {
    let localIdentifier: String
    let fingerprint: MediaFingerprint
}

/// Pure fingerprint comparison. Conservative by design — a wrong re-link silently shows the wrong
/// clip under someone's heart-rate overlay, which is worse than an honest "Not on this phone".
enum MediaLinkMatcher {
    /// Capture instants must agree within this (sub-second precision differs between a stored
    /// `Date` and a re-imported asset's metadata; 2 s also absorbs the clamped-offset fallback).
    static let captureToleranceSec: TimeInterval = 2
    /// Durations must agree within this when both are known (container re-mux rounding).
    static let durationToleranceSec: Double = 0.5

    /// How well `have` matches `want`; `nil` = cannot be the same asset. Higher is better.
    static func score(want: MediaFingerprint, have: MediaFingerprint) -> Int? {
        guard want.isVideo == have.isVideo else { return nil }
        guard abs(want.capturedAt.timeIntervalSince(have.capturedAt)) <= captureToleranceSec else { return nil }
        var score = 1
        if want.isVideo, let a = want.durationSec, let b = have.durationSec {
            guard abs(a - b) <= durationToleranceSec else { return nil }
            score += 1
        }
        if let ww = want.pixelWidth, let wh = want.pixelHeight,
           let hw = have.pixelWidth, let hh = have.pixelHeight {
            // Either orientation: a re-export can bake the rotation into the pixel dims.
            guard (ww == hw && wh == hh) || (ww == hh && wh == hw) else { return nil }
            score += 1
        }
        if let a = want.originalFilename, let b = have.originalFilename,
           a.caseInsensitiveCompare(b) == .orderedSame {
            score += 2
        }
        return score
    }

    /// The single best candidate for `want`, skipping identifiers in `excluding` (already owned by
    /// another row). Returns `nil` when nothing qualifies OR when the top score is shared by two
    /// different assets (e.g. burst photos) — ambiguity is never resolved by guessing.
    static func bestMatch(for want: MediaFingerprint, among candidates: [MediaLinkCandidate],
                          excluding: Set<String> = []) -> String? {
        var best: (id: String, score: Int)?
        var tied = false
        for candidate in candidates where !excluding.contains(candidate.localIdentifier) {
            guard let s = score(want: want, have: candidate.fingerprint) else { continue }
            if let current = best {
                if s > current.score { best = (candidate.localIdentifier, s); tied = false }
                else if s == current.score, candidate.localIdentifier != current.id { tied = true }
            } else {
                best = (candidate.localIdentifier, s)
            }
        }
        return tied ? nil : best?.id
    }
}

/// A `SessionMedia` row reduced to the plain values the planner needs.
struct MediaLinkRow: Equatable, Sendable {
    let id: UUID
    let localIdentifier: String
    /// The stamped PhotoKit cloud identifier (`PHCloudIdentifier.stringValue`), if any.
    let cloudIdentifier: String?
    /// The stamped fingerprint, if the row was ever seen while its asset resolved.
    let fingerprint: MediaFingerprint?
    /// A weaker fingerprint derived from `session.startedAt + offsetSec` for rows that were never
    /// stamped (restored from an older backup). `nil` when the session is unknown or the offset
    /// was clamped to 0 (the true capture instant is then unknowable).
    let fallbackFingerprint: MediaFingerprint?
}

/// What the PhotoKit edge learned about the library, as plain values.
struct MediaLibrarySnapshot: Equatable, Sendable {
    /// Every row `localIdentifier` that still resolves → the asset's current fingerprint.
    var present: [String: MediaFingerprint] = [:]
    /// Row identifiers that resolve but cannot be fingerprinted (no creation date): alive, so
    /// never re-linked or reported missing, and never stamped.
    var unstampable: Set<String> = []
    /// local → cloud identifier, for the `present` assets PhotoKit could map.
    var cloudIdentifiers: [String: String] = [:]
    /// cloud → CURRENT local identifier, for the cloud ids stamped on dead rows.
    var localForCloud: [String: String] = [:]
    /// Assets captured near the dead rows' capture instants (the fingerprint search pool).
    var candidates: [MediaLinkCandidate] = []
}

/// One row's outcome. `.stamp` / `.relink` are the only cases that write to the store.
enum MediaLinkAction: Equatable, Sendable {
    /// The link is alive; record these durable handles (only emitted when they changed).
    case stamp(cloudIdentifier: String?, fingerprint: MediaFingerprint)
    /// The link was dead; point the row at this asset instead.
    case relink(localIdentifier: String, via: Route)
    /// The link is dead and nothing in the library matches.
    case missing

    enum Route: String, Equatable, Sendable { case cloudIdentifier, fingerprint }
}

enum MediaLinkPlanner {
    /// Rows whose `localIdentifier` no longer resolves.
    static func deadRows(_ rows: [MediaLinkRow], present: Set<String>) -> [MediaLinkRow] {
        rows.filter { !present.contains($0.localIdentifier) }
    }

    /// The fingerprint a dead row is searched by: the stamped one, else the weaker fallback.
    static func searchFingerprint(for row: MediaLinkRow) -> MediaFingerprint? {
        row.fingerprint ?? row.fallbackFingerprint
    }

    /// The capture-time windows the edge should fetch candidates for — one padded interval per
    /// searchable dead row, merged when they overlap so the edge runs few Photos queries.
    static func searchWindows(for dead: [MediaLinkRow],
                              pad: TimeInterval = MediaLinkMatcher.captureToleranceSec) -> [DateInterval] {
        let sorted = dead.compactMap { searchFingerprint(for: $0)?.capturedAt }.sorted()
        var out: [DateInterval] = []
        for instant in sorted {
            let next = DateInterval(start: instant.addingTimeInterval(-pad), end: instant.addingTimeInterval(pad))
            if let last = out.last, next.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, next.end))
            } else {
                out.append(next)
            }
        }
        return out
    }

    /// Decide every row's outcome. Rows with nothing to do are absent from the result.
    /// Deterministic: rows are processed in `id` order so the same inputs give the same links.
    static func plan(rows: [MediaLinkRow], library: MediaLibrarySnapshot) -> [UUID: MediaLinkAction] {
        var actions: [UUID: MediaLinkAction] = [:]
        // An asset already owned by a live row is never handed to a dead one.
        var claimed = Set(rows.map(\.localIdentifier).filter { library.present[$0] != nil })
            .union(library.unstampable)
        // One answer per dead identifier: the same physical asset can legitimately be filed in two
        // sessions (two rows, one `localIdentifier`), and both rows must land on the same asset.
        var resolved: [String: (local: String, route: MediaLinkAction.Route)] = [:]

        let ordered = rows.sorted { $0.id.uuidString < $1.id.uuidString }
        for row in ordered {
            if library.unstampable.contains(row.localIdentifier) { continue }
            if let current = library.present[row.localIdentifier] {
                // Keep an existing cloud id when PhotoKit can't map this time (iCloud signed out).
                let cloud = library.cloudIdentifiers[row.localIdentifier] ?? row.cloudIdentifier
                if cloud != row.cloudIdentifier || current != row.fingerprint {
                    actions[row.id] = .stamp(cloudIdentifier: cloud, fingerprint: current)
                }
                continue
            }
            if let known = resolved[row.localIdentifier] {
                actions[row.id] = .relink(localIdentifier: known.local, via: known.route)
                continue
            }
            var found: (local: String, route: MediaLinkAction.Route)?
            if let cloud = row.cloudIdentifier, let local = library.localForCloud[cloud],
               !claimed.contains(local) {
                found = (local: local, route: MediaLinkAction.Route.cloudIdentifier)
            } else if let want = searchFingerprint(for: row),
                      let local = MediaLinkMatcher.bestMatch(for: want, among: library.candidates,
                                                             excluding: claimed) {
                found = (local: local, route: MediaLinkAction.Route.fingerprint)
            }
            if let found {
                claimed.insert(found.local)
                resolved[row.localIdentifier] = found
                actions[row.id] = .relink(localIdentifier: found.local, via: found.route)
            } else {
                actions[row.id] = .missing
            }
        }
        return actions
    }

    /// Tally for logging / the future "N clips aren't on this phone" summary.
    struct Summary: Equatable, Sendable {
        var stamped = 0
        var relinked = 0
        var missing = 0
    }

    static func summary(of actions: [UUID: MediaLinkAction]) -> Summary {
        var s = Summary()
        for action in actions.values {
            switch action {
            case .stamp: s.stamped += 1
            case .relink: s.relinked += 1
            case .missing: s.missing += 1
            }
        }
        return s
    }
}
