import Foundation

/// **Sessions · Activities · Exercises** (Clips redesign part 2, prompt 197; wireframe screens 1–3): what a Clips post
/// is. Activities is today's post (one activity in one session). Sessions merges a session's posts into ONE post — every
/// clip in filming order, each labelled with its activity + set, chips to jump between activities, the session's
/// stats. Exercises folds every session of an activity into a progress ALBUM — Then vs Now, the gain, the timeline.
/// Pure transforms of the composed activity posts (after filters), so the three always agree.
enum ClipFeedLevel: String, CaseIterable, Identifiable, Sendable {
    case sessions, activities, exercises
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .activities: return "Activities"
        case .exercises: return "Exercises"
        }
    }
    static let storageKey = "clips.level"
}

/// One activity inside a session post — a chip that jumps the carousel to its first clip.
struct ClipFeedActivityChip: Sendable, Equatable, Hashable {
    let title: String
    let firstPage: Int
    let count: Int
}

/// One activity's progress album (the Exercises level).
struct ClipFeedAlbum: Identifiable, Sendable, Equatable {
    let key: ActivityKey
    let title: String
    let discipline: ClipFeedPost.Discipline
    /// The activity's posts, oldest → newest (one per session).
    let posts: [ClipFeedPost]
    var id: String { "album:\(key.exerciseId)|\(key.nameKey)" }
    var clipCount: Int { posts.reduce(0) { $0 + $1.clipCount } }
    var sessionCount: Int { Set(posts.map(\.sessionID)).count }
    var first: ClipFeedPost { posts[0] }
    var latest: ClipFeedPost { posts[posts.count - 1] }
    var since: Date { first.sessionStartedAt }
    var lastDone: Date { latest.sessionStartedAt }
}

enum ClipFeedLevels {

    /// One post per session: its activity posts merged (reels keep their own post). Feed order is preserved.
    static func sessions(_ posts: [ClipFeedPost]) -> [ClipFeedPost] {
        var order: [UUID] = []
        var members: [UUID: [ClipFeedPost]] = [:]
        var out: [ClipFeedPost] = []
        for p in posts {
            if p.isReel { out.append(p); continue }
            if members[p.sessionID] == nil { order.append(p.sessionID); out.append(p) }   // placeholder slot
            members[p.sessionID, default: []].append(p)
        }
        var built: [UUID: ClipFeedPost] = [:]
        for sid in order { built[sid] = merge(members[sid] ?? []) }
        return out.map { p in p.isReel ? p : (built[p.sessionID] ?? p) }
            .reduce(into: [ClipFeedPost]()) { acc, p in if !acc.contains(where: { $0.id == p.id }) { acc.append(p) } }
    }

    /// A session's activity posts → one session post.
    static func merge(_ group: [ClipFeedPost]) -> ClipFeedPost {
        guard var post = group.first else { preconditionFailure("empty session group") }
        if group.count == 1 && group[0].stats == nil && group[0].exerciseID == nil && group[0].climbUUID == nil {
            post.level = .sessions
            return post
        }
        // Every clip in filming order, labelled with its activity (+ its set / attempt).
        var tagged: [(ClipFeedItem, String)] = []
        for p in group { for item in p.clips { tagged.append((item, p.title)) } }
        tagged.sort { $0.0.media.offsetSec < $1.0.media.offsetSec }
        let items = tagged.map { item, title in
            ClipFeedItem(media: item.media, attemptLabel: [title, item.attemptLabel].compactMap { $0 }.joined(separator: " · "))
        }
        var chips: [ClipFeedActivityChip] = []
        for (i, (_, title)) in tagged.enumerated() where !chips.contains(where: { $0.title == title }) {
            chips.append(ClipFeedActivityChip(title: title, firstPage: i, count: tagged.filter { $0.1 == title }.count))
        }
        let sets = group.reduce(0) { $0 + ($1.stats?.setDetail.count ?? 0) }
        let exercises = group.filter { $0.stats != nil }.count
        let prs = group.filter { $0.stats?.isPR == true }.count
        var parts: [String] = []
        if sets > 0 { parts.append("\(sets) \(sets == 1 ? "set" : "sets")") }
        if exercises > 0 { parts.append("\(exercises) \(exercises == 1 ? "exercise" : "exercises")") }
        if exercises == 0 { parts.append("\(items.count) \(items.count == 1 ? "clip" : "clips")") }

        let name = post.sessionTitle.isEmpty ? post.subtitle : post.sessionTitle
        post.id = "session@\(post.sessionID.uuidString)"
        post.level = .sessions
        post.title = name
        post.subtitle = sessionSubtitle(post)
        post.discipline = post.sessionActivity == .general ? post.discipline : post.sessionActivity
        post.clips = items
        post.exerciseID = nil
        post.climbUUID = nil
        post.climbResult = nil
        post.overlayDetail = ""
        post.activityChips = chips.count > 1 ? chips : []
        post.stats = ClipFeedPostStats(line: parts.joined(separator: " · "), activityKey: nil, activityTitle: name,
                                       prCount: prs)
        post.captureAt = group.map(\.captureAt).min() ?? post.captureAt
        return post
    }

