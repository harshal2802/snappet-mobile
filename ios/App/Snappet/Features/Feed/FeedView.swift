import SwiftUI
import SwiftData
import HighlightEngine

// MARK: - Recap Feed — root scroll (F1)
//
// The middle "Recap" tab. Derives cards on read via the F0 FeedComposer over @Query'd sessions/logs
// (F0b's persisted activities back the writers; the cards themselves are never persisted). Ships the
// Lens bar (F0 pure post-filters, incl. always-available Sessions-only), a Stories-rail placeholder
// (real period labels — F6 activates), keyset-windowed pagination, and the freshness pill.

/// Render-cache for the derived feed: rebuilds the cards only when the underlying @Query content
/// changes (add/remove), so frequent re-renders — lens taps, scroll pagination, the freshness-pill
/// animation — reuse the last composition instead of re-running the full FeedComposer every time.
/// A plain reference type (not an observed @State value) so reading/refreshing it inside `body`
/// doesn't itself invalidate the view.
private final class FeedMemo {
    private var signature: Int?
    private var cachedCards: [FeedCard] = []
    private var cachedIndex = FeedMediaIndex()
    /// Refreshes BOTH the cards and the media-lookup index on a signature miss (one key, so they can
    /// never drift) and returns the cards. Read `index` afterwards in the same body eval — the signature
    /// has settled, so it's the index built against these cards.
    func cards(signature sig: Int,
               buildCards: () -> [FeedCard],
               buildIndex: () -> FeedMediaIndex) -> [FeedCard] {
        if sig != signature { signature = sig; cachedCards = buildCards(); cachedIndex = buildIndex() }
        return cachedCards
    }
    var index: FeedMediaIndex { cachedIndex }
}

