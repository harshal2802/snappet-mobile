import Foundation

// MARK: - Clips grid — months you can read and act on (prompt 173, pure)
//
// The explore grid (▦) grouped covers by month (prompt 167) and a tap jumped to the post. Prompt 173 makes each
// month a summary you can act on — sessions · sends · peak HR, a day strip of the days you trained (tap a day to
// jump to it), and "✦ Make reel" for the month — and each cover tell you what it is at a glance (video length,
// SENT/FLASH, ✦ REEL, peak ♥, favourite). Wireframes: docs/ux-research/clips-grid/. Unit-tested.

enum ClipGridModel {

    struct Month: Identifiable, Equatable {
        var id: String                       // "yyyy-MM"
        var title: String                    // "October 2026"
        var interval: DateInterval           // the calendar month — the month reel's scope
        var posts: [ClipFeedPost]
        var sessions: Int
        var sends: Int
        var peakHR: Int?
        /// Day-of-month → how many posts that day (the day strip).
        var postsByDay: [Int: Int]
        var daysInMonth: Int

        /// "9 sessions · 14 sends · peak 178" — parts with nothing to say drop out.
        var summary: String {
            var parts = ["\(sessions) session\(sessions == 1 ? "" : "s")"]
            if sends > 0 { parts.append("\(sends) send\(sends == 1 ? "" : "s")") }
            if let peakHR { parts.append("peak \(peakHR)") }
            return parts.joined(separator: " · ")
        }

        /// The first post captured on `day`, newest-first like the feed — the day strip's jump target.
        func firstPost(onDay day: Int, calendar: Calendar) -> ClipFeedPost? {
            posts.first { calendar.component(.day, from: $0.sessionStartedAt) == day }
        }
    }

    /// Months newest first. `peak` gives a post's peak HR (from its clips' overlay payloads).
    static func months(_ posts: [ClipFeedPost], peak: (ClipFeedPost) -> Double?,
                       calendar: Calendar = .current, locale: Locale = .current) -> [Month] {
        ClipFeedSections.months(posts, calendar: calendar, locale: locale).compactMap { section in
            guard let first = section.posts.first,
                  let interval = calendar.dateInterval(of: .month, for: first.sessionStartedAt) else { return nil }
            let days = calendar.range(of: .day, in: .month, for: first.sessionStartedAt)?.count ?? 31
            var byDay: [Int: Int] = [:]
            for p in section.posts { byDay[calendar.component(.day, from: p.sessionStartedAt), default: 0] += 1 }
            let peaks = section.posts.compactMap(peak)
            return Month(id: section.id, title: section.title, interval: interval, posts: section.posts,
                         sessions: Set(section.posts.map(\.sessionID)).count,
                         sends: section.posts.filter { $0.climbResult?.status.isSend == true }.count,
                         peakHR: peaks.max().map { Int($0.rounded()) },
                         postsByDay: byDay, daysInMonth: days)
        }
    }

    /// The day strip's shade for a day: 0 = nothing, 1–3 = more posts.
    static func dayLevel(_ count: Int) -> Int { count <= 0 ? 0 : count == 1 ? 1 : count <= 3 ? 2 : 3 }

    /// A cover's video length, "0:24" / "1:05" — nil for photos or unknown durations.
    static func durationLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0.5 else { return nil }
        let s = Int(seconds.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// MARK: - Select mode (prompt 175)

extension ClipGridModel {
    /// The clips a selection covers (every clip of every selected post), for "✦ Make reel" and Hide.
    static func mediaIDs(of selected: Set<String>, in posts: [ClipFeedPost]) -> Set<UUID> {
        Set(posts.filter { selected.contains($0.id) }.flatMap { $0.clips.map(\.media.id) })
    }

    /// The videos to share: each selected post's FIRST video (one file per post keeps the share sheet sane).
    static func shareables(of selected: Set<String>, in posts: [ClipFeedPost]) -> [String] {
        posts.filter { selected.contains($0.id) }
            .compactMap { $0.clips.first { $0.media.kind == "video" && !$0.media.isReel }?.media.localIdentifier
                ?? $0.clips.first { $0.media.kind == "video" }?.media.localIdentifier }
    }

    /// Whether the bulk heart should UN-favourite: only when every selected post already is a favourite.
    static func allFavorite(_ selected: Set<String>, in posts: [ClipFeedPost], isFavorite: (ClipFeedPost) -> Bool) -> Bool {
        let picked = posts.filter { selected.contains($0.id) }
        return !picked.isEmpty && picked.allSatisfy(isFavorite)
    }
}

// MARK: - Move fast (prompt 176)

extension ClipGridModel {
    /// Which month a finger at `fraction` (0 = top … 1 = bottom) of the scrubber points at.
    static func monthIndex(atFraction fraction: Double, count: Int) -> Int? {
        guard count > 0, fraction.isFinite else { return nil }
        return min(count - 1, max(0, Int((min(1, max(0, fraction)) * Double(count)).rounded(.down))))
    }
}

// MARK: - Year level (2026-10-10, wireframe docs/ux-research/clips-grid/zoom-levels.png — option A)

extension ClipGridModel {
    /// One year of the year mosaic: "2026 · 412 clips · 96 sessions".
    struct Year: Equatable {
        var id: String                   // "yyyy"
        var title: String                // "2026"
        var clips: Int
        var sessions: Int
        var summary: String {
            "\(clips) clip\(clips == 1 ? "" : "s") · \(sessions) session\(sessions == 1 ? "" : "s")"
        }
    }

    /// The years the months fall in, by year id ("yyyy" — a month id's prefix).
    static func years(_ months: [Month]) -> [String: Year] {
        var out: [String: Year] = [:]
        var sessions: [String: Set<UUID>] = [:]
        for m in months {
            let y = String(m.id.prefix(4))
            out[y, default: Year(id: y, title: y, clips: 0, sessions: 0)].clips += m.posts.reduce(0) { $0 + $1.clipCount }
            sessions[y, default: []].formUnion(m.posts.map(\.sessionID))
        }
        for (y, s) in sessions { out[y]?.sessions = s.count }
        return out
    }

    /// The year mosaic's small month label — "OCT".
    static func shortMonth(_ month: Month, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f.string(from: month.interval.start).uppercased(with: locale)
    }
}