    /// "Thu 16 Oct · 52 min".
    static func sessionSubtitle(_ post: ClipFeedPost) -> String {
        var parts = [post.sessionStartedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))]
        if let end = post.sessionEndedAt {
            let minutes = Int(end.timeIntervalSince(post.sessionStartedAt) / 60)
            if minutes > 0 { parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Exercises

    /// One album per activity (posts with an identity: a logged exercise, a board climb), newest activity first.
    static func albums(_ posts: [ClipFeedPost]) -> [ClipFeedAlbum] {
        var byKey: [ActivityKey: [ClipFeedPost]] = [:]
        for p in posts where !p.isReel {
            guard let key = albumKey(p) else { continue }
            byKey[key, default: []].append(p)
        }
        return byKey.map { key, members in
            let ordered = members.sorted { $0.sessionStartedAt < $1.sessionStartedAt }
            let latest = ordered[ordered.count - 1]
            return ClipFeedAlbum(key: key, title: latest.stats?.activityTitle ?? latest.title,
                                 discipline: latest.discipline, posts: ordered)
        }
        .sorted { $0.lastDone > $1.lastDone }
    }

    static func albumKey(_ p: ClipFeedPost) -> ActivityKey? {
        if let k = p.stats?.activityKey { return k }
        if let uuid = p.climbUUID { return ActivityKey(exerciseId: LibraryCatalog.kilterExerciseId, nameKey: uuid) }
        return nil
    }

    /// Then vs Now in words: "est. 1RM +12 kg in 9 weeks" · "Project → Sent" · nil when there's nothing to compare.
    static func gain(_ album: ClipFeedAlbum, unit: WeightUnit) -> String? {
        guard album.posts.count > 1 else { return nil }
        let span = since(album.first.sessionStartedAt, album.latest.sessionStartedAt)
        if let a = album.first.stats?.bestKg, let b = album.latest.stats?.bestKg {
            let delta = b - a
            guard abs(delta) >= 0.5 else { return "est. 1RM held \(span)" }
            let shown = WorkoutMath.formatWeight(kg: abs(delta), unit: unit)
            return "est. 1RM \(delta > 0 ? "+" : "−")\(shown) \(unit.display) \(span)"
        }
        if let a = album.first.climbResult?.status, let b = album.latest.climbResult?.status, a != b {
            return "\(a.label) → \(b.label)"
        }
        return nil
    }

    /// "in 9 weeks" / "in 5 days" / "the same day".
    static func since(_ a: Date, _ b: Date) -> String {
        let days = Int(b.timeIntervalSince(a) / 86_400)
        if days >= 14 { return "in \(days / 7) weeks" }
        if days >= 1 { return "in \(days) \(days == 1 ? "day" : "days")" }
        return "the same day"
    }
}