struct FeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \KilterSession.startedAt, order: .reverse) private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var workoutSessions: [WorkoutSession]
    @Query private var litEvents: [KilterLitEvent]
    @Query private var allMedia: [SessionMedia]
    // F2 batched membership: hoist the reaction/save corpus to ONE query each (was 2 FetchDescriptors
    // PER card in FeedReactionStrip.task). @Model-backed, so both auto-refresh on any toggle.
    @Query private var feedReactions: [FeedReaction]
    @Query private var feedSaveItems: [FeedSaveItem]

    @State private var lens: FeedLensChip = .all
    @State private var visibleCount = 12
    @State private var seen: Set<String> = []
    @State private var newCount = 0
    /// Which layout the feed body renders — the list scroll (F1) or the inline masonry wall (F7).
    /// An inline flip (not a modal sheet): the grid toggle flips this over the SAME visible corpus.
    @State private var layout: FeedLayout = .list
    @State private var presentedStory: StoryPeriod?
    @State private var memo = FeedMemo()
    /// R10 (F1 polish): flips true once the first compose/appear completes. Until then a populated
    /// store can briefly show the empty state while SwiftData hydrates — so we show a redacted
    /// skeleton instead of "no recap yet" on cold launch. Flipped in `.task` (post first layout).
    @State private var hasComposedOnce = false

    private let pageSize = 12
    private let topAnchor = "feed.top"

    // MARK: Derivation (derive-on-read; no card persistence)

    private func composed() -> [FeedCard] {
        memo.cards(
            signature: feedSignature(),
            buildCards: {
                FeedQuery.cards(kilterSessions: kilterSessions, kilterLogs: kilterLogs,
                                workoutSessions: workoutSessions, litEvents: litEvents,
                                sessionMedia: allMedia, now: .now)
            },
            buildIndex: {
                FeedMediaIndex(kilterSessions: kilterSessions, workoutSessions: workoutSessions,
                               kilterLogs: kilterLogs, allMedia: allMedia)
            })
    }

    /// Cheap content fingerprint: counts of every source + the newest session/workout date. Changes
    /// when records are added/removed (the common case), so the memo above can safely reuse the last
    /// composition across pure UI re-renders. Date drift (recency decay) is intentionally ignored —
    /// ordering stays stable while the tab is on screen and refreshes the moment data changes.
    private func feedSignature() -> Int {
        var h = Hasher()
        h.combine(kilterSessions.count)
        h.combine(kilterLogs.count)
        h.combine(workoutSessions.count)
        h.combine(litEvents.count)
        h.combine(allMedia.count)
        h.combine(kilterSessions.first?.startedAt)      // @Query sorted newest-first
        h.combine(workoutSessions.first?.startedAt)
        return h.finalize()
    }

    /// O(1)-membership sets for the reaction strips, rebuilt once per render from the hoisted queries
    /// (instead of 2 FetchDescriptor scans per visible card). Toggles mutate the @Model tables, so the
    /// queries auto-refresh and these recompute on the next body eval. NOT folded into `feedSignature()`
    /// — they don't affect card composition, only the strip's heart/bookmark fill.
    private var reactedIds: Set<String> { Set(feedReactions.map(\.activityContentId)) }
    private var savedIds: Set<String> { Set(feedSaveItems.map(\.activityContentId)) }

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
                        // R10 (F1 polish): on cold launch, before the first compose/appear completes,
                        // show a redacted skeleton instead of the empty state — a populated store can
                        // momentarily read empty while SwiftData hydrates, and we don't want a flash of
                        // "no recap yet". Once `hasComposedOnce` flips (and it's still empty) → real empty.
                        if hasComposedOnce {
                            emptyState
                        } else {
                            feedSkeleton
                        }
                    } else {
                        switch layout {
                        case .list: listBody(visible: visible, filtered: filtered)
                        // F7: the masonry wall renders INLINE over the SAME visible corpus (one
                        // composition, two layouts). Pagination is the shared keyset: each tile's
                        // `.onAppear` advances `visibleCount` via the same `loadMoreIfNeeded` the list uses.
                        case .grid: WallView(cards: visible,
                                             loadMore: { loadMoreIfNeeded(card: $0, in: filtered) })
                        }
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
                    // F7: inline layout flip (no modal sheet) — list ↔ masonry wall over the same corpus.
                    Button {
                        withAnimation(.snappy) {
                            layout.toggle()
                        }
                    } label: {
                        Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                    }
                    .accessibilityIdentifier("feed.gridToggle")
                }
            }
            .fullScreenCover(item: $presentedStory) { RecapStoryView(period: $0) }
        }
        .task {
            if seen.isEmpty { seen = FeedFreshness.topIDs(all) }
            // R10 (F1 polish): first compose/appear is done — drop the skeleton. After this an empty
            // corpus is a genuine empty state, not a cold-launch hydration flash.
            hasComposedOnce = true
        }
        // R10 (F1 polish): optimistic insert — when a NEW card arrives at the head (a just-logged
        // session), slide it in rather than snap. Scoped to the head id only (not the whole id set) so
        // pagination appends and lens switches don't trigger a full-list reshuffle animation, and we
        // don't allocate an id array every body eval. Never yanks scroll (the overlay pill owns that).
        .animation(.snappy, value: visible.first?.id)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { seen = FeedFreshness.topIDs(composed()) }
            if phase == .active { withAnimation { newCount = FeedFreshness.newCount(current: composed(), seen: seen) } }
        }
    }

    // MARK: Pieces

    /// The F1 list layout: the LazyVStack of full Pulse-Pro cards with the R6 carousel media +
    /// reaction strips. Only rendered in `.list` mode — in `.grid` mode the inline `WallView` takes over.
    @ViewBuilder private func listBody(visible: [FeedCard], filtered: [FeedCard]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(visible, id: \.id) { card in
                VStack(spacing: 8) {
                    NavigationLink(value: card) {
                        // F3b (R6): thread the session media so the a1 card hosts its in-card carousel.
                        FeedCardView(card: card, media: cardMedia(for: card))
                    }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            FeedInteractionWriter.toggleReaction(contentId: card.contentId, in: context)
                        })
                        .onLongPressGesture(minimumDuration: 0.45) {
                            FeedInteractionWriter.toggleSave(contentId: card.contentId, in: context)
                        }
                    if !card.contentId.isEmpty {
                        FeedReactionStrip(contentId: card.contentId,
                                          reacted: reactedIds.contains(card.contentId),
                                          saved: savedIds.contains(card.contentId))
                            .padding(.horizontal, 6)
                    }
                }
                .onAppear { loadMoreIfNeeded(card: card, in: filtered) }
            }
        }
        .padding(.horizontal, SnappetSpacing.lg)
        .padding(.bottom, 24)
    }

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

    /// R10 (F1 polish): cold-launch placeholder — a couple of redacted card-shaped rows shown until
    /// the first compose completes (`hasComposedOnce`). A populated store paints these for a frame
    /// instead of flashing the empty state; a genuinely empty store crosses straight to `emptyState`.
    private var feedSkeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent session").font(.headline)
                    Text("Loading your recap cards").font(.subheadline)
                    RoundedRectangle(cornerRadius: 14, style: .continuous).frame(height: 120)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SnappetSpacing.lg)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(.horizontal, SnappetSpacing.lg)
        .padding(.top, 8)
        .redacted(reason: .placeholder)
        .accessibilityIdentifier("feed.skeleton")
    }

    // MARK: Behavior

    /// The Kilter session id behind a climb-session card (the source ref the carousel reads HR/media from).
    private func sessionId(for card: FeedCard) -> UUID? {
        card.sourceRefs.first { $0.objectKind == "kilterSession" }.flatMap { UUID(uuidString: $0.ref) }
    }

    // MARK: F3b (R6) — in-card carousel media bundle

    /// The session-media bundle for an a1 climb-session card's carousel + fullscreen viewer: the
    /// session's clips (offset-ordered downstream), its HR series/maxHR (for the editor overlay), a
    /// name resolver, and the Animate `clipContext`. `nil` for non-climb cards or sessions with no media
    /// → the card shows the still `DisciplineHero` + cheap "N clips" affordance (no carousel). Snapshots
    /// the `@Model`s into plain values here on the `@MainActor` so SwiftData never crosses into the viewer.
    private func cardMedia(for card: FeedCard) -> FeedCardMedia? {
        guard case .climbSession = card.payload, let sid = sessionId(for: card) else { return nil }
        let index = memo.index                       // settled by composed() earlier this eval
        let media = index.mediaBySession[sid] ?? []  // O(1) instead of allMedia.filter
        guard !media.isEmpty else { return nil }
        let resolver = FeedMediaResolver(index: index)
        return FeedCardMedia(clips: media.map(MediaInput.from),
                             hrSeries: resolver.hrSeries(for: sid), maxHR: resolver.maxHR(for: sid),
                             nameFor: resolver.nameResolver(for: sid),
                             clipContext: resolver.clipContext(for: sid, card: card))
    }

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

// MARK: - Feed layout (F7)

/// The two layouts the feed body flips between (inline, not a sheet): the F1 list scroll and the
/// F7 masonry wall — both over the SAME composed + lens-filtered + windowed corpus.
enum FeedLayout {
    case list, grid
    mutating func toggle() { self = self == .list ? .grid : .list }
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
