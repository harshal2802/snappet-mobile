import Foundation

/// **Every picker is the Library** (Library redesign L4b, prompt 187): Quick Session "Add exercise" and the routine
/// builder open on **Yours · Most used** with a "Last: …" line, the catalog one tap away under Explore. These are the
/// pure rules both pickers share — which of your activities a picker offers and in what order; the conversion of a
/// pick into a session entity or a routine block is `ActivityLauncher`'s (the same as Log it now / Add to routine).
enum LibraryPick {

    /// One ticked row in a picker, in the order you ticked it: a catalog item (by id) or one of yours (by key).
    enum Choice: Hashable, Sendable {
        case catalog(String)
        case yours(ActivityKey)
    }

    /// The Yours rows a picker offers: everything you can start again (not a festival night, not a whole-discipline
    /// overview), minus what you hid, filtered by search + discipline, **most used first** — and the ones you created
    /// but haven't done yet after them (they have no usage to rank on).
    static func rows(_ yours: [LibraryCatalog.Row], hidden: Set<ActivityKey>, query: String,
                     discipline: WorkoutDiscipline?) -> [LibraryCatalog.Row] {
        let offered = yours.filter { ActivityLauncher.canLaunch($0.key) && !hidden.contains($0.key) }
        let sorted = LibraryCatalog.sorted(LibraryCatalog.filter(offered, query: query, discipline: discipline),
                                           by: .mostUsed)
        return sorted.filter { !$0.notDoneYet } + sorted.filter(\.notDoneYet)
    }

    /// The picker's subtitle for a row: "Last: 4 × 8 @ 75 kg", or what it is when there's no last time.
    static func subtitle(_ row: LibraryCatalog.Row) -> String {
        if row.notDoneYet { return row.headline ?? "Not done yet" }
        if let last = row.last { return "Last: \(last)" }
        return row.discipline.label
    }

    /// Open on Yours when there's something in it, else on the catalog.
    static func opensOnYours(_ rows: [LibraryCatalog.Row]) -> Bool { !rows.isEmpty }
}
