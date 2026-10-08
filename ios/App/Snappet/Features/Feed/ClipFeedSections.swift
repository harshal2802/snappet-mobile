import Foundation

// MARK: - Clips feed — session + month grouping (prompt 167, pure)
//
// On a real library (300+ posts) the feed was one long dateless scroll, and a 6-exercise session read as 6
// near-identical headers in a row. The feed now groups posts under a pinned SESSION header (name · date ·
// kind · post count) and the explore grid under pinned MONTH headers — the "jump to a month" view
// (wireframes: docs/ux-research/clips-navigation/). Grouping is over the already-ordered, already-filtered
// posts (the composer sorts by session start → end, so a session's posts are contiguous), so filters and
// search group their results the same way.

struct ClipFeedSection: Identifiable, Equatable {
    /// The session id (feed) or "yyyy-MM" (grid).
    var id: String
    var title: String
    /// Feed: "Tue 30 Sep · Kilter · 40°"; grid: nil.
    var detail: String?
    var kind: ClipFeedKind?
    var discipline: ClipFeedPost.Discipline?
    var isFromAppleWatch: Bool = false
    var posts: [ClipFeedPost]

    var countLabel: String { "\(posts.count) post\(posts.count == 1 ? "" : "s")" }
}

enum ClipFeedSections {

    /// Consecutive posts of one session → one section. (Posts arrive session-contiguous from the composer;
    /// should the same session ever reappear later in the list, it simply starts a new section.)
    static func sessions(_ posts: [ClipFeedPost], calendar: Calendar = .current,
                         locale: Locale = .current) -> [ClipFeedSection] {
        let day = DateFormatter()
        day.locale = locale; day.calendar = calendar; day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("EEE d MMM")
        var out: [ClipFeedSection] = []
        for post in posts {
            if let last = out.last, last.posts.last?.sessionID == post.sessionID {
                out[out.count - 1].posts.append(post)
                // A festival night's untagged "session clips" post can come first — the session reads
                // as Festival if ANY of its posts is a festival set.
                if post.discipline == .festival, last.discipline != .festival {
                    out[out.count - 1].discipline = .festival
                    out[out.count - 1].detail = detail(post, dayLabel: day.string(from: post.sessionStartedAt),
                                                       activity: .festival)
                }
                continue
            }
            // Duplicate-id guard: a session split into two runs gets a suffixed id (ForEach identity).
            let base = post.sessionID.uuidString
            let id = out.contains { $0.id == base } ? "\(base)#\(out.count)" : base
            out.append(ClipFeedSection(id: id, title: post.sessionTitle.isEmpty ? post.subtitle : post.sessionTitle,
                                       detail: detail(post, dayLabel: day.string(from: post.sessionStartedAt),
                                                      activity: post.discipline == .festival ? .festival : post.sessionActivity),
                                       kind: post.kind,
                                       discipline: post.discipline == .festival ? .festival : post.sessionActivity,
                                       isFromAppleWatch: post.isFromAppleWatch, posts: [post]))
        }
        return out
    }

    /// Prompt 170: names the session's ACTIVITY (Climbing / Strength / Cardio / …), "Kilter" for a board
    /// session, plus its angle and an Apple Watch marker — "Sat 27 Sep · Climbing · Apple Watch".
    static func detail(_ post: ClipFeedPost, dayLabel: String, activity: ClipFeedPost.Discipline) -> String {
        var parts = [dayLabel]
        parts.append(post.kind == .kilter ? "Kilter" : activity.label)
        if let a = post.sessionAngle { parts.append("\(a)°") }
        if post.isFromAppleWatch { parts.append("Apple Watch") }
        return parts.joined(separator: " · ")
    }

    /// Posts grouped by the month their session started ("October 2026"), newest first (input order kept).
    static func months(_ posts: [ClipFeedPost], calendar: Calendar = .current,
                       locale: Locale = .current) -> [ClipFeedSection] {
        let title = DateFormatter()
        title.locale = locale; title.calendar = calendar; title.timeZone = calendar.timeZone
        title.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        var out: [ClipFeedSection] = []
        for post in posts {
            let c = calendar.dateComponents([.year, .month], from: post.sessionStartedAt)
            let id = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            if let i = out.firstIndex(where: { $0.id == id }) { out[i].posts.append(post); continue }
            out.append(ClipFeedSection(id: id, title: title.string(from: post.sessionStartedAt), posts: [post]))
        }
        return out
    }
}
