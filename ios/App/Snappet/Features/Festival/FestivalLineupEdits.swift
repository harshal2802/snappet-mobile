import Foundation

// MARK: - Lineup edits (prompt 232, pure)
//
// The user's own changes to an installed lineup — a late start, a weather hold that pushes a whole
// stage back, a set the poster got wrong, a surprise guest — layered OVER the original `.fpack`
// rather than rewriting it. Why an overlay: a set's id is a UUIDv5 over its artist/stage/times, so
// re-stamping an edited set would orphan its stars, "I'm here" stretches and clip tags. Applying
// the overlay keeps every original id, and the original bytes stay untouched for re-share and for
// "Reset to the lineup's time". Stored as JSON on `FestivalLineup.editsData`; `FestivalLineup.pack()`
// applies it, so every surface (schedule, matcher, recap, reminders, exports) sees the edited times.

struct FestivalLineupEdits: Codable, Equatable, Sendable {

    /// Field-level changes to an ORIGINAL set (nil = unchanged).
    struct SetChange: Codable, Equatable, Sendable {
        var artist: String?
        var stage: String?
        var start: Date?
        var end: Date?

        var isEmpty: Bool { artist == nil && stage == nil && start == nil && end == nil }
    }

    /// A set the user added by hand. Its id is minted once at creation and never re-derived, so
    /// later edits to it keep its stars/claims.
    struct AddedSet: Codable, Equatable, Sendable {
        var id: UUID
        var artist: String
        var stage: String
        var start: Date
        var end: Date
    }

    var name: String?
    var changes: [UUID: SetChange] = [:]
    var removed: Set<UUID> = []
    var added: [AddedSet] = []

    var isEmpty: Bool { name == nil && changes.isEmpty && removed.isEmpty && added.isEmpty }

    // MARK: Storage

    static func decode(_ data: Data) -> FestivalLineupEdits {
        guard !data.isEmpty else { return FestivalLineupEdits() }
        return (try? JSONDecoder().decode(FestivalLineupEdits.self, from: data)) ?? FestivalLineupEdits()
    }

    func encoded() -> Data {
        isEmpty ? Data() : ((try? JSONEncoder().encode(self)) ?? Data())
    }

    // MARK: Apply

