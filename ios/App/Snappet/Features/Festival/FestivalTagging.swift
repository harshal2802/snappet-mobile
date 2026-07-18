import Foundation

// MARK: - Festival tagging — pure decision layer (festival prompt 03)
//
// Everything between "a dance session has media" and "tag rows exist / the review sheet knows what
// to ask" that can be decided without touching SwiftData or Photos. `FestivalTagSync` (the thin
// @MainActor edge) snapshots the @Models into the plain values below, calls these functions, and
// writes the results back — so the auto-vs-ask partition, the sticky-user-decision rule, the review
// captions, and the timeline geometry all unit-test in `SnappetTests` with no simulator.

enum FestivalTagging {

    // MARK: Session media → ClipStamps (the #283 adaptation)

    /// A plain-value snapshot of one `SessionMedia` row, taken at the store edge.
    struct MediaSnapshot: Sendable, Equatable {
        var mediaID: UUID
        var offsetSec: Double
        var durationSec: Double?
        /// `true` for a posted highlight reel (`SessionMedia.isReel`) — an export, not festival
        /// footage; never matched.
        var isReel: Bool
    }

    /// Adapt a dance session's media into the matcher's `ClipStamp`s: `captureDate = session
    /// startedAt + offsetSec` (the #283 session-media-window timeline), `id = mediaID.uuidString`.
    /// Posted reels are dropped — a reel is a cut of the night, not a clip from a set.
    static func stamps(for media: [MediaSnapshot], sessionStart: Date) -> [ClipStamp] {
        media.filter { !$0.isReel }.map {
            ClipStamp(id: $0.mediaID.uuidString,
                      captureDate: sessionStart.addingTimeInterval(max(0, $0.offsetSec)),
                      duration: $0.durationSec)
        }
    }

    // MARK: Tag provenance

    /// Who decided a tag. `auto` rows are (re)placed by every matcher pass; `user` (an override,
    /// a Change › pick, or "keep all") and `none` ("not from a set") are STICKY — the auto pass
    /// never touches them. Mirrors `MediaAssignmentSource`.
    enum TagSource: String, Sendable, Codable, CaseIterable {
        case auto, user, none
    }

    /// A plain-value mirror of one existing `FestivalClipTag` row (what the planner needs to know).
    struct ExistingTag: Sendable, Equatable {
        var mediaID: UUID
        var setID: UUID
        var source: TagSource
    }

    // MARK: The auto-vs-ask plan

    /// One tag the sync should write (insert, or update the existing `auto` row in place).
    struct Upsert: Sendable, Equatable {
        var mediaID: UUID
        var set: FestivalSet
        var confidence: Double
        var reason: String   // the caption key — see `caption(for:)`
    }

    /// What one matcher pass means for the store: `upserts` apply silently; `reviewMediaIDs` float
    /// to the sheet's "Needs you"; `staleMediaIDs` are `auto` rows whose clip no longer matches any
    /// set (media deleted from the session, or a lineup revision moved the set) — the sync deletes
    /// them so tags never outlive their evidence.
    struct Plan: Sendable, Equatable {
        var upserts: [Upsert] = []
        var reviewMediaIDs: [UUID] = []
        var staleMediaIDs: [UUID] = []
    }

    /// Partition matcher output against the existing rows. Rules (the acceptance criteria):
    /// - an assignment at/above `FestivalSetMatcher.autoTagThreshold` with a set → silent upsert,
    ///   UNLESS the clip already has a sticky (`user`/`none`) row;
    /// - below the threshold (or `.outsideSchedule`) → the review queue, again unless sticky;
    ///   an existing `auto` row for such a clip is stale (the evidence weakened) and is removed —
    ///   as is an `auto` row whose clip no longer has ANY assignment (the media was deleted);
    /// - re-running the same pass is a no-op by construction (same inputs → same upserts).
    static func plan(assignments: [FestivalSetMatcher.Assignment],
                     existing: [ExistingTag]) -> Plan {
        let sticky = Set(existing.filter { $0.source != .auto }.map(\.mediaID))
        let autoRows = Set(existing.filter { $0.source == .auto }.map(\.mediaID))
        var out = Plan()
        var seen = Set<UUID>()
        for a in assignments {
            guard let mediaID = UUID(uuidString: a.clipID) else { continue }
            seen.insert(mediaID)
            guard !sticky.contains(mediaID) else { continue }
            if a.isAutoTag, let set = a.set {
                out.upserts.append(Upsert(mediaID: mediaID, set: set, confidence: a.confidence,
                                          reason: caption(for: a.reason)))
            } else {
                if a.set != nil { out.reviewMediaIDs.append(mediaID) }
                if autoRows.contains(mediaID) { out.staleMediaIDs.append(mediaID) }
            }
        }
        // Orphaned auto rows: the clip disappeared from the session (deleted media) — no evidence,
        // no tag. Sticky rows are the user's word and stay.
        out.staleMediaIDs.append(contentsOf: autoRows.subtracting(seen).sorted { $0.uuidString < $1.uuidString })
        return out
    }

    // MARK: Review rows (frame 9)

