import Foundation

// MARK: - Clips feed — festival + artist chips (prompt 171, pure)
//
// The single "Festival" chip becomes one chip PER FESTIVAL you have clips from; picking one shows a second
// row of the artists you have matched clips of, plus "Untagged" for clips not matched to a set yet. Built
// from the posts, so the chips are only ever ones that would show something. Unit-tested.

enum ClipFestivalChips {

    struct Festival: Equatable, Identifiable {
        var packID: String
        var name: String
        var id: String { packID }
    }

    /// The festivals in `posts`, newest first (the feed's order), each once.
    static func festivals(in posts: [ClipFeedPost]) -> [Festival] {
        var seen = Set<String>()
        var out: [Festival] = []
        for p in posts {
            guard let f = p.festival, !f.packID.isEmpty, seen.insert(f.packID).inserted else { continue }
            out.append(Festival(packID: f.packID, name: f.name))
        }
        return out
    }

    /// The artists you have matched clips of at `packID` (alphabetical — easy to scan a lineup), and how
    /// many of that festival's posts aren't matched yet.
    static func artists(in posts: [ClipFeedPost], packID: String) -> (artists: [String], untagged: Int) {
        let mine = posts.filter { $0.festival?.packID == packID }
        let names = Set(mine.compactMap { $0.festival?.artist })
        return (names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                mine.filter { $0.festival?.artist == nil }.count)
    }
}
