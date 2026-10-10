import SwiftUI
import SwiftData

/// Route value for the Weekly Highlight Reel (highlights P4) — pushed by the Clips feed's hero
/// card and the App Library's flagship hero, into whichever `NavigationStack` hosts them.
struct WeeklyReelRoute: Hashable {}

/// What a Clips reel covers (prompt 173/175): this week (the hero card), a month (the grid's month header), or
/// a hand-picked set of clips (the grid's select mode — `SessionMedia.id`s).
enum ClipsReelScope: Hashable {
    case week
    case month(DateInterval, title: String)
    case clips(Set<UUID>)
}

/// Pushes the shared reel builder for a scope — from the Clips grid.
struct ClipsReelRoute: Hashable { var scope: ClipsReelScope }

/// The store edge for the Weekly Highlight Reel: snapshots this week's media-bearing sessions
/// (gym + Kilter + Apple-Watch imports) into plain `WeeklyHighlights.SessionInput`s, stitches them
/// via `ReelSource.week`, and hands the result to the SHARED `ReelView` — one reel maker, no new
/// player/editor surface. Too little footage yet → an honest empty state, never a dead screen.
struct WeeklyReelHostView: View {
    /// This week by default (the hero card / App Library); a month or picked clips from the Clips grid.
    var scope: ClipsReelScope = .week

    @Query private var media: [SessionMedia]
    @Query private var workoutSessions: [WorkoutSession]
    @Query private var kilterSessions: [KilterSession]

    var body: some View {
        let inputs = sessionInputs()
        let videoCount = inputs.reduce(0) { $0 + $1.clips.filter(\.isVideo).count }
        if videoCount >= 1, let source = reelSource(inputs), scope != .week || videoCount >= 2 {
            ReelView(source: source)
        } else {
            ContentUnavailableView {
                Label("Not enough footage yet", systemImage: "sparkles.tv")
            } description: {
                Text(scope == .week
                     ? "Film at least two clips during this week's sessions and the weekly cut unlocks — gym, Kilter, and Apple Watch workouts all count."
                     : "There's no video in this selection to cut a reel from.")
            }
            .navigationTitle(scope == .week ? "Weekly Highlights" : "Highlights")
            .accessibilityIdentifier("weeklyReel.empty")
        }
    }

    private func reelSource(_ inputs: [WeeklyHighlights.SessionInput]) -> ReelSource? {
        switch scope {
        case .week:
            return ReelSource.week(sessions: inputs)
        case .month(let interval, let title):
            return ReelSource.collection(sessions: inputs, id: "month-\(Int(interval.start.timeIntervalSince1970))",
                                         title: title, postTitle: "\(title) — Highlights",
                                         start: interval.start, trimToHighlights: true)
        case .clips(let ids):
            return ReelSource.collection(sessions: inputs, id: "picked-\(ids.count)-\(ids.hashValue)",
                                         title: "Your picks", postTitle: "My picks — Highlights",
                                         start: inputs.map(\.startedAt).min() ?? .now, trimToHighlights: false)
        }
    }

    /// This week's sessions that carry media, snapshotted to plain values. Posted reels are
    /// excluded from the input clips (a reel of reels would be circular); photos ride along —
    /// the planner renders them as stills between the video moments.
    private func sessionInputs() -> [WeeklyHighlights.SessionInput] {
        // Which sessions/clips the scope covers (prompt 173/175).
        let interval: DateInterval? = {
            switch scope {
            case .week: return WeeklyHighlights.week(containing: .now)
            case .month(let i, _): return i
            case .clips: return nil                                  // any day — the picks decide
            }
        }()
        let picked: Set<UUID>? = { if case .clips(let ids) = scope { return ids }; return nil }()
        let rows = media.filter { !$0.isReel && (picked?.contains($0.id) ?? true) }
        let bySession = Dictionary(grouping: rows, by: \.sessionID)
        func inScope(_ d: Date) -> Bool { interval?.contains(d) ?? true }

        func clips(_ rows: [SessionMedia]) -> [SessionHighlightInput.Clip] {
            rows.map {
                SessionHighlightInput.Clip(localIdentifier: $0.localIdentifier,
                                           isVideo: $0.kind == .video,
                                           offsetSec: $0.offsetSec, durationSec: $0.durationSec)
            }
        }

        var out: [WeeklyHighlights.SessionInput] = []
        for s in workoutSessions where inScope(s.startedAt) {
            guard let rows = bySession[s.id], !rows.isEmpty else { continue }
            out.append(.init(id: s.id, title: s.routineName, startedAt: s.startedAt,
                             duration: s.duration, hrSeries: s.hrSeries,
                             maxHR: s.maxHR, restHR: s.restHR,
                             clips: clips(rows), isClimbing: false))
        }
        for k in kilterSessions where inScope(k.startedAt) {
            guard let rows = bySession[k.id], !rows.isEmpty else { continue }
            out.append(.init(id: k.id, title: k.title ?? "Kilter session", startedAt: k.startedAt,
                             duration: k.duration, hrSeries: k.hrSeries,
                             maxHR: k.maxHR, restHR: k.restHR,
                             clips: clips(rows), isClimbing: true))
        }
        return out
    }
}
