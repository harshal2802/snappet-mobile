import Foundation

/// A distinct climb the user has logged before, derived from session history (+ the live session) so the
/// **"Add a climb"** sheet can offer a one-tap **re-log** above Type. Pure value (Foundation only — no
/// SwiftUI / SwiftData) so the dedup / ordering / filter rules are unit-tested without a device (the repo's
/// pure-logic-at-a-thin-edge rule).
///
/// Quick Session climbs have NO content identity — `SessionExercise.id` is per-instance, and the UUIDv5
/// `KilterClimbIdentity` belongs to a *different* feature (the connected Kilter board). So two logs of "the
/// same" climb are deduped on a derived, normalized `id` (type · scale · grade · name · gym · wall · colour),
/// keeping the MOST RECENT instance as the representative. Selecting one prefills the sheet via `params`;
/// committing builds a brand-new climb — history is never mutated and old photos/attempts are not copied.
struct PreviousClimb: Identifiable, Equatable {
    /// The normalized identity key — also the dedup key and a stable handle.
    let id: String
    /// The captured identity, ready to seed the sheet (`AddClimbSheet.seed(from:)`).
    let params: AddClimbParams
    /// When this climb was most recently logged (its source session's `startedAt`) — drives the "when" line.
    let lastLoggedAt: Date
    /// Attempts logged on the representative (most-recent) instance.
    let attemptCount: Int
    /// Best outcome EVER achieved on this climb across ALL deduped instances (drives the "Sent" filter);
    /// `nil` ⇒ no attempt logged. Folded across sessions so an older send isn't lost when the latest
    /// session only logged attempts. (`var` solely so `catalog` can fold it in; read-only otherwise.)
    var bestStatus: KilterAscentStatus?
    /// First attached photo's PHAsset id, for the row preview; `nil` ⇒ the row shows the type glyph instead.
    let photoLocalIdentifier: String?
    /// How many photos the representative instance has (for the count badge).
    let photoCount: Int

    /// Identity is the derived key — equality/dedup compare the climb, not the storage instance.
    static func == (a: PreviousClimb, b: PreviousClimb) -> Bool { a.id == b.id }
}

// MARK: - Identity

extension PreviousClimb {
    /// The normalized dedup/identity key for a climb's display fields. Case/whitespace-insensitive on the
    /// free-text fields (name / gym / wall) so "The Prow" and "the prow " collapse; exact on the enum raws
    /// and the grade rung (a known discrete value). Fields are joined by a unit-separator control char that
    /// can't appear in the inputs.
    static func identityKey(type: ClimbType, scale: GradeScale, grade: String,
                            name: String, gym: String?, wall: String?, color: ClimbColor?) -> String {
        func norm(_ s: String?) -> String {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return [type.rawValue, scale.rawValue,
                grade.trimmingCharacters(in: .whitespacesAndNewlines),
                norm(name), norm(gym), norm(wall), color?.rawValue ?? ""].joined(separator: "\u{1f}")
    }

    /// The identity key for a captured `AddClimbParams`.
    static func identityKey(for p: AddClimbParams) -> String {
        identityKey(type: p.type, scale: p.scale, grade: p.grade,
                    name: p.name, gym: p.gym, wall: p.wall, color: p.color)
    }
}

// MARK: - Catalog (pure)

extension PreviousClimb {
    /// Build the distinct, most-recent-first, capped list of previous climbs from flattened `entries`
    /// (each a climb `SessionExercise` paired with the time it was logged — its source session's
    /// `startedAt`). Non-climb entries are ignored. `photoLookup` maps a climb's `SessionExercise.id` to
    /// its attached photo identifiers (most-relevant first); defaulted so the function is testable with no
    /// Photos. Order is deterministic: most-recent first, ties broken by input order (callers pass the live
    /// session's climbs first, so the live re-log floats to the top).
    static func catalog(
        from entries: [(exercise: SessionExercise, loggedAt: Date)],
        photoLookup: (UUID) -> [String] = { _ in [] },
        cap: Int = 12
    ) -> [PreviousClimb] {
        let climbs = entries.enumerated().filter { $0.element.exercise.kind == .climbAttempt }
        let ordered = climbs.sorted { a, b in
            a.element.loggedAt != b.element.loggedAt
                ? a.element.loggedAt > b.element.loggedAt
                : a.offset < b.offset
        }
        var index: [String: Int] = [:]
        var out: [PreviousClimb] = []
        for item in ordered {
            let ex = item.element.exercise
            let key = identityKey(for: AddClimbParams(from: ex))
            // A climb logged across several sessions dedups to its MOST-RECENT instance (params / photo /
            // date), but `bestStatus` folds the BEST outcome ever achieved on it (flash > sent > project >
            // attempt) so the "Sent" filter stays truthful even when the latest session was only attempts.
            if let i = index[key] {
                if rank(ex.resolvedClimbStatus) > rank(out[i].bestStatus) {
                    out[i].bestStatus = ex.resolvedClimbStatus
                }
                continue
            }
            let photos = photoLookup(ex.id)
            index[key] = out.count
            out.append(PreviousClimb(
                id: key, params: AddClimbParams(from: ex), lastLoggedAt: item.element.loggedAt,
                attemptCount: ex.sets.count, bestStatus: ex.resolvedClimbStatus,
                photoLocalIdentifier: photos.first, photoCount: photos.count))
        }
        return Array(out.prefix(cap))
    }

    /// Outcome rank for the "best across instances" fold (`nil` = no attempt) — mirrors `resolvedClimbStatus`.
    private static func rank(_ s: KilterAscentStatus?) -> Int {
        switch s {
        case .flash:   return 3
        case .sent:    return 2
        case .project: return 1
        case .attempt: return 0
        case nil:      return -1
        }
    }
}

// MARK: - Filter (pure)

extension PreviousClimb {
    /// The mutually-exclusive type scope of the previous-climb filter rail.
    enum Scope: String, CaseIterable, Sendable { case all, boulder, routes }

    /// Apply the search + filter rail to a catalog. `scope` filters by discipline; `gym` (when non-empty)
    /// restricts to that gym case-insensitively (the "This gym" toggle); `sentOnly` keeps climbs whose best
    /// outcome is a send; `query` is a case-insensitive substring matched against name / grade / gym / wall
    /// / setter.
    static func filtered(_ items: [PreviousClimb], query: String = "", scope: Scope = .all,
                         gym: String? = nil, sentOnly: Bool = false) -> [PreviousClimb] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let gymKey = gym?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { pc in
            switch scope {
            case .all:     break
            case .boulder: if pc.params.type.isRoute { return false }
            case .routes:  if !pc.params.type.isRoute { return false }
            }
            if let gymKey, !gymKey.isEmpty {
                let pcGym = (pc.params.gym ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if pcGym != gymKey { return false }
            }
            if sentOnly, !(pc.bestStatus?.isSend ?? false) { return false }
            if !q.isEmpty {
                let hay = [pc.params.name, pc.params.grade, pc.params.gym ?? "",
                           pc.params.wall ?? "", pc.params.setter ?? ""]
                    .joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }
}
