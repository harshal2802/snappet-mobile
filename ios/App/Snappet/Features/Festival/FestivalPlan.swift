import Foundation

/// The starred-set plan (wireframe frame 4's ★): a bag of set content-ids plus the pure interval math
/// everything downstream leans on — clash detection ("⚠︎ clash"), the reminder instants prompt 04 hands
/// to `UNUserNotificationCenter`, and the schedule gaps the `SetRecommender` fills. Lives beside the
/// matcher because clash/gap math is the same interval vocabulary.
///
/// Ids are content ids (UUIDv5), so a plan survives a pack re-download and travels in the prompt-05
/// share QR. `Codable` for cheap persistence; pure Foundation → unit-tested without a simulator.
struct FestivalPlan: Sendable, Equatable, Codable {
    var starredSetIDs: Set<UUID> = []

    init(starredSetIDs: Set<UUID> = []) {
        self.starredSetIDs = starredSetIDs
    }

    mutating func toggle(_ setID: UUID) {
        if !starredSetIDs.insert(setID).inserted { starredSetIDs.remove(setID) }
    }

    func isStarred(_ setID: UUID) -> Bool { starredSetIDs.contains(setID) }

    /// The starred sets that exist in `pack`, chronological (then by artist for same-start stability).
    /// Stale ids — a star from a lineup revision that dropped the set — simply don't resolve.
    func starredSets(in pack: FestivalPack) -> [FestivalSet] {
        pack.allSets
            .filter { starredSetIDs.contains($0.id) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
    }

    // MARK: Clashes

    /// Two starred sets the user can't attend whole: their windows overlap in time (stages are where
    /// legs come in, not this math). Back-to-back (end == next start) is NOT a clash.
    struct Clash: Sendable, Equatable {
        let first: FestivalSet
        let second: FestivalSet
        let overlap: DateInterval
    }

    /// Every overlapping pair among the starred sets, ordered by the earlier set's start. `first` is
    /// always the earlier-starting set of the pair.
    func clashes(in pack: FestivalPack) -> [Clash] {
        let starred = starredSets(in: pack)
        var out: [Clash] = []
        for (i, a) in starred.enumerated() {
            for b in starred.dropFirst(i + 1) where b.start < a.end {
                out.append(Clash(first: a, second: b,
                                 overlap: DateInterval(start: b.start, end: min(a.end, b.end))))
            }
        }
        return out
    }

    // MARK: Reminders

    struct Reminder: Sendable, Equatable {
        let set: FestivalSet
        /// When to fire: `lead` before the set starts.
        let fireDate: Date
    }

    /// One reminder per starred set, `lead` seconds before its start, chronological. Pure — prompt 04
    /// owns dropping past dates and the `UNUserNotificationCenter` edge.
    func reminderDates(in pack: FestivalPack, lead: TimeInterval) -> [Reminder] {
        starredSets(in: pack).map {
            Reminder(set: $0, fireDate: $0.start.addingTimeInterval(-lead))
        }
    }

    // MARK: Gaps

    /// The empty stretches between consecutive starred sets *within one festival day* — what the
    /// recommender offers to fill. Overlapping (clashing) or back-to-back stars produce no gap, and a
    /// day needs ≥2 stars to have one. Ordered chronologically.
    func gaps(in pack: FestivalPack) -> [DateInterval] {
        var out: [DateInterval] = []
        for day in pack.days {
            let starred = starredSets(in: pack).filter { set in
                day.window(utcOffsetSeconds: pack.utcOffsetSeconds)?.contains(set.start) == true
            }
            var frontier: Date?
            for set in starred {
                if let end = frontier, set.start > end {
                    out.append(DateInterval(start: end, end: set.start))
                }
                frontier = max(frontier ?? set.end, set.end)
            }
        }
        return out
    }
}
