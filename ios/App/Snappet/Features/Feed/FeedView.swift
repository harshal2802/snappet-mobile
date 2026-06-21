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
    private var cached: [FeedCard] = []
    func cards(signature sig: Int, build: () -> [FeedCard]) -> [FeedCard] {
        if sig != signature { signature = sig; cached = build() }
        return cached
    }
}

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
    /// Which layout the feed body renders — the list scroll (F1) or the inline masonry wall (F7).
    /// An inline flip (not a modal sheet): the grid toggle flips this over the SAME visible corpus.
    @State private var layout: FeedLayout = .list
    @State private var presentedStory: StoryPeriod?
    @State private var memo = FeedMemo()

    // MARK: F3 (R2) — single active inline-clip player (scroll-center tracking)
    /// Each visible card's frame in the `feedScroll` coordinate space, keyed by the card's STABLE id
    /// (not its ForEach position) — index↔card mapping is unstable across lens/filter/pagination.
    @State private var cardFrames: [String: CGRect] = [:]
    /// The scroll viewport rect in the same coordinate space (updated as the list lays out).
    @State private var viewportRect: CGRect = .zero
    /// The id of the card that holds the one active player, per the R1 coordinator (index↔id mapped
    /// at the view edge; the coordinator stays index-based & pure).
    @State private var activeCardId: String?
    /// Lazily-ranked top clip for the active a1 card only (one engine run per active-card change).
    @State private var activeRankedClip: FeedClipRef?
    /// The card id `activeRankedClip` was ranked for — guards against stale ranks after reorder.
    @State private var activeRankedCardId: String?

    private let pageSize = 12
    private let topAnchor = "feed.top"
    private let feedScrollSpace = "feedScroll"
    /// Hysteresis band (points): a challenger must beat the current card's distance-to-center by more
    /// than this to take over, so a card straddling center doesn't thrash on scroll jitter.
    private let activeHysteresis: CGFloat = 60

    // MARK: Derivation (derive-on-read; no card persistence)

    private func composed() -> [FeedCard] {
        memo.cards(signature: feedSignature()) {
            FeedQuery.cards(kilterSessions: kilterSessions, kilterLogs: kilterLogs,
                            workoutSessions: workoutSessions, litEvents: litEvents,
                            sessionMedia: allMedia, now: .now)
        }
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
                        switch layout {
                        case .list: listBody(visible: visible, filtered: filtered)
                        // F7: the masonry wall renders INLINE over the SAME visible corpus (one
                        // composition, two layouts). No active inline player runs in grid mode
                        // (grid tiles are static) — `layout` flip clears `activeCardId` below.
                        // Pagination is the shared keyset: each tile's `.onAppear` advances
                        // `visibleCount` via the same `loadMoreIfNeeded` the list uses.
                        case .grid: WallView(cards: visible,
                                             loadMore: { loadMoreIfNeeded(card: $0, in: filtered) })
                        }
                    }
                }
                // F3 (R2): capture the scroll viewport rect in the feedScroll space (drives centrality).
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(feedScrollSpace))
                } action: { rect in
                    viewportRect = rect
                    recomputeActive(visible: visible)
                }
                .coordinateSpace(name: feedScrollSpace)
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
                    // Flipping to grid clears the single-active inline player (R2 is inert in grid mode).
                    Button {
                        withAnimation(.snappy) {
                            layout.toggle()
                            if layout == .grid { activeCardId = nil }
                        }
                    } label: {
                        Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                    }
                    .accessibilityIdentifier("feed.gridToggle")
                }
            }
            .fullScreenCover(item: $presentedStory) { RecapStoryView(period: $0) }
        }
        .task { if seen.isEmpty { seen = FeedFreshness.topIDs(all) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { seen = FeedFreshness.topIDs(composed()) }
            if phase == .active { withAnimation { newCount = FeedFreshness.newCount(current: composed(), seen: seen) } }
        }
    }

    // MARK: Pieces

    /// The F1 list layout: the LazyVStack of full Pulse-Pro cards with the R2 single-active inline
    /// player wiring (frame capture, centrality recompute) + R6 carousel media + reaction strips.
    /// Only rendered in `.list` mode — in `.grid` mode the inline `WallView` takes over and no player
    /// frames are captured, so the active player stays inert.
    @ViewBuilder private func listBody(visible: [FeedCard], filtered: [FeedCard]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(visible, id: \.id) { card in
                VStack(spacing: 8) {
                    NavigationLink(value: card) {
                        // F3 (R2): pass single-active centrality + the ranked clip (active a1 card only).
                        FeedCardView(card: card,
                                     isCentral: card.id == activeCardId,
                                     rankedClip: rankedClip(for: card),
                                     media: cardMedia(for: card))
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
                        FeedReactionStrip(contentId: card.contentId).padding(.horizontal, 6)
                    }
                }
                // F3 (R2): capture each card's frame in the feedScroll space → R1 coordinator.
                // Keyed by the card's stable id so it survives index reuse across reorders.
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(feedScrollSpace))
                } action: { frame in
                    cardFrames[card.id] = frame
                    recomputeActive(visible: visible)
                }
                .onDisappear { cardFrames[card.id] = nil }
                .onAppear { loadMoreIfNeeded(card: card, in: filtered) }
            }
        }
        .padding(.horizontal, SnappetSpacing.lg)
        .padding(.bottom, 24)
        // F3 (R2): a lens/filter/pagination change can recycle ids — drop any stale
        // active card and prune frames to the current id set so nothing carries over.
        .onChange(of: visible.map(\.id)) { _, ids in
            activeCardId = nil
            let live = Set(ids)
            cardFrames = cardFrames.filter { live.contains($0.key) }
            recomputeActive(visible: visible)
        }
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

    // MARK: Behavior

    // MARK: F3 (R2) — single active inline-clip player

    /// Recompute which card holds the one active player via the R1 pure coordinator (nearest viewport
    /// center + hysteresis). When the active card changes, re-rank the top clip for it lazily (one
    /// engine run per hand-off) — fulfilling the decisions.md seam (rank consumed by the ACTIVE card only).
    private func recomputeActive(visible: [FeedCard]) {
        guard viewportRect != .zero else { return }
        // Build a dense [CGRect] in the SAME order as `visible` (each card → its id-keyed frame, or a
        // far-offscreen rect so a not-yet-measured card never wins). The R1 coordinator stays index-
        // based & pure; we map id↔index only here at the view edge.
        let frames: [CGRect] = visible.map { cardFrames[$0.id] ?? CGRect(x: 0, y: -1_000_000, width: 0, height: 0) }
        let currentIndex = activeCardId.flatMap { id in visible.firstIndex { $0.id == id } }
        let nextIndex = FeedActivePlayerCoordinator.activeIndex(
            cardFrames: frames, viewport: viewportRect, current: currentIndex, hysteresis: activeHysteresis)
        let next = nextIndex.flatMap { idx in visible.indices.contains(idx) ? visible[idx].id : nil }
        if next != activeCardId {
            activeCardId = next
            refreshActiveRank(visible: visible)
        }
    }

    /// Rank the top clip segment for the active a1 card (HighlightEngine via R1's pure wiring). Runs
    /// only on a hand-off; non-a1 / non-clipReady active cards clear the rank (they keep the still hero).
    private func refreshActiveRank(visible: [FeedCard]) {
        guard let id = activeCardId, let card = visible.first(where: { $0.id == id }) else {
            activeRankedClip = nil; activeRankedCardId = nil; return
        }
        guard case .climbSession = card.payload, let sid = sessionId(for: card) else {
            activeRankedClip = nil; activeRankedCardId = nil; return
        }
        let clips = allMedia.filter { $0.sessionID == sid }.map {
            SessionHighlightInput.Clip(localIdentifier: $0.localIdentifier, isVideo: $0.kind == .video,
                                       offsetSec: $0.offsetSec, durationSec: $0.durationSec)
        }
        guard let session = kilterSessions.first(where: { $0.id == sid }) else {
            activeRankedClip = nil; activeRankedCardId = nil; return
        }
        let duration = (session.endedAt ?? .now).timeIntervalSince(session.startedAt)
        let result = FeedClipEligibility.evaluate(hrSeries: session.hrSeries, clips: clips, duration: duration)
        activeRankedClip = result.clipReady ? result.topClip : nil
        activeRankedCardId = card.id
    }

    /// The ranked clip to hand the active a1 card — only when the rank was computed for THIS card id
    /// (guards against a stale rank surviving a reorder). Non-active cards get `nil` (cheap payload hint).
    private func rankedClip(for card: FeedCard) -> FeedClipRef? {
        guard activeCardId == card.id, activeRankedCardId == card.id else { return nil }
        return activeRankedClip
    }

    /// The Kilter session id behind a climb-session card (the source ref the rank reads HR/media from).
    private func sessionId(for card: FeedCard) -> UUID? {
        card.sourceRefs.first { $0.objectKind == "kilterSession" }.flatMap { UUID(uuidString: $0.ref) }
    }

    // MARK: F3b (R6) — in-card carousel media bundle

    /// The session-media bundle for an a1 climb-session card's carousel + fullscreen viewer: the
    /// session's clips (offset-ordered downstream), its HR series/maxHR (for the editor overlay), a
    /// name resolver, and the Animate `clipContext`. `nil` for non-climb cards or sessions with no media
    /// → the card falls back to the F3 inline-player hero + cheap affordance (no carousel). Snapshots
    /// the `@Model`s into plain values here on the `@MainActor` so SwiftData never crosses into the viewer.
    private func cardMedia(for card: FeedCard) -> FeedCardMedia? {
        guard case .climbSession = card.payload, let sid = sessionId(for: card) else { return nil }
        let media = allMedia.filter { $0.sessionID == sid }
        guard !media.isEmpty else { return nil }
        return FeedCardMedia(clips: media.map(MediaInput.from),
                             hrSeries: hrSeries(for: sid), maxHR: maxHR(for: sid),
                             nameFor: nameResolver(for: sid), clipContext: clipContext(for: sid, card: card))
    }

    private func hrSeries(for sid: UUID) -> [HRPoint] {
        kilterSessions.first { $0.id == sid }?.hrSeries ?? workoutSessions.first { $0.id == sid }?.hrSeries ?? []
    }

    private func maxHR(for sid: UUID) -> Double {
        (kilterSessions.first { $0.id == sid }?.maxHR ?? workoutSessions.first { $0.id == sid }?.maxHR) ?? HeartRateZone.defaultMaxHR
    }

    private func nameResolver(for sid: UUID) -> (String) -> String {
        var map: [String: String] = ["general": "General"]
        for log in kilterLogs where log.sessionId == sid { map[log.climbUUID] = log.climbName }
        return { key in map[key] ?? "Clip" }
    }

    /// The Animate context (clip render inputs) for a session that has video clips; `nil` ⇒ the viewer
    /// shows a plain Share (no dead Animate). Mirrors `CardDetailView.clipContext`.
    private func clipContext(for sid: UUID, card: FeedCard) -> ClipExportCoordinator.Context? {
        let media = allMedia.filter { $0.sessionID == sid }
        guard media.contains(where: { $0.kind == .video }) else { return nil }
        let clips = media.map {
            SessionHighlightInput.Clip(localIdentifier: $0.localIdentifier, isVideo: $0.kind == .video,
                                       offsetSec: $0.offsetSec, durationSec: $0.durationSec)
        }
        guard let k = kilterSessions.first(where: { $0.id == sid }) else { return nil }
        var clipName: String? = nil
        if case .climbSession(let p) = card.payload { clipName = p.hardestSendGrade }
        return ClipExportCoordinator.Context(
            hrSeries: k.hrSeries, clips: clips,
            duration: (k.endedAt ?? .now).timeIntervalSince(k.startedAt),
            maxHR: maxHR(for: sid), restHR: k.restHR, clipName: clipName)
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
