import SwiftUI
import SwiftData

// MARK: - Recap Feed — Story Player (F6)
//
// The Spotify-Wrapped-grammar player: full-bleed swipeable scenes, tap-right to advance / tap-left to
// go back, progress bars on top. It re-runs the SAME FeedComposer scoped to a period window (one engine,
// two callers) — sparse periods yield fewer scenes, rich periods more. Per-scene share is wired in F4.

enum StoryPeriod: String, Identifiable, CaseIterable {
    case week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: return "This Week"
        case .month: return "This Month"
        case .year: return "Year in Climb"
        }
    }
    var window: FeedWindow {
        switch self {
        case .week: return .thisWeek
        case .month: return .thisMonth
        case .year: return .thisYear
        }
    }
}

private struct StoryScene: Identifiable {
    let id = UUID()
    var kick: String
    var big: String
    var small: String
    var accent: Color
}

struct RecapStoryView: View {
    let period: StoryPeriod

    @Environment(\.dismiss) private var dismiss
    @Query private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query private var workoutSessions: [WorkoutSession]
    @Query private var litEvents: [KilterLitEvent]

    @State private var index = 0

    var body: some View {
        let scenes = buildScenes()
        let current = scenes.indices.contains(index) ? scenes[index] : scenes[0]

        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [current.accent.opacity(0.55), .black],
                           center: .top, startRadius: 0, endRadius: 680).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(scenes.indices, id: \.self) { i in
                        Capsule().fill(Color.white.opacity(i <= index ? 1 : 0.3)).frame(height: 3)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 14)

                HStack {
                    Label(period.title, systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(.white)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                        .accessibilityIdentifier("story.close")
                }
                .padding(.horizontal, 16).padding(.top, 12)

                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Text(current.kick.uppercased()).font(.caption.weight(.heavy)).tracking(2).foregroundStyle(.white.opacity(0.85))
                    Text(current.big).font(.system(size: 56, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white).minimumScaleFactor(0.5).lineLimit(3)
                    Text(current.small).font(.title3).foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 24)
                Spacer()

                HStack {
                    Text("tap to continue").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Label("Share scene", systemImage: "square.and.arrow.up").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 18).padding(.bottom, 24)
            }

            // Tap zones: left third → back, right two-thirds → next.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                    .onTapGesture { index = max(0, index - 1) }
                    .frame(width: 110)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { advance(count: scenes.count) }
            }
            .ignoresSafeArea()
        }
        .accessibilityIdentifier("story.player")
    }

    private func advance(count: Int) {
        if index < count - 1 { index += 1 } else { dismiss() }
    }

    private func buildScenes() -> [StoryScene] {
        let cards = FeedQuery.cards(kilterSessions: kilterSessions, kilterLogs: kilterLogs,
                                    workoutSessions: workoutSessions, litEvents: litEvents,
                                    window: period.window, now: .now)
        var scenes: [StoryScene] = []
        let sessions = cards.filter { $0.kind == .a1Session || $0.kind == .a2Session }.count
        scenes.append(StoryScene(kick: period.title, big: "\(sessions)",
                                 small: sessions == 1 ? "session logged" : "sessions logged",
                                 accent: SnappetColor.kilter))

        for card in cards.filter({ ![.a1Session, .a2Session].contains($0.kind) }).prefix(6) {
            scenes.append(scene(for: card))
        }
        if scenes.count == 1 {
            scenes.append(StoryScene(kick: "Keep going", big: "Log more",
                                     small: "to unlock your \(period.title.lowercased()) story",
                                     accent: SnappetColor.workout))
        }
        return scenes
    }

    private func scene(for card: FeedCard) -> StoryScene {
        switch card.payload {
        case .gradePR(let p):
            return StoryScene(kick: "New hardest ever", big: p.newGrade,
                              small: p.previousGrade.map { "up from \($0)" } ?? "your first peak", accent: SnappetColor.brand)
        case .pyramid(let p):
            return StoryScene(kick: "Your pyramid", big: p.maxGrade ?? "—",
                              small: "\(p.totalSends) sends across \(p.rows.filter { $0.sends > 0 }.count) grades", accent: SnappetColor.kilter)
        case .streak(let p):
            return StoryScene(kick: "On a roll", big: "\(p.days)", small: "days in a row", accent: SnappetColor.kilter)
        case .weeklyVolume(let p):
            return StoryScene(kick: "Volume", big: "\(p.buckets.last?.sends ?? 0)", small: "sends this week", accent: SnappetColor.kilter)
        case .mostClimbs(let p):
            return StoryScene(kick: "Biggest session", big: "\(p.count)", small: "climbs in one go", accent: SnappetColor.kilter)
        case .effort(let p):
            return StoryScene(kick: "Effort", big: "\(p.maxBpm)", small: "peak BPM · \(p.trimp) TRIMP", accent: SnappetColor.performance(forZone: .max))
        case .hardestEffort(let p):
            return StoryScene(kick: "Hardest-effort send", big: p.grade, small: "\(p.peakBpm) bpm at the top", accent: SnappetColor.performance(forZone: .max))
        case .hrTrend(let p):
            return StoryScene(kick: "HR trend", big: "\(p.points.last?.avgBpm ?? 0)", small: "recent avg BPM", accent: SnappetColor.workout)
        case .liftPR(let p):
            return StoryScene(kick: "Lift PR", big: "\(Int(p.oneRepMaxKg.rounded())) kg", small: "\(p.exerciseName) est. 1RM", accent: SnappetColor.brand)
        case .onTheBoard(let p):
            return StoryScene(kick: "On the board", big: "\(p.litCount)", small: "climbs lit", accent: SnappetColor.kilter)
        case .climbSession(let p):
            return StoryScene(kick: "Session", big: p.hardestSendGrade ?? "—", small: "\(p.sends) sends", accent: SnappetColor.kilter)
        case .workoutSession(let p):
            return StoryScene(kick: "Workout", big: "\(p.setCount)", small: "sets", accent: SnappetColor.workout)
        }
    }
}
