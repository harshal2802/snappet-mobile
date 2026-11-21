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

// MARK: - Manual relink (cloud-connect P1b, prompt 266) — the PURE core
//
// The automatic pass above can only re-link what it can find unaided. When it can't, the person
// picks the footage themselves (system photo picker; Google's picker arrives in P4). A hand pick is
// still VERIFIED against what Snappet remembers about the clip: a pick that doesn't match a missing
// clip is reported, never silently attached — the wrong footage under someone's heart-rate overlay
// is worse than a clip that stays missing.

/// A clip whose Photos asset is gone, as the "Find missing clips" sheet lists it.
struct MissingClip: Identifiable, Equatable, Sendable {
    /// The `SessionMedia.id`.
    let id: UUID
    let localIdentifier: String
    let isVideo: Bool
    /// When it was shot, if known (stamped fingerprint, else `session.startedAt + offsetSec`).
    let capturedAt: Date?
    let durationSec: Double?
    /// The session it is filed under ("Bouldering", "Kilter Board", a festival name…).
    let sessionTitle: String?
}

/// What happened to one hand-picked asset.
enum MediaRelinkVerdict: Equatable, Sendable {
    /// Attached to these missing rows (more than one when the same clip is filed in two sessions).
    case attached(rowIDs: [UUID])
    /// Doesn't match any missing clip's capture time / kind / length.
    case noMatch
    /// Matches two different missing clips equally, or ties with another pick — not guessed.
    case ambiguous
    /// Already the footage of a clip that is not missing.
    case alreadyInUse
}

enum MediaRelinkPlanner {
    struct Result: Equatable, Sendable {
        /// missing row id → the picked asset it should now point at.
        var relinks: [UUID: String] = [:]
        /// picked asset identifier → what happened to it.
        var verdicts: [String: MediaRelinkVerdict] = [:]

        var attachedRowCount: Int { relinks.count }
        var unmatchedPickCount: Int {
            verdicts.values.filter { if case .attached = $0 { false } else { true } }.count
        }
    }

    /// Match hand-picked assets to missing rows. `owned` = identifiers already used by live rows.
    /// Deterministic (order of `missing` / `picks` does not matter).
    static func assign(missing: [MediaLinkRow], picks: [MediaLinkCandidate],
                       owned: Set<String>) -> Result {
        var result = Result()
        var usable: [MediaLinkCandidate] = []
        var seen = Set<String>()
        for pick in picks.sorted(by: { $0.localIdentifier < $1.localIdentifier })
        where seen.insert(pick.localIdentifier).inserted {
            if owned.contains(pick.localIdentifier) {
                result.verdicts[pick.localIdentifier] = .alreadyInUse
            } else {
                usable.append(pick)
            }
        }

        // One decision per dead identifier — rows sharing it are the same physical clip filed twice.
        var groups: [String: [MediaLinkRow]] = [:]
        for row in missing { groups[row.localIdentifier, default: []].append(row) }

        // Each dead identifier names its single best pick (a tie between picks is no match)…
        var claims: [String: [(dead: String, score: Int)]] = [:]
        var contested = Set<String>()
        for dead in groups.keys.sorted() {
            guard let row = groups[dead]?.min(by: { $0.id.uuidString < $1.id.uuidString }),
                  let want = MediaLinkPlanner.searchFingerprint(for: row) else { continue }
            let scored = usable.compactMap { pick in
                MediaLinkMatcher.score(want: want, have: pick.fingerprint).map { (pick.localIdentifier, $0) }
            }
            guard let top = scored.map(\.1).max() else { continue }
            let best = scored.filter { $0.1 == top }
            if best.count == 1 {
                claims[best[0].0, default: []].append((dead: dead, score: top))
            } else {
                best.forEach { contested.insert($0.0) }
            }
        }
        // …and each pick goes to the single dead identifier that wants it most (a tie is no match).
        for pick in usable {
            let id = pick.localIdentifier
            let wanted = claims[id] ?? []
            guard let top = wanted.map(\.score).max() else {
                result.verdicts[id] = contested.contains(id) ? .ambiguous : .noMatch
                continue
            }
            let winners = wanted.filter { $0.score == top }
            guard winners.count == 1, let rows = groups[winners[0].dead] else {
                result.verdicts[id] = .ambiguous
                continue
            }
            let ids = rows.map(\.id).sorted { $0.uuidString < $1.uuidString }
            ids.forEach { result.relinks[$0] = id }
            result.verdicts[id] = .attached(rowIDs: ids)
        }
        return result
    }
}