    /// The edited pack: original sets with their changes (ids kept), minus removed, plus added.
    /// A set whose new start leaves its poster day re-files under the day that now contains it.
    /// Stage order is the original order with new stages appended; a stage left empty drops out.
    func apply(to original: FestivalPack) -> FestivalPack {
        guard !isEmpty else { return original }
        var pack = original
        if let name, !name.isEmpty { pack.name = name }

        var entries: [(day: String, set: FestivalSet)] = []
        for day in original.days {
            for stage in day.stages {
                for var set in stage.sets where !removed.contains(set.id) {
                    if let change = changes[set.id] {
                        if let v = change.artist { set.artist = v }
                        if let v = change.stage { set.stage = v }
                        if let v = change.start { set.start = v }
                        if let v = change.end { set.end = v }
                    }
                    let moved = changes[set.id]?.start != nil
                    let dayDate = moved ? (original.day(containing: set.start)?.date ?? day.date) : day.date
                    entries.append((dayDate, set))
                }
            }
        }
        for a in added where !removed.contains(a.id) {
            var set = FestivalSet(artist: a.artist, start: a.start, end: a.end)
            set.id = a.id
            set.stage = a.stage
            entries.append((Self.nearestDay(to: a.start, in: original), set))
        }

        var stageOrder = original.days.flatMap { $0.stages.map(\.name) }
        for e in entries where !stageOrder.contains(e.set.stage) { stageOrder.append(e.set.stage) }
        var uniqueOrder: [String] = []
        for s in stageOrder where !uniqueOrder.contains(s) { uniqueOrder.append(s) }

        pack.days = original.days.map { day in
            let mine = entries.filter { $0.day == day.date }.map(\.set)
            let stages = uniqueOrder.compactMap { name -> FestivalStage? in
                let sets = mine.filter { $0.stage == name }
                    .sorted { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
                return sets.isEmpty ? nil : FestivalStage(name: name, sets: sets)
            }
            return FestivalDay(date: day.date, stages: stages)
        }
        return pack
    }

    /// The poster day containing `date`, else the day whose window starts closest to it (a set
    /// typed outside the festival's days still lands somewhere visible).
    static func nearestDay(to date: Date, in pack: FestivalPack) -> String {
        if let day = pack.day(containing: date) { return day.date }
        func distance(_ day: FestivalDay) -> TimeInterval {
            guard let start = day.window(utcOffsetSeconds: pack.utcOffsetSeconds)?.start else {
                return .infinity
            }
            return abs(start.timeIntervalSince(date))
        }
        return pack.days.min { distance($0) < distance($1) }?.date ?? ""
    }

    // MARK: Edits

    /// The original (poster) times of an edited set, for "edited (was 23:30–01:00)". `nil` when the
    /// set's times are untouched or it was added by hand.
    func originalTimes(of setID: UUID, in original: FestivalPack) -> DateInterval? {
        guard let change = changes[setID], change.start != nil || change.end != nil,
              let set = original.setsByID[setID] else { return nil }
        return set.window
    }

    /// Change one set (original or added). Values equal to the original clear that field, so an
    /// edit back to the poster time is the same as never editing it.
    mutating func update(_ setID: UUID, artist: String? = nil, stage: String? = nil,
                         start: Date? = nil, end: Date? = nil, original: FestivalPack) {
        if let i = added.firstIndex(where: { $0.id == setID }) {
            if let artist { added[i].artist = artist }
            if let stage { added[i].stage = stage }
            if let start { added[i].start = start }
            if let end { added[i].end = end }
            return
        }
        guard let base = original.setsByID[setID] else { return }
        var change = changes[setID] ?? SetChange()
        if let artist { change.artist = artist == base.artist ? nil : artist }
        if let stage { change.stage = stage == base.stage ? nil : stage }
        if let start { change.start = start == base.start ? nil : start }
        if let end { change.end = end == base.end ? nil : end }
        changes[setID] = change.isEmpty ? nil : change
    }

    /// Put one set's times back to the poster's.
    mutating func resetTimes(_ setID: UUID) {
        guard var change = changes[setID] else { return }
        change.start = nil
        change.end = nil
        changes[setID] = change.isEmpty ? nil : change
    }

    mutating func remove(_ setID: UUID) {
        if let i = added.firstIndex(where: { $0.id == setID }) {
            added.remove(at: i)
        } else {
            removed.insert(setID)
            changes[setID] = nil
        }
    }

    /// Add a set by hand; returns its new id.
    @discardableResult
    mutating func add(artist: String, stage: String, start: Date, end: Date,
                      festivalID: String) -> UUID {
        let probe = FestivalSet(artist: artist, start: start, end: end)
        var id = FestivalSet.contentID(festivalID: festivalID, stage: stage, set: probe)
        // The same artist/stage/time added twice still needs two distinct rows.
        while added.contains(where: { $0.id == id }) { id = UUID() }
        added.append(AddedSet(id: id, artist: artist, stage: stage, start: start, end: end))
        return id
    }

    /// Move `sets` (from the CURRENT edited pack) by `seconds`: `startAndEnd` sets move whole,
    /// `endOnly` sets (already playing at the delay point) just run later.
    mutating func shift(startAndEnd: [FestivalSet], endOnly: [FestivalSet] = [],
                        by seconds: TimeInterval, original: FestivalPack) {
        for set in startAndEnd {
            update(set.id, start: set.start.addingTimeInterval(seconds),
                   end: set.end.addingTimeInterval(seconds), original: original)
        }
        for set in endOnly {
            update(set.id, end: set.end.addingTimeInterval(seconds), original: original)
        }
    }

    // MARK: Delay targets (pure previews for the sheets)

    /// What "Delay the schedule" would move: on the festival day containing `from`, every set on
    /// the chosen stages (`nil` = all) starting at/after `from` moves whole; a set already playing
    /// at `from` keeps its start and ends later. Later poster days are never touched.
    static func delayTargets(in pack: FestivalPack, stages: Set<String>?, from: Date)
        -> (moved: [FestivalSet], extended: [FestivalSet]) {
        guard let day = pack.day(containing: from) else { return ([], []) }
        let sets = day.allSets.filter { stages?.contains($0.stage) ?? true }
        let moved = sets.filter { $0.start >= from }
        let extended = sets.filter { $0.start < from && $0.end > from }
        return (moved, extended)
    }

    /// The sets after `set` on its stage, same festival day — what "Also move later sets on <stage>"
    /// carries along when one set runs late.
    static func laterSets(after set: FestivalSet, in pack: FestivalPack) -> [FestivalSet] {
        guard let day = pack.day(containing: set.start)
                ?? pack.days.first(where: { $0.allSets.contains { $0.id == set.id } }) else { return [] }
        return day.allSets.filter { $0.stage == set.stage && $0.id != set.id && $0.start >= set.start }
    }

    /// "+30 min" / "−15 min" / "+1 h 15".
    static func shiftLabel(_ seconds: TimeInterval) -> String {
        let mins = Int((seconds / 60).rounded())
        let sign = mins < 0 ? "−" : "+"
        let a = abs(mins)
        if a < 60 { return "\(sign)\(a) min" }
        return a % 60 == 0 ? "\(sign)\(a / 60) h" : String(format: "%@%d h %02d", sign, a / 60, a % 60)
    }
}