    /// The machine-readable reason rendered as the row caption — the wireframe's exact vocabulary.
    static func caption(for reason: FestivalSetMatcher.Reason) -> String {
        switch reason {
        case .withinSet: return "mid-set"
        case .betweenSets: return "between stages"
        case .multipleStagesLive: return "two sets live"
        case .outsideSchedule: return "off the schedule"
        }
    }

    /// "62%" — the row's confidence chip.
    static func percentLabel(_ confidence: Double) -> String {
        "\(Int((confidence * 100).rounded()))%"
    }

    /// The sets a Change › dialog offers for an assignment: the assignment's own evidence first
    /// (proposed set, gap neighbours, every live candidate), deduped, in start order. The dialog
    /// appends "Not from a set" itself — that's a resolution, not a candidate.
    static func candidates(for assignment: FestivalSetMatcher.Assignment) -> [FestivalSet] {
        var sets: [FestivalSet] = []
        if let set = assignment.set { sets.append(set) }
        switch assignment.reason {
        case .betweenSets(let before, let after):
            sets.append(contentsOf: [before, after])
        case .multipleStagesLive(let live):
            sets.append(contentsOf: live)
        case .withinSet, .outsideSchedule:
            break
        }
        var seen = Set<UUID>()
        return sets.filter { seen.insert($0.id).inserted }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
    }

    /// "or Eric Prydz?" — the second line of a needs-you row: the strongest candidate that ISN'T
    /// the proposal. `nil` when the proposal is the only candidate (gap rows name their reason
    /// instead).
    static func alternativeLabel(for assignment: FestivalSetMatcher.Assignment) -> String? {
        guard case .multipleStagesLive = assignment.reason else { return nil }
        let other = candidates(for: assignment).first { $0.id != assignment.set?.id }
        return other.map { "or \($0.artist)?" }
    }

    /// "Saturday · 11 clips · 8 auto-tagged · 3 need you" — the sheet's summary line (day label
    /// prepended by the view when it knows the selected day).
    static func summaryLine(clipCount: Int, autoCount: Int, needsYouCount: Int) -> String {
        var parts = ["\(clipCount) clip\(clipCount == 1 ? "" : "s")"]
        parts.append("\(autoCount) auto-tagged")
        if needsYouCount > 0 { parts.append("\(needsYouCount) need\(needsYouCount == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }

    // MARK: Day labels

    /// The rollover-aware poster weekday for a capture instant ("Saturday") — a 01:00 clip labels
    /// as the night before, exactly the `FestivalDay.rolloverHour` rule, without inflating a pack.
    static func posterWeekday(for date: Date, utcOffsetSeconds: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        cal.locale = Locale(identifier: "en_US")   // fixed-English labels, the suite rule
        let shifted = date.addingTimeInterval(-Double(FestivalDay.rolloverHour) * 3600)
        return cal.weekdaySymbols[cal.component(.weekday, from: shifted) - 1]
    }
}

// MARK: - Review-sheet timeline geometry (frame 9)

/// The day as a horizontal bar: set blocks and clip ticks as `0…1` fractions of the day's
/// PROGRAMMED span (first set start → last set end, padded), not the full 24 h window — a festival
/// day is empty until noon and the wireframe's bar isn't. Pure values → the view is a dumb render.
enum FestivalTagTimeline {

    /// Fraction of the span added as breathing room on each side.
    static let edgePad = 0.03

    struct Block: Equatable, Identifiable {
        var setID: UUID
        var artist: String
        var x: Double        // leading edge, 0…1
        var width: Double    // 0…1
        var id: UUID { setID }
    }

    struct Tick: Equatable, Identifiable {
        var mediaID: UUID
        var x: Double        // 0…1
        var needsYou: Bool
        var id: UUID { mediaID }
    }

    struct Layout: Equatable {
        var blocks: [Block] = []
        var ticks: [Tick] = []
    }

    /// Lay out one day's sets + clip stamps. `needsYou` marks the ticks the sheet paints amber.
    /// Returns an empty layout when the day has no sets (nothing to draw against).
    static func layout(sets: [FestivalSet], stamps: [ClipStamp],
                       needsYou: Set<UUID>) -> Layout {
        guard let first = sets.map(\.start).min(),
              let last = sets.map(\.end).max(), last > first else { return Layout() }
        let raw = last.timeIntervalSince(first)
        let pad = raw * edgePad
        let origin = first.addingTimeInterval(-pad)
        let span = raw + 2 * pad

        func fraction(_ date: Date) -> Double {
            min(1, max(0, date.timeIntervalSince(origin) / span))
        }

        let blocks = sets
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
            .map { set in
                Block(setID: set.id, artist: set.artist,
                      x: fraction(set.start),
                      width: max(0.01, fraction(set.end) - fraction(set.start)))
            }
        let ticks = stamps.compactMap { stamp -> Tick? in
            guard let mediaID = UUID(uuidString: stamp.id) else { return nil }
            return Tick(mediaID: mediaID, x: fraction(stamp.captureDate),
                        needsYou: needsYou.contains(mediaID))
        }
        return Layout(blocks: blocks, ticks: ticks)
    }
}
