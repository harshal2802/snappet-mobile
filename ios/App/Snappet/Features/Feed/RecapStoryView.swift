import SwiftUI
import SwiftData

// MARK: - Recap Feed — Story Player (F6)
//
// Full-bleed Spotify-Wrapped player: auto-advancing segment scenes, tap-right/left, hold-to-pause,
// swipe-down dismiss, per-scene Share into the F4 ShareComposer. Re-runs the SAME FeedComposer scoped
// to a period window (one engine, two callers). Composition + playback are pure (StoryComposition /
// StoryPlayback); this view only renders + drives the clock. Auto-advance is disabled under Reduce Motion.

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

struct RecapStoryView: View {
    let period: StoryPeriod

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query private var workoutSessions: [WorkoutSession]
    @Query private var litEvents: [KilterLitEvent]

    @State private var scenes: [StoryScene] = []
    @State private var playback = StoryPlayback(sceneCount: 1)
    @State private var shareCard: FeedCard?

    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if scenes.isEmpty {
                ProgressView().tint(.white)
            } else {
                let scene = scenes[min(playback.index, scenes.count - 1)]
                content(scene)
            }
        }
        .task { buildIfNeeded() }
        .onReceive(tick) { _ in
            guard !reduceMotion, !scenes.isEmpty else { return }    // Reduce Motion → manual tap only
            if playback.tick(0.05) { dismiss() }
        }
        .sheet(item: $shareCard) { ShareComposerView(card: $0) }
        .accessibilityIdentifier("story.player")
    }

    @ViewBuilder private func content(_ scene: StoryScene) -> some View {
        let accent = color(scene.accent)
        ZStack {
            RadialGradient(colors: [accent.opacity(0.55), .black], center: .top, startRadius: 0, endRadius: 680).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Segment progress bars — filled before current, partial on current.
                HStack(spacing: 4) {
                    ForEach(scenes.indices, id: \.self) { i in
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(.white)
                                    .frame(width: geo.size.width * fill(for: i))
                            }
                        }.frame(height: 3)
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
                    Text(scene.kick.uppercased()).font(.caption.weight(.heavy)).tracking(2).foregroundStyle(.white.opacity(0.85))
                    Text(scene.big).font(.system(size: 56, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white).minimumScaleFactor(0.5).lineLimit(3)
                    Text(scene.small).font(.title3).foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 24)
                Spacer()

                HStack {
                    Text(reduceMotion ? "tap to continue" : "hold to pause").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if let card = scene.card {
                        Button { playback.pause(); shareCard = card } label: {
                            Label("Share scene", systemImage: "square.and.arrow.up").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        }
                        .accessibilityIdentifier("story.share")
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 24)
            }

            // Tap zones (back / next) + hold-to-pause + swipe-down dismiss.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(width: 110).onTapGesture { playback.back() }
                Color.clear.contentShape(Rectangle()).onTapGesture { if playback.next() { dismiss() } }
            }
            .ignoresSafeArea()
            .onLongPressGesture(minimumDuration: 60, maximumDistance: 80, perform: {},
                                onPressingChanged: { pressing in pressing ? playback.pause() : playback.resume() })
            .gesture(DragGesture(minimumDistance: 24).onEnded { if $0.translation.height > 100 { dismiss() } })
        }
    }

    private func fill(for i: Int) -> Double {
        if i < playback.index { return 1 }
        if i == playback.index { return playback.progress }
        return 0
    }

    private func buildIfNeeded() {
        guard scenes.isEmpty else { return }   // memoized — built once per presentation
        let cards = FeedQuery.cards(kilterSessions: kilterSessions, kilterLogs: kilterLogs,
                                    workoutSessions: workoutSessions, litEvents: litEvents,
                                    window: period.window, now: .now)
        let sessionCount = cards.filter { $0.kind == .a1Session || $0.kind == .a2Session }.count
        scenes = StoryComposition.scenes(periodTitle: period.title, sessionCount: sessionCount, cards: cards)
        playback = StoryPlayback(sceneCount: scenes.count)
    }

    private func color(_ accent: StoryAccent) -> Color {
        switch accent {
        case .kilter: return SnappetColor.kilter
        case .workout: return SnappetColor.workout
        case .brand: return SnappetColor.brand
        case .effort: return SnappetColor.performance(forZone: .max)
        }
    }
}
