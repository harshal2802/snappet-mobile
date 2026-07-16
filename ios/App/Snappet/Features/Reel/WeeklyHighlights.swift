import Foundation
import HighlightEngine

// MARK: - Weekly Highlight Reel (highlights P4, pure)
//
// The one capability nothing else in the app has: a CROSS-SESSION montage. Every session of the
// week — gym, Kilter, Apple-Watch import — is stitched onto ONE synthetic timeline (HR series and
// media offsets shifted by the running span), producing a single engine `Workout` the ENTIRE
// existing reel pipeline consumes unchanged: HighlightEngine ranks moments across the whole week,
// `ReelViewModel`/`ReelView` edit it, `ReelExporter` burns the week's stitched HR curve as the
// glass scorebug. PURE — Foundation + engine value types only — unit-tested in
// `WeeklyHighlightsTests` with no simulator.

enum WeeklyHighlights {

    /// A plain-value snapshot of one media-bearing session, built at the store edge
    /// (`WeeklyReelHostView`) from the `@Model`s — nothing SwiftData crosses in here.
    struct SessionInput: Sendable {
        var id: UUID
        var title: String
        var startedAt: Date
        var duration: Double
        var hrSeries: [HRPoint]
        var maxHR: Double?
        var restHR: Double?
        var clips: [SessionHighlightInput.Clip]
        var isClimbing: Bool
        /// Peak-effort / sent-climb windows to boost, in SESSION-relative seconds.
        var boostWindows: [ClosedRange<Double>] = []
    }

    /// The Clips-feed hero card's data (nil = don't show the card): derived from the already-
    /// composed posts, so the feed pays nothing new to decide.
    struct Offer: Equatable, Sendable {
        var sessionCount: Int
        var videoClipCount: Int
        var subtitle: String
    }

    /// The calendar week containing `now` — the window both the hero card and the host build from.
    static func week(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now)
    }

    /// Whether the Clips feed shows the weekly hero, decided over the composed posts (pure, cheap):
    /// ≥ 2 video clips across the week's sessions makes a cut worth offering. Reel posts don't
    /// count — a reel of reels would be circular.
    static func offer(posts: [ClipFeedPost], week: DateInterval) -> Offer? {
        var sessionIDs = Set<UUID>()
        var videos = 0
        for post in posts where !post.isReel && week.contains(post.sessionStartedAt) {
            let count = post.clips.filter { $0.media.kind == "video" && !$0.media.isReel }.count
            if count > 0 {
                videos += count
                sessionIDs.insert(post.sessionID)
            }
        }
        guard videos >= 2 else { return nil }
        let s = sessionIDs.count
        return Offer(sessionCount: s, videoClipCount: videos,
                     subtitle: "\(videos) clips from \(s) session\(s == 1 ? "" : "s") this week")
    }

    /// Stitch the week's sessions onto one synthetic timeline: session i's HR samples, media
    /// offsets, and boost windows all shift by the running sum of the previous sessions' spans.
    /// Sessions are ordered chronologically, so the reel cuts Monday → Sunday. Returns `nil` when
    /// no session brings any usable media.
    static func stitchedWorkout(sessions: [SessionInput]) -> (workout: Workout,
                                                              boostWindows: [ClosedRange<Double>])? {
        let ordered = sessions.sorted { $0.startedAt < $1.startedAt }
        var hr: [HRSample] = []
        var media: [MediaItem] = []
        var boosts: [ClosedRange<Double>] = []
        var shift = 0.0
        var restBpm: Double?
        var maxBpm: Double?

        for s in ordered {
            // Reuse the session→engine bridge (drop-no-duration + default-duration policy) and
            // then shift the session-relative result onto the week timeline.
            let wk = SessionHighlightInput.makeWorkout(
                hrSeries: s.hrSeries, clips: s.clips, duration: s.duration, sport: nil, category: nil)
            hr.append(contentsOf: wk.hr.map { HRSample(t: $0.t + shift, bpm: $0.bpm) })
            media.append(contentsOf: wk.media.map {
                MediaItem(id: $0.id, kind: $0.kind,
                          startOffset: $0.startOffset + shift, duration: $0.duration)
            })
            boosts.append(contentsOf: s.boostWindows.map {
                ($0.lowerBound + shift)...($0.upperBound + shift)
            })
            if let r = s.restHR { restBpm = min(restBpm ?? r, r) }
            if let m = s.maxHR { maxBpm = max(maxBpm ?? m, m) }
            shift += span(of: s, workout: wk)
        }
        guard !media.isEmpty else { return nil }

        let allClimbing = ordered.allSatisfy(\.isClimbing)
        let noneClimbing = ordered.allSatisfy { !$0.isClimbing }
        let workout = Workout(
            activity: allClimbing ? .climbing : (noneClimbing ? .strength : .other),
            duration: shift,
            hr: hr,
            restBpm: restBpm,
            maxBpm: maxBpm,
            media: media)
        return (workout, boosts)
    }

    /// A session's width on the stitched timeline: its duration, stretched to cover any HR sample
    /// or clip that lands past the recorded end — so consecutive sessions can never overlap.
    static func span(of s: SessionInput, workout: Workout) -> Double {
        let lastHR = workout.hr.map(\.t).max() ?? 0
        let lastMedia = workout.media.map(\.endOffset).max() ?? 0
        return max(max(s.duration, 0), max(lastHR, lastMedia)) + 1
    }
}

extension ReelSource {
    /// The Weekly Highlight Reel source: the stitched week as ONE workout, cut with TRIMMED
    /// highlight windows (`trimToHighlights`) so seven days condense into moments — unlike a
    /// session reel, which plays clips full-length. Posts into Clips under the week's most recent
    /// session. Returns `nil` when the week has nothing to cut.
    static func week(sessions: [WeeklyHighlights.SessionInput], now: Date = .now) -> ReelSource? {
        guard let stitched = WeeklyHighlights.stitchedWorkout(sessions: sessions),
              let latest = sessions.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        let interval = WeeklyHighlights.week(containing: now)
        var source = ReelSource(
            id: "week-\(Int(interval.start.timeIntervalSince1970))",
            activity: stitched.workout.activity,
            title: "Weekly Highlights",
            start: interval.start,
            // The stitched snapshot IS the input — manual picks don't apply to a week cut.
            makeWorkout: { _, _ in stitched.workout })
        source.boostWindows = stitched.boostWindows
        source.trimToHighlights = true
        source.postSessionID = latest.id
        source.postTitle = "Your Week — Highlights"
        return source
    }
}