/// Pure wording + grouping for the missing-clips notice and sheet (prompt 266).
enum MissingClipsNotice {
    static func title(count: Int) -> String {
        count == 1 ? "1 clip isn’t on this phone" : "\(count.formatted()) clips aren’t on this phone"
    }

    static func sheetTitle(count: Int) -> String {
        switch count {
        case 0: "Missing clips"
        case 1: "Find 1 missing clip"
        default: "Find \(count.formatted()) missing clips"
        }
    }

    /// Show the feed notice? Dismissing remembers the count at that moment; the notice returns only
    /// when MORE clips are missing than the person already waved away.
    static func shouldShow(count: Int, dismissedAtCount: Int) -> Bool {
        count > 0 && count > dismissedAtCount
    }

    /// Clips of one session on one day.
    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let clips: [MissingClip]
    }

    /// Group by session title + calendar day, keeping the input order (newest first).
    static func groups(_ clips: [MissingClip], calendar: Calendar = .current,
                       locale: Locale = .current) -> [Group] {
        var order: [String] = []
        var buckets: [String: (title: String, clips: [MissingClip])] = [:]
        for clip in clips {
            let day = clip.capturedAt.map { calendar.startOfDay(for: $0) }
            let dayText = day.map {
                $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                                        timeZone: calendar.timeZone))
            }
            let name = clip.sessionTitle?.trimmingCharacters(in: .whitespaces)
            let title = [name?.isEmpty == false ? name : nil, dayText].compactMap { $0 }.joined(separator: " · ")
            let key = "\(name ?? "")|\(day?.timeIntervalSinceReferenceDate ?? -1)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = (title.isEmpty ? "Unknown session" : title, [])
            }
            buckets[key]?.clips.append(clip)
        }
        return order.compactMap { key in buckets[key].map { Group(id: key, title: $0.title, clips: $0.clips) } }
    }

    /// "7:31 PM · 0:14" / "7:31 PM · Photo" / "Video · 0:14" when the time is unknown.
    static func line(for clip: MissingClip, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts: [String] = []
        if let at = clip.capturedAt {
            parts.append(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                               timeZone: calendar.timeZone)))
        } else {
            parts.append(clip.isVideo ? "Video" : "Photo")
        }
        if clip.isVideo, let seconds = clip.durationSec, seconds > 0 {
            let total = Int(seconds.rounded())
            parts.append("\(total / 60):" + String(format: "%02d", total % 60))
        } else if clip.capturedAt != nil {
            parts.append(clip.isVideo ? "Video" : "Photo")
        }
        return parts.joined(separator: " · ")
    }

    /// The plain-language result of one round of picking.
    struct Outcome: Equatable, Sendable {
        let attached: Int
        let unmatched: Int

        init(attached: Int, unmatched: Int) { self.attached = attached; self.unmatched = unmatched }

        /// `picked` = how many the person chose; any that could not even be read count as unmatched.
        init(result: MediaRelinkPlanner.Result, picked: Int) {
            let matchedPicks = result.verdicts.values.filter { if case .attached = $0 { true } else { false } }.count
            self.init(attached: result.attachedRowCount, unmatched: max(0, picked - matchedPicks))
        }

        var message: String {
            let found = attached == 1 ? "1 clip found" : "\(attached) clips found"
            let missed = unmatched == 1 ? "1 pick didn’t match a missing clip"
                                        : "\(unmatched) picks didn’t match a missing clip"
            switch (attached > 0, unmatched > 0) {
            case (true, true): return "\(found) · \(missed)"
            case (true, false): return found
            case (false, true): return unmatched == 1 ? "That pick didn’t match a missing clip" : "None of those matched a missing clip"
            case (false, false): return "Nothing was picked"
            }
        }
    }
}
