import Foundation
import SwiftData

/// **The Instagram-style post's words** (Clips redesign part 1, prompt 196; `docs/ux-research/clips-feed-levels/`):
/// what the post's stats line says ("4 × 8 @ 75 kg · ▲ PR"), each set's detail for the set chips ("8 × 75 kg"), and
/// which activity it belongs to (for "View all 14 Bench Press clips"); plus the user's caption, stored as a
/// `FeedReaction` row (no new model — already backed up), and the #tags suggested for it. Pure.
struct ClipFeedPostStats: Sendable, Equatable {
    /// The session's effort in a few words — the Library's "Last:" line (`LibraryCatalog.lastLine`).
    var line: String
    /// This session's top set beats every earlier session of the activity (strength: est. 1RM).
    var isPR: Bool = false
    /// setIndex → "8 × 75 kg" / "0:42" / "Sent · 0:31" — the set chips under the caption.
    var setDetail: [Int: String] = [:]
    /// The activity (for "View all N clips" → its Activity page); nil when it has no identity.
    var activityKey: ActivityKey?
    /// The activity's display name ("Bench Press").
    var activityTitle: String
    /// The session's best est. 1RM (kg) — the Exercises album's "Then vs Now" gain (prompt 197).
    var bestKg: Double? = nil
    /// A whole-session post's PR count ("▲ 2 PRs", prompt 197); 0 elsewhere (an activity post uses `isPR`).
    var prCount: Int = 0
}

enum ClipPostStats {

    /// The stats for one exercise in one session. `priorBestKg` is the activity's best est. 1RM in EARLIER sessions.
    static func make(_ ex: SessionExercise, title: String, key: ActivityKey?, priorBestKg: Double?,
                     unit: WeightUnit) -> ClipFeedPostStats? {
        let distanceUnit: DistanceUnit = unit == .lb ? .mi : .km
        guard let line = LibraryCatalog.lastLine(ex, unit: unit, distanceUnit: distanceUnit) else { return nil }
        var detail: [Int: String] = [:]
        for (i, set) in ex.sets.enumerated() where set.completedAt != nil {
            detail[i] = SetMeasure.displaySummary(set, discipline: ex.discipline, kind: ex.kind, unit: unit,
                                                  distanceUnit: distanceUnit)
        }
        var pr = false
        if ex.discipline == .strength, let prior = priorBestKg, let best = bestKg(ex) { pr = best > prior + 0.01 }
        return ClipFeedPostStats(line: line, isPR: pr, setDetail: detail, activityKey: key, activityTitle: title,
                                 bestKg: bestKg(ex))
    }

    /// An exercise's best est. 1RM (kg) this session — the PR yardstick.
    static func bestKg(_ ex: SessionExercise) -> Double? {
        ex.sets.compactMap { s -> Double? in
            guard s.completedAt != nil, let r = s.actualReps, r > 0, let w = s.actualWeight, w > 0 else { return nil }
            return ActivityDashboard.oneRepMax(kg: WorkoutMath.toKg(w, s.weightUnit), reps: r)
        }.max()
    }

    /// The post's stats line as shown: "4 × 8 @ 75 kg · ▲ PR".
    static func display(_ stats: ClipFeedPostStats) -> String {
        guard let pr = prText(stats) else { return stats.line }
        return "\(stats.line) · \(pr)"
    }

    /// "▲ PR" / "▲ 2 PRs" — nil when there's none.
    static func prText(_ stats: ClipFeedPostStats) -> String? {
        if stats.prCount > 1 { return "▲ \(stats.prCount) PRs" }
        return stats.isPR || stats.prCount == 1 ? "▲ PR" : nil
    }
}

// MARK: - Captions

/// The user's words on a post (prompt 196) + what the post shows. Stored as a `FeedReaction`
/// (`typeRaw == ClipCaption.reactionType`, `activityContentId == "clippost:<post.id>"`, `value` = this as JSON).
struct ClipCaption: Codable, Equatable, Sendable {
    var text: String = ""
    var showStats: Bool = true
    var showSets: Bool = true
    var showHR: Bool = true

    static let reactionType = "clipCaption"
    static func contentID(postID: String) -> String { "clippost:\(postID)" }

    var isDefault: Bool { self == ClipCaption() }

    func encoded() -> String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ raw: String?) -> ClipCaption? {
        raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ClipCaption.self, from: $0) }
    }

    /// The #tags written in the text — searchable.
    var tags: [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            guard word.hasPrefix("#"), word.count > 1 else { return nil }
            return String(word.dropFirst()).trimmingCharacters(in: .punctuationCharacters).lowercased()
        }
    }

    /// #tags to offer for a post (not already in the text): #PR, the session, the place, the activity.
    static func suggestions(post: ClipFeedPost, text: String) -> [String] {
        func slug(_ s: String) -> String? {
            let t = s.lowercased().filter { $0.isLetter || $0.isNumber }
            return t.count >= 2 && t.count <= 24 ? t : nil
        }
        var out: [String] = []
        if post.stats?.isPR == true { out.append("PR") }
        if post.climbResult?.status.isSend == true { out.append("sent") }
        if let s = slug(post.sessionTitle) { out.append(s) }
        if let s = slug(post.stats?.activityTitle ?? post.title) { out.append(s) }
        if let fest = post.festival, let s = slug(fest.name) { out.append(s) }
        let have = Set(ClipCaption(text: text).tags)
        var seen = Set<String>()
        return out.filter { have.contains($0.lowercased()) == false && seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Store

/// Captions by post id (prompt 196) — a cache of the `clipCaption` `FeedReaction` rows, so each card's read never
/// fetches. Re-read on every feed rebuild (a backup restore shows up), written when the editor saves.
@Observable @MainActor final class ClipCaptionStore {
    private var context: ModelContext?
    private(set) var byPost: [String: ClipCaption] = [:]

    func attach(_ context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        guard let context else { return }
        let type = ClipCaption.reactionType
        let rows = (try? context.fetch(FetchDescriptor<FeedReaction>(predicate: #Predicate { $0.typeRaw == type }))) ?? []
        var out: [String: ClipCaption] = [:]
        for r in rows.sorted(by: { $0.createdAt < $1.createdAt }) where r.activityContentId.hasPrefix("clippost:") {
            if let c = ClipCaption.decode(r.value) { out[String(r.activityContentId.dropFirst("clippost:".count))] = c }
        }
        if out != byPost { byPost = out }
    }

    func caption(for postID: String) -> ClipCaption { byPost[postID] ?? ClipCaption() }

    /// Save (or clear, when back to the defaults) a post's caption — one row per post.
    func save(_ caption: ClipCaption, for postID: String) {
        guard let context else { return }
        let type = ClipCaption.reactionType
        let content = ClipCaption.contentID(postID: postID)
        let rows = (try? context.fetch(FetchDescriptor<FeedReaction>(
            predicate: #Predicate { $0.typeRaw == type && $0.activityContentId == content }))) ?? []
        rows.forEach(context.delete)
        var trimmed = caption
        trimmed.text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isDefault {
            context.insert(FeedReaction(activityContentId: content, typeRaw: type, value: trimmed.encoded()))
            byPost[postID] = trimmed
        } else {
            byPost[postID] = nil
        }
        try? context.save()
    }
}
