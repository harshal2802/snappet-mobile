import SwiftUI
import SwiftData

// MARK: - Recap Feed — root scroll (F1)
//
// The middle "Recap" tab. Derives cards on read via the F0 FeedComposer over @Query'd sessions/logs
// (F0b's persisted activities back the writers; the cards themselves are never persisted). Ships the
// Lens bar (F0 pure post-filters, incl. always-available Sessions-only), a Stories-rail placeholder
// (real period labels — F6 activates), keyset-windowed pagination, and the freshness pill.

struct FeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \KilterSession.startedAt, order: .reverse) private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var workoutSessions: [WorkoutSession]
    @Query private var litEvents: [KilterLitEvent]
    @Query private var allMedia: [SessionMedia]

    @State private var lens: FeedLensChip = .all
    @State private var visibleCount = 12
    @State private var seen: Set<String> = []
    @State private var newCount = 0
    @State private var showingWallPlaceholder = false
    @State private var presentedStory: StoryPeriod?

    private let pageSize = 12
    private let topAnchor = "feed.top"

    // MARK: Derivation (derive-on-read; no card persistence)

    private func composed() -> [FeedCard] {
        FeedQuery.cards(kilterSessions: kilterSessions, kilterLogs: kilterLogs,
                        workoutSessions: workoutSessions, litEvents: litEvents,
                        sessionMedia: allMedia, now: .now)
    }

    var body: some View {
        let all = composed()
        let filtered = FeedComposer.filter(all, lens: lens.lens)
        let visible = FeedPagination.window(filtered, count: visibleCount)

        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id(topAnchor)
                    storiesRail
                    lensBar
                    if visible.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(visible) { card in
                                VStack(spacing: 8) {
                                    NavigationLink(value: card) { FeedCardView(card: card) }
                                        .buttonStyle(.plain)
                                        .accessibilityElement(children: .combine)
                                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                                            FeedInteractionWriter.toggleReaction(contentId: card.contentId, in: context)
                                        })
                                        .onLongPressGesture(minimumDuration: 0.45) {
                                            FeedInteractionWriter.toggleSave(contentId: card.contentId, in: context)
                                        }
                                    if !card.contentId.isEmpty {
                                        FeedReactionStrip(contentId: card.contentId).padding(.horizontal, 6)
                                    }
                                }
                                .onAppear { loadMoreIfNeeded(card: card, in: filtered) }
                            }
                        }
                        .padding(.horizontal, SnappetSpacing.lg)
                        .padding(.bottom, 24)
                    }
                }
                .overlay(alignment: .top) {
                    if let text = FeedFreshness.pillText(newCount: newCount) {
                        Button {
                            withAnimation { proxy.scrollTo(topAnchor, anchor: .top) }
                            dismissPill(current: all)
                        } label: {
                            Label(text, systemImage: "arrow.up.circle.fill")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundStyle(Color.black)
                                .background(SnappetColor.brand, in: Capsule())
                                .shadow(color: SnappetColor.brand.opacity(0.5), radius: 10, y: 4)
                        }
                        .accessibilityIdentifier("feed.pill")
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .refreshable { dismissPill(current: composed()) }
                .navigationDestination(for: FeedCard.self) { CardDetailView(card: $0) }
            }
            .background(SnappetColor.paper)
            .navigationTitle("Recap")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingWallPlaceholder = true } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("feed.gridToggle")
                }
            }
            .sheet(isPresented: $showingWallPlaceholder) { WallView() }
            .fullScreenCover(item: $presentedStory) { RecapStoryView(period: $0) }
        }
        .task { if seen.isEmpty { seen = FeedFreshness.topIDs(all) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { seen = FeedFreshness.topIDs(composed()) }
            if phase == .active { withAnimation { newCount = FeedFreshness.newCount(current: composed(), seen: seen) } }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var storiesRail: some View {
        // Degrade-by-absence: a period cover shows only when its recap is eligible (week/month have a
        // session in-window; year needs >=6 months of history). No eligible period → no rail (no dead chip).
        let eligible = StoryComposition.eligiblePeriods(
            sessionDates: kilterSessions.map(\.startedAt) + workoutSessions.compactMap(\.completedAt), now: .now)
        if !eligible.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if eligible.contains(.week) {
                        Button { presentedStory = .week } label: {
                            StoryCoverPlaceholder(title: "This Week", icon: "sparkles", accent: SnappetColor.kilter, isNew: true)
                        }.buttonStyle(.plain)
                    }
                    if eligible.contains(.month) {
                        Button { presentedStory = .month } label: {
                            StoryCoverPlaceholder(title: "This Month", icon: "calendar", accent: SnappetColor.workout, isNew: false)
                        }.buttonStyle(.plain)
                    }
                    if eligible.contains(.year) {
                        Button { presentedStory = .year } label: {
                            StoryCoverPlaceholder(title: "Year in Climb", icon: "trophy.fill", accent: SnappetColor.brand, isNew: false)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, SnappetSpacing.lg).padding(.vertical, 4)
            }
            .accessibilityIdentifier("feed.stories")
        }
    }

    private var lensBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(FeedLensChip.allCases) { chip in
                    let on = chip == lens
                    Button { lens = chip; visibleCount = pageSize } label: {
                        Text(chip.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(on ? Color.black : SnappetColor.ink)
                            .background(on ? SnappetColor.kilter : SnappetColor.surfaceMuted, in: Capsule())
                    }
                    .accessibilityIdentifier("feed.lens.\(chip.rawValue)")
                }
            }
            .padding(.horizontal, SnappetSpacing.lg)
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 44, weight: .semibold)).foregroundStyle(SnappetColor.kilter)
            Text("Your Recap starts with your first session")
                .font(.headline).multilineTextAlignment(.center)
            Text("Log a Kilter climb or a workout and it shows up here — with PRs, streaks and recaps as you go.")
                .font(.subheadline).foregroundStyle(SnappetColor.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.top, 60)
        .accessibilityIdentifier("feed.empty")
    }

    // MARK: Behavior

    private func loadMoreIfNeeded(card: FeedCard, in filtered: [FeedCard]) {
        guard let idx = filtered.firstIndex(where: { $0.id == card.id }) else { return }
        if idx >= visibleCount - 3 && visibleCount < filtered.count {
            visibleCount = min(visibleCount + pageSize, filtered.count)
        }
    }

    private func dismissPill(current: [FeedCard]) {
        withAnimation { newCount = 0 }
        seen = FeedFreshness.topIDs(current)
    }
}

// MARK: - Lens chips

enum FeedLensChip: String, CaseIterable, Identifiable {
    case all, climbing, strength, effort, milestones, sessions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .climbing: return "Climbing"
        case .strength: return "Strength"
        case .effort: return "Effort"
        case .milestones: return "Milestones"
        case .sessions: return "Sessions"
        }
    }
    var lens: FeedLens {
        switch self {
        case .all: return .all
        case .climbing: return .category(.climbing)
        case .strength: return .category(.strength)
        case .effort: return .category(.effort)
        case .milestones: return .category(.milestone)
        case .sessions: return .sessionsOnly
        }
    }
}

// MARK: - Placeholders (F6/F7 activate)

private struct StoryCoverPlaceholder: View {
    let title: String
    let icon: String
    let accent: Color
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Image(systemName: icon).font(.subheadline.weight(.bold)).foregroundStyle(accent)
            Spacer(minLength: 0)
            Text(title).font(.caption.weight(.heavy)).foregroundStyle(SnappetColor.ink).lineLimit(2)
            Text("recap").font(.caption2).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(width: 88, height: 116, alignment: .leading)
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isNew ? accent : SnappetColor.hairline, lineWidth: isNew ? 2 : 0.5))
    }
}
