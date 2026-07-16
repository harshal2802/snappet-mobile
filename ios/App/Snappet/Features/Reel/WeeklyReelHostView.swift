import SwiftUI
import SwiftData

/// Route value for the Weekly Highlight Reel (highlights P4) — pushed by the Clips feed's hero
/// card and the App Library's flagship hero, into whichever `NavigationStack` hosts them.
struct WeeklyReelRoute: Hashable {}

/// The store edge for the Weekly Highlight Reel: snapshots this week's media-bearing sessions
/// (gym + Kilter + Apple-Watch imports) into plain `WeeklyHighlights.SessionInput`s, stitches them
/// via `ReelSource.week`, and hands the result to the SHARED `ReelView` — one reel maker, no new
/// player/editor surface. Too little footage yet → an honest empty state, never a dead screen.
struct WeeklyReelHostView: View {
    @Query private var media: [SessionMedia]
    @Query private var workoutSessions: [WorkoutSession]
    @Query private var kilterSessions: [KilterSession]

    var body: some View {
        let inputs = sessionInputs()
        let videoCount = inputs.reduce(0) { $0 + $1.clips.filter(\.isVideo).count }
        if videoCount >= 2, let source = ReelSource.week(sessions: inputs) {
            ReelView(source: source)
        } else {
            ContentUnavailableView {
                Label("Not enough footage yet", systemImage: "sparkles.tv")
            } description: {
                Text("Film at least two clips during this week's sessions and the weekly cut unlocks — gym, Kilter, and Apple Watch workouts all count.")
            }
            .navigationTitle("Weekly Highlights")
            .accessibilityIdentifier("weeklyReel.empty")
        }
    }

    /// This week's sessions that carry media, snapshotted to plain values. Posted reels are
    /// excluded from the input clips (a reel of reels would be circular); photos ride along —
    /// the planner renders them as stills between the video moments.
    private func sessionInputs() -> [WeeklyHighlights.SessionInput] {
        let week = WeeklyHighlights.week(containing: .now)
        let bySession = Dictionary(grouping: media.filter { !$0.isReel }, by: \.sessionID)

        func clips(_ rows: [SessionMedia]) -> [SessionHighlightInput.Clip] {
            rows.map {
                SessionHighlightInput.Clip(localIdentifier: $0.localIdentifier,
                                           isVideo: $0.kind == .video,
                                           offsetSec: $0.offsetSec, durationSec: $0.durationSec)
            }
        }

        var out: [WeeklyHighlights.SessionInput] = []
        for s in workoutSessions where week.contains(s.startedAt) {
            guard let rows = bySession[s.id], !rows.isEmpty else { continue }
            out.append(.init(id: s.id, title: s.routineName, startedAt: s.startedAt,
                             duration: s.duration, hrSeries: s.hrSeries,
                             maxHR: s.maxHR, restHR: s.restHR,
                             clips: clips(rows), isClimbing: false))
        }
        for k in kilterSessions where week.contains(k.startedAt) {
            guard let rows = bySession[k.id], !rows.isEmpty else { continue }
            out.append(.init(id: k.id, title: k.title ?? "Kilter session", startedAt: k.startedAt,
                             duration: k.duration, hrSeries: k.hrSeries,
                             maxHR: k.maxHR, restHR: k.restHR,
                             clips: clips(rows), isClimbing: true))
        }
        return out
    }
}
