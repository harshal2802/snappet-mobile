import Foundation

/// **Pure, undoable Library maintenance** (Library redesign L3, prompt 185): rename an activity everywhere it was
/// logged, merge look-alikes into one, and suggest which names look alike. Every operation returns the exact
/// per-entity before/after it would apply, so the edge can apply it and later reverse it (Undo) without re-deriving.
///
/// What it touches is deliberately narrow: an entity's NAME (and, for a climb, the gym / wall / colour that are part
/// of its identity). Sets, grades, outcomes, durations and clips are never rewritten — a merged climb keeps every
/// attempt exactly as logged.
enum LibraryMaintenance {

    /// The identity-bearing fields an operation may change on a `SessionExercise`.
    struct Fields: Equatable, Sendable {
        var displayName: String?
        var gym: String?
        var wall: String?
        var colorRaw: String?

        init(_ ex: SessionExercise) {
            displayName = ex.displayName; gym = ex.gym; wall = ex.wall; colorRaw = ex.climbColorRaw
        }
        init(displayName: String?, gym: String?, wall: String?, colorRaw: String?) {
            self.displayName = displayName; self.gym = gym; self.wall = wall; self.colorRaw = colorRaw
        }
    }

    struct Change: Equatable, Sendable {
        let sessionID: UUID
        let exerciseID: UUID
        let before: Fields
        let after: Fields
    }

    // MARK: - Capability

    /// Rename is for anything you named (or a catalog lift, whose name becomes an override). Not festivals (their name
    /// is the festival's) and not whole-discipline overviews.
    static func canRename(_ key: ActivityKey) -> Bool {
        key.disciplineScope == nil && key.exerciseId != ActivityIdentity.festivalExerciseId
            && !LibraryCatalog.isKilter(key)   // a board climb's name is the Kilter catalog's (prompt 189)
    }

    /// Merge folds named activities together — climbs and ad-hoc entities. A catalog lift's identity is its catalog
    /// id, so two different catalog lifts are never "the same".
    static func canMerge(_ key: ActivityKey) -> Bool {
        canRename(key) && !key.nameKey.isEmpty
    }

    // MARK: - Rename

    /// Every entity of `key` gets `newName`. An empty / unchanged name is no change.
    static func rename(_ key: ActivityKey, to newName: String, sessions: [WorkoutSession],
                       identity: ActivityIdentity) -> [Change] {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRename(key), !name.isEmpty else { return [] }
        return entities(of: key, in: sessions, identity: identity).compactMap { s, ex in
            var after = Fields(ex)
            after.displayName = name
            return after == Fields(ex) ? nil : Change(sessionID: s.id, exerciseID: ex.id, before: Fields(ex), after: after)
        }
    }

    // MARK: - Merge

    /// Fold every entity of `sources` into `target`: they take the target's name — and for climbs its gym, wall and
    /// colour — from the target's most recent instance. Logs of a climb more than the reset window apart still stay
    /// separate sets afterwards (the gym reset it); that's the identity rule, not the merge.
    static func merge(_ sources: [ActivityKey], into target: ActivityKey, sessions: [WorkoutSession],
                      identity: ActivityIdentity) -> [Change] {
        guard canMerge(target),
              let template = entities(of: target, in: sessions, identity: identity).last?.1 else { return [] }
        let isClimb = template.discipline == .climb
        var out: [Change] = []
        for source in sources where source != target && canMerge(source) {
            for (s, ex) in entities(of: source, in: sessions, identity: identity) {
                var after = Fields(ex)
                after.displayName = template.displayName
                if isClimb { after.gym = template.gym; after.wall = template.wall; after.colorRaw = template.climbColorRaw }
                if after != Fields(ex) {
                    out.append(Change(sessionID: s.id, exerciseID: ex.id, before: Fields(ex), after: after))
                }
            }
        }
        return out
    }

    // MARK: - Apply / undo

    /// Write `changes` into the sessions (their `after`, or their `before` when undoing). Returns how many entities
    /// changed. The caller saves the store.
    @discardableResult
    static func apply(_ changes: [Change], to sessions: [WorkoutSession], undo: Bool = false) -> Int {
        let bySession = Dictionary(grouping: changes, by: \.sessionID)
        var n = 0
        for s in sessions {
            guard let cs = bySession[s.id] else { continue }
            var exercises = s.exercises
            for c in cs {
                guard let i = exercises.firstIndex(where: { $0.id == c.exerciseID }) else { continue }
                let f = undo ? c.before : c.after
                exercises[i].displayName = f.displayName
                exercises[i].gym = f.gym
                exercises[i].wall = f.wall
                exercises[i].climbColorRaw = f.colorRaw
                n += 1
            }
            s.exercises = exercises
        }
        return n
    }

    // MARK: - Look-alikes

    /// Your other activities of the same discipline whose names look like `row`'s — one contains the other, or
    /// they're a few typos apart — most alike first. Merge suggestions. Never two climbs of different grades, and
    /// never names that differ only in a number ("V4 boulder" / "V5 boulder", "Route 3" / "Route 4") — those are
    /// different things, however alike they look.
    static func lookalikes(of row: LibraryCatalog.Row, in rows: [LibraryCatalog.Row]) -> [LibraryCatalog.Row] {
        let a = ActivityKey.normalize(row.title)
        guard !a.isEmpty else { return [] }
        return rows.compactMap { r -> (LibraryCatalog.Row, Int)? in
            guard r.key != row.key, r.discipline == row.discipline, canMerge(r.key) else { return nil }
            if let g1 = row.climb?.grade, let g2 = r.climb?.grade, !g1.isEmpty, !g2.isEmpty,
               ActivityKey.normalize(g1) != ActivityKey.normalize(g2) { return nil }
            let b = ActivityKey.normalize(r.title)
            guard !b.isEmpty else { return nil }
            if a != b, a.filter({ !$0.isNumber }) == b.filter({ !$0.isNumber }) { return nil }
            if a == b { return (r, 0) }
            if a.contains(b) || b.contains(a) { return (r, 1) }
            let d = editDistance(a, b)
            return d <= max(2, min(a.count, b.count) / 4) ? (r, 1 + d) : nil
        }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.lastDate > $1.0.lastDate }
        .map(\.0)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }

    // MARK: - Private

    /// Every entity of `key` with its session, oldest → newest.
    private static func entities(of key: ActivityKey, in sessions: [WorkoutSession],
                                 identity: ActivityIdentity) -> [(WorkoutSession, SessionExercise)] {
        var out: [(WorkoutSession, SessionExercise)] = []
        for s in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for ex in s.exercises where identity.key(for: ex, loggedAt: s.startedAt) == key {
                out.append((s, ex))
            }
        }
        return out
    }
}
