import SwiftUI
import SwiftData

// MARK: - Clips feed — the video/photo-first tab (prompt 82)
//
// A new bottom tab (Home · Clips · Recap · Apps): an Instagram-style feed where the media IS the post.
// One post = one exercise / one climb; its clips are a swipeable carousel; each poster burns in the live
// HR scorebug + the climb/exercise name (the same look the Studio export uses). A ⋯ menu opens the Studio
// scoped to the clip(s) or jumps to the owning session.
//
// Derive-on-read, like the Recap `FeedView`: @Query the source @Models, snapshot to plain values at the
// edge, compose with the pure `ClipFeedComposer`. The session stays the single source of truth — no new
// store. Reactions, share (raw + HR-burned, prompt 160) and the explore grid layered on since.

/// Per-session HR context the posters slice their scorebug window from. `Sendable` — it crosses the
/// off-main feed-composition hop (prompt 106).
struct ClipFeedHR: Equatable, Sendable {
    var series: [HRPoint]
    var maxHR: Double
    var restHR: Double?
}

/// Identifies the feed's single active inline clip — a post + the carousel page within it (prompt 85).
struct PlayingClipRef: Equatable {
    var postID: String
    var page: Int
    /// Autoplay starts muted (prompt 90); tap-to-play is unmuted.
    var muted: Bool = false
    func matches(_ postID: String, _ page: Int) -> Bool { self.postID == postID && self.page == page }
}

/// High-frequency carousel state, lifted OUT of `ClipsFeedView`'s `@State` into `@Observable` (prompt 97).
///
/// The fix for the carousel-swipe FREEZE: `playing`/`isScrolling` change on every swipe/scroll. As plain
/// `@State` on `ClipsFeedView`, each write unconditionally re-ran the WHOLE feed `body` — re-evaluating every
/// on-screen post card's `TabView(.page)` of AVPlayer-backed pages, which blocked the main thread ~250–600ms
/// (the slide never rendered → freeze-then-jump). With `@Observable`, SwiftUI tracks reads per-property: views
/// that DON'T read these (the feed `ScrollView`/`ForEach`, sibling cards) are NOT invalidated; only the leaf
/// `ClipPosterView` that actually reads `playing` re-renders. Passing the OBJECT down (not a property) never
/// establishes a read, so the swap is what severs the cascade. `@MainActor` — it's UI state.
@MainActor @Observable
final class ClipFeedPlayback {
    /// The feed's single active inline clip ("last interaction wins"). Driving the audio session from its
    /// `didSet` keeps the reaction OFF `ClipsFeedView.body` (an `.onChange(of:)` there would re-read it and
    /// re-introduce the whole-feed invalidation this class exists to remove).
    var playing: PlayingClipRef? {
        didSet {
            guard playing != oldValue else { return }   // match the old .onChange dedup — no redundant setActive churn
            if let p = playing, !p.muted { ClipAudioSession.activate() }
            else { ClipAudioSession.deactivate() }
        }
    }
    /// True while the OUTER vertical feed is actively scrolling (a horizontal carousel swipe does NOT set it).
    var isScrolling = false
}

struct ClipsFeedView: View {
    @Environment(\.modelContext) private var context
    /// For the Health offer card's Connect action only (highlights P5): the explicit tap calls
    /// `health.requestAuthorization()` then `reconcileWatchWorkouts()` — the ONE place Clips may
    /// request Health access (the launch-path request was tried and reverted; decisions.md).
    @Environment(AppModel.self) private var app

    @Query private var allMedia: [SessionMedia]
    @Query(sort: \KilterSession.startedAt, order: .reverse) private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var workoutSessions: [WorkoutSession]
    /// Studio projects — so the feed poster can render the session's SAVED HR tile (WYSIWYG, prompt 89);
    /// @Query so editing the HR chart in the Studio re-renders the feed. Sorted newest-edit-first so the
    /// per-session first-wins pick is deterministic (and is the latest edit) if a session ever has two
    /// projects (e.g. a backup that carried duplicates).
    @Query(sort: \StudioProject.updatedAt, order: .reverse) private var studioProjects: [StudioProject]
    /// Festival clip tags + lineups (festival prompt 03) — the flavor that turns a tagged clip into
    /// an artist·stage post behind the 🎪 chip. @Query so a review-sheet decision re-renders the feed.
    @Query private var festivalTags: [FestivalClipTag]
    @Query private var festivalLineups: [FestivalLineup]
    @Query private var festivalAttendance: [FestivalAttendance]
    /// The feed's single active inline clip + scroll flag — "last tapped wins", so only ONE clip plays across
    /// the whole feed (prompt 85). Tap-driven, NOT scroll-driven (the R12 hero's scroll-center coordinator is
    /// what rendered a black box in the scrolling card). Lifted into `@Observable` (prompt 97) so a swipe
    /// updating `playback.playing` re-renders ONLY the affected leaf page, not the whole feed body.
    @State private var playback = ClipFeedPlayback()
    /// Explore-grid sheet (prompt 86) + the post id to scroll the feed to when a grid cover is picked.
    @State private var showGrid = false
    @State private var scrollTarget: String?
    /// Favorite reactions (prompt 88) — `FeedReaction` rows keyed by clip, so they're backed up and
    /// survive regrouping (prompt 162). Bound to the context in `rebuildFeed`.
    @State private var reactions = ClipReactionStore()
    /// The user's default HR tile + title (prompt 163) — backed-up row, re-read every rebuild.
    @State private var overlayStore = ClipOverlayStyleStore()
    @State private var showStyle = false
    /// The feed's one transient message (prompt 164 hide-undo · prompt 166 autoplay) — a few seconds,
    /// then gone. One slot, so two toasts never stack.
    @State private var toast: ClipFeedToast?
    /// Optional search + chip filter (prompt 107) — pure value state; `.searchable` binds `query`,
    /// the chip strip binds the rest. Session-scoped by design (resets on relaunch, like IG search).
    @State private var filter = ClipFeedFilter()
    /// Cached derived feed (prompt 92 perf). Composing posts + slicing each clip's HR payload is the heavy
    /// part; do it ONLY when the @Query data changes — NOT on every `playingClip`/`page` write. A carousel
    /// swipe writes `playingClip`, which re-runs `body`; recomputing the feed there landed the work on the
    /// fast-snap animation frame and dropped it (the swipe jerk). Cache severs that edge.
    @State private var cachedPosts: [ClipFeedPost] = []
    @State private var cachedHRContext: [UUID: ClipFeedHR] = [:]
    @State private var cachedHRTiles: [UUID: HRTile] = [:]
    @State private var cachedPayloads: [UUID: ClipHROverlay.Payload] = [:]
    /// The in-flight rebuild (prompt 106): cancel-and-restart so a burst of `feedKey` changes (each
    /// post's aspect backfill saves one `SessionMedia` → one `feedKey` tick each) coalesces into ONE
    /// background composition instead of M consecutive full recomputes.
    @State private var rebuildTask: Task<Void, Never>?
    /// Autoplay-on-scroll (prompt 90) — opt-in (default OFF; the R12-risk inline render is device-owed),
    /// suppressed under Reduce Motion / Low Power.
    @AppStorage("clips.autoplay") private var autoplayEnabled = false
    /// The "Connect Apple Health" offer's asked-or-dismissed flag (highlights P5). One flag for
    /// both outcomes — read-auth status isn't queryable, so asked is as final as dismissed.
    @AppStorage(ClipsHealthOffer.resolvedKey) private var healthOfferResolved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var autoplayActive: Bool {
        autoplayEnabled && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        let posts = cachedPosts
        // Optional search + filter (prompt 107): the visible set. Zero-cost when idle — an inactive
        // filter returns `posts` untouched and never consults the reaction store (so no extra SwiftUI
        // dependency is registered). With `favoritesOnly` on, reading `reactions` here is deliberate:
        // toggling a heart live-updates the filtered feed.
        // Hidden clips leave the feed (prompt 164) — or, behind the Hidden chip, are all it shows.
        let unhidden = ClipFeedFilter.withHidden(posts, hidden: reactions.hiddenIDs, showHidden: filter.showHidden)
        let visible = filter.apply(unhidden, isFavorite: reactions.isFavorite)
        return NavigationStack {
            Group {
                if posts.isEmpty {
                    // The fresh-install case is exactly who the Health offer exists for (no clips,
                    // no watch imports yet) — so it renders above the empty state too.
                    VStack(spacing: 0) {
                        if showsHealthOffer {
                            ClipsHealthOfferCard(onConnect: connectHealth,
                                                 onDismiss: { healthOfferResolved = true })
                                .padding(.top, 8)
                        }
                        emptyState
                    }
                } else {
                  // Measure the feed width ONCE here (stable) so each card's tile height is correct from the
                  // first render — no per-card width measurement that pops the height during scroll (prompt 92).
                  GeometryReader { feedGeo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            // Session headers pin while you're inside that session (prompt 167).
                            LazyVStack(spacing: 18, pinnedViews: [.sectionHeaders]) {
                                // Contextual "Connect Apple Health" offer (highlights P5): shown while
                                // no watch-imported session exists and the user hasn't connected or
                                // dismissed — the fresh-install read-priming gap the retired Workout
                                // Reels onboarding left behind. The Health sheet fires ONLY from the
                                // card's Connect tap, never from a launch path (the reverted trap).
                                if showsHealthOffer {
                                    ClipsHealthOfferCard(onConnect: connectHealth,
                                                         onDismiss: { healthOfferResolved = true })
                                }
                                // Weekly Highlight Reel hero (highlights P4): offered over the composed
                                // posts (pure, cheap) once this week has ≥2 video clips; opens the
                                // shared reel builder on the stitched week.
                                if let offer = WeeklyHighlights.offer(
                                        posts: ClipFeedFilter.withHidden(posts, hidden: reactions.hiddenIDs, showHidden: false),
                                        week: WeeklyHighlights.week(containing: .now)) {
                                    WeeklyReelHeroCard(offer: offer)
                                }
                                // Filter chips — visible, not buried in a toolbar glyph (the #264 lesson);
                                // scrolls away with content so browsing costs no vertical space. Hidden
                                // while the search field is up (one control in charge at a time).
                                ClipFilterChipStrip(filter: $filter, hiddenCount: reactions.hiddenIDs.count)
                                if filter.isActive {
                                    resultLine(visible: visible.count, total: posts.count)
                                }
                                if visible.isEmpty, filter.isActive {
                                    noMatchState
                                } else {
                                    // Grouped under a pinned session header (prompt 167) — over the
                                    // VISIBLE posts, so filters and search group their results too.
                                    let indexByID = Dictionary(visible.enumerated().map { ($1.id, $0) },
                                                               uniquingKeysWith: { a, _ in a })
                                    ForEach(ClipFeedSections.sessions(visible)) { section in
                                        Section {
                                            ForEach(section.posts) { post in
                                                postCard(post, width: feedGeo.size.width)
                                                    // Warm the posters just below the fold (prompt 134). A
                                                    // poster costs 70–120 ms and used to START loading only
                                                    // when its cell appeared, so a normal scroll outran the
                                                    // loader. Hooking the row's own appearance keeps this
                                                    // free of scroll-offset tracking.
                                                    .onAppear {
                                                        prefetchPosters(after: indexByID[post.id] ?? 0,
                                                                        in: visible,
                                                                        width: feedGeo.size.width)
                                                    }
                                            }
                                        } header: {
                                            ClipSessionHeader(section: section)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("clips.feed")
                        // The standard iOS pull-down search field — invisible until wanted (prompt 107).
                        .searchable(text: $filter.query,
                                    placement: .navigationBarDrawer(displayMode: .automatic),
                                    prompt: "Search names, grades, sends, dates…")
                        // Narrowing the feed can remove the playing post's card mid-playback; stop the
                        // active clip so playback state never points at a filtered-out page.
                        .onChange(of: filter) { _, _ in playback.playing = nil }
                        // Track scroll phase: stop an UNMUTED clip (tap-to-play) so audio can't blare while
                        // scrolling (prompt 85), and publish `isScrolling` so cards only START muted autoplay
                        // once the scroll SETTLES (no mid-scroll still↔player churn — prompt 90 polish).
                        .onScrollPhaseChange { _, newPhase, _ in
                            playback.isScrolling = newPhase != .idle
                            if newPhase != .idle, let pc = playback.playing, !pc.muted { playback.playing = nil }
                        }
                        // Turning autoplay OFF stops any clip it started (otherwise a muted clip loops on).
                        .onChange(of: autoplayEnabled) { _, on in if !on { playback.playing = nil } }
                        // Jump to a post picked in the explore grid (prompt 86). Deferred a beat so the grid
                        // sheet finishes dismissing first — scrolling mid-transition can no-op against an
                        // off-screen (not-yet-realized) LazyVStack row.
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                withAnimation { proxy.scrollTo(target, anchor: .top) }
                                scrollTarget = nil
                            }
                        }
                    }
                  }
                }
            }
            .background(SnappetColor.paper)
            // Transient feedback (prompt 164 "Hidden · Undo", prompt 166 autoplay on/off).
            .overlay(alignment: .bottom) {
                if let t = toast {
                    HStack(spacing: 12) {
                        Text(t.message).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                        if let ids = t.undoHidden {
                            Button("Undo") { reactions.unhide(ids); toast = nil }
                                .font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.brand)
                                .accessibilityIdentifier("clips.hide.undo")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.black.opacity(0.85), in: Capsule())
                    .padding(.horizontal, SnappetSpacing.lg)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier(t.undoHidden != nil ? "clips.hide.toast" : "clips.toast")
                }
            }
            .animation(.easeOut(duration: 0.2), value: toast)
            // Build the cached feed on first appearance and ONLY when the underlying @Query data changes —
            // never on a playingClip/page write (prompt 92 perf: keeps the heavy composition off the swipe).
            // Composition runs on a background task; data-driven rebuilds debounce so a burst of saves
            // (the aspect backfill) coalesces into one recompute (prompt 106).
            // Re-entering the tab with posts already showing: let the tab switch land first, then refresh in
            // the background (the compose is off-main, but its 100 ms snapshot isn't — Clips perf 2026-10-06).
            .task { rebuildFeed(debounce: !cachedPosts.isEmpty, delay: .milliseconds(600)) }
            .onChange(of: feedKey) { _, _ in rebuildFeed(debounce: true) }
            // A saved overlay style re-composes every payload with the new default tile (prompt 163).
            .onChange(of: overlayStore.style) { _, _ in rebuildFeed() }
            // Audio session (prompt 93): driven from `ClipFeedPlayback.playing`'s didSet (NOT an `.onChange`
            // here — that would re-read `playing` and re-introduce the whole-feed invalidation prompt 97 removes).
            .onDisappear { ClipAudioSession.deactivate() }
            .navigationTitle("Clips")
            .navigationBarTitleDisplayMode(.large)
            // The Weekly Highlight Reel builder (highlights P4), pushed by the hero card above.
            .navigationDestination(for: WeeklyReelRoute.self) { _ in WeeklyReelHostView() }
            .toolbar {
                if !posts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        // The default HR tile + title for every clip (prompt 163).
                        Button { showStyle = true } label: { Image(systemName: "paintbrush.pointed") }
                            .accessibilityIdentifier("clips.style.button")
                            .accessibilityLabel("Overlay style")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Autoplay-on-scroll (prompt 90) — opt-in, off by default. Prompt 166: a LABELLED
                        // control (the bare play.slash glyph didn't read as "autoplay") + a toast saying
                        // what changed.
                        Button(action: toggleAutoplay) {
                            HStack(spacing: 4) {
                                Image(systemName: autoplayEnabled ? "play.fill" : "pause.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Autoplay").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(autoplayEnabled ? SnappetColor.brand : SnappetColor.textSecondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(autoplayEnabled ? SnappetColor.brand.opacity(0.14) : SnappetColor.surfaceMuted,
                                        in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("clips.autoplay.toggle")
                        .accessibilityLabel("Autoplay")
                        .accessibilityValue(autoplayEnabled ? "On" : "Off")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showGrid = true } label: { Image(systemName: "square.grid.3x3") }
                            .accessibilityIdentifier("clips.grid.button")
                    }
                }
            }
            .sheet(isPresented: $showStyle) {
                ClipOverlayStyleSheet(store: overlayStore, preview: stylePreviewInput)
            }
            .sheet(isPresented: $showGrid) {
                // The grid inherits the active search/filter (prompt 107) so it always agrees with the feed.
                ClipsGridView(posts: visible, onPick: { scrollTarget = $0 })
            }
        }
    }

    /// One post card with the feed's shared state (prompt 167 pulled it out of the grouped ForEach).
    private func postCard(_ post: ClipFeedPost, width: CGFloat) -> some View {
        ClipPostCard(post: post,
                     hr: cachedHRContext[post.sessionID] ?? ClipFeedHR(series: [], maxHR: 190, restHR: nil),
                     allMedia: allMedia, playback: playback,
                     reactions: reactions, hrTile: cachedHRTiles[post.sessionID],
                     payloads: cachedPayloads,
                     autoplayActive: autoplayActive,
                     contentWidth: width,
                     style: overlayStore.style,
                     showingHidden: filter.showHidden,
                     onHide: hide, onUnhide: { reactions.unhide($0) })
            .id(post.id)
    }

    // MARK: Hide from Clips (prompt 164)

    /// Hide `ids` (non-destructive), stop playback if one of them was playing, offer Undo for 4s.
    private func hide(_ ids: Set<UUID>) {
        playback.playing = nil
        reactions.hide(ids)
        show(ClipFeedToast(message: ids.count == 1 ? "Clip hidden from Clips" : "\(ids.count) clips hidden from Clips",
                           undoHidden: ids))
    }

    /// Show `t` for a few seconds (a newer toast replaces it).
    private func show(_ t: ClipFeedToast) {
        toast = t
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(t.undoHidden != nil ? 4 : 2.5))
            if toast == t { toast = nil }
        }
    }

    // MARK: Autoplay (prompt 166)

    /// Flip autoplay and SAY what happened — including when the system is holding it back, so "on" never
    /// silently does nothing.
    private func toggleAutoplay() {
        autoplayEnabled.toggle()
        show(ClipFeedToast(message: ClipAutoplayCopy.message(
            enabled: autoplayEnabled, reduceMotion: reduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)))
    }

    // MARK: Overlay style (prompt 163)

    /// The ✎ sheet's preview: the newest video post with HR whose session has no Studio tile of its own
    /// (so the preview shows the DEFAULT), else the sample clip.
    private var stylePreviewInput: ClipOverlayPreviewInput {
        for post in cachedPosts where cachedHRTiles[post.sessionID] == nil {
            guard let item = post.clips.first(where: { $0.media.kind == "video" && !$0.media.isReel }),
                  let hr = cachedHRContext[post.sessionID], !hr.series.isEmpty,
                  cachedPayloads[item.media.id] != nil else { continue }
            return ClipOverlayPreviewInput(media: item.media, hr: hr, values: post.titleValues(for: item),
                                           aspect: post.aspect, caption: post.title)
        }
        return .sample
    }

    // MARK: "Connect Apple Health" offer (highlights P5)

    /// Pure gate + the view's two inputs: the existing sessions @Query (a watch import existing
    /// means read access already works) and the persisted asked/dismissed flag (read-auth status
    /// is NOT queryable, so a flag is the only honest gate).
    private var showsHealthOffer: Bool {
        ClipsHealthOffer.shouldShow(
            // Any Health import proves the connection exists — the offer must not re-appear just
            // because the imports came from Google Health rather than the Watch (prompt 129).
            hasWatchImportedSession: workoutSessions.contains(where: \.isImportedFromHealth),
            resolved: healthOfferResolved)
    }

    /// The Connect tap: resolve the flag first (asked is final — the sheet answers off-process and
    /// its outcome can't be read back), then request + reconcile so granted workouts appear
    /// immediately. The ONLY Health request this tab ever makes.
    private func connectHealth() {
        healthOfferResolved = true
        Task { @MainActor in
            try? await app.health.requestAuthorization()
            await app.reconcileWatchWorkouts()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No clips yet", systemImage: "play.square.stack")
        } description: {
            Text("Film a workout or a climb and your clips show up here — each one with your live heart rate and the climb or exercise name.")
        }
        .accessibilityIdentifier("clips.empty")
    }

    // MARK: Search + filter chrome (prompt 107)

    /// The honest "N of M posts · Clear" line, shown only while something narrows the feed.
    private func resultLine(visible: Int, total: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(visible) of \(total) post\(total == 1 ? "" : "s")")
                .font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.ink)
            if !filter.trimmedQuery.isEmpty {
                Text("match “\(filter.trimmedQuery)”")
                    .font(.caption).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            }
            Spacer()
            Button("Clear") { filter = .cleared }
                .font(.caption.weight(.bold)).foregroundStyle(SnappetColor.brand)
                .accessibilityIdentifier("clips.filter.clear")
        }
        .padding(.horizontal, SnappetSpacing.lg)
        .accessibilityIdentifier("clips.filter.results")
    }

    /// Dead ends get an exit: name what failed + one-tap recovery — never a silent empty feed.
    private var noMatchState: some View {
        ContentUnavailableView {
            Label(filter.trimmedQuery.isEmpty ? "No matching clips" : "No posts match “\(filter.trimmedQuery)”",
                  systemImage: "magnifyingglass")
        } description: {
            Text("Try a different name, or clear the search and filters to see every post.")
        } actions: {
            Button("Clear search & filters") { filter = .cleared }
                .buttonStyle(.borderedProminent).tint(SnappetColor.brand)
                .accessibilityIdentifier("clips.filter.emptyClear")
        }
        .padding(.top, 60)
        .accessibilityIdentifier("clips.filter.empty")
    }

    // MARK: Derivation (derive-on-read; no persistence)

    /// Everything the off-main composition needs, snapshotted from the `@Model`s on the MainActor
    /// (prompt 106). Plain `Sendable` values only — the compose step must not touch SwiftData.
    private struct FeedSnapshot: Sendable {
        var bundles: [ClipFeedComposer.SessionBundle]
        var climbMeta: [String: ClipFeedClimbMeta]
        var exerciseNames: [UUID: String]
        /// media id → festival flavor (festival prompt 03) — tagged clips + festival-session reels.
        var festivalMeta: [UUID: ClipFeedFestivalMeta]
        /// Per-session HR context — **media-bearing sessions only**. Building it for every historical
        /// session decoded every `hrSeries` blob per rebuild (and retained them) for posts that don't exist.
        var hr: [UUID: ClipFeedHR]
        var tiles: [UUID: HRTile]
        /// The user's default tile (prompt 163) — used where a session has no Studio tile of its own.
        var style: ClipOverlayStyle
    }

    /// The background composition's result, assigned back to the caches on the MainActor in one shot.
    private struct ComposedFeed: Sendable {
        var posts: [ClipFeedPost]
        var hr: [UUID: ClipFeedHR]
        var tiles: [UUID: HRTile]
        var payloads: [UUID: ClipHROverlay.Payload]
    }

    /// Snapshot the @Query models into plain values at the store edge (MediaInput drops sessionID,
    /// so the by-session bucketing happens here too).
    private func makeSnapshot() -> FeedSnapshot {
        // Per-clip Studio edits the feed live-reflects (prompt 116): trim + HR-window config, resolved
        // by SessionMedia id (localIdentifier fallback for unlinked timeline clips — the same policy as
        // StudioHRPlacement.resolveOffset). Bounded to MEDIA-BEARING sessions: `p.clips` is the
        // largest composite blob on StudioProject and this runs per rebuild on the MainActor — the
        // same scoping rule FeedSnapshot.hr documents. First-project-wins per media id (a session has
        // one StudioProject today; the merge rule just makes that assumption explicit).
        var edits: [UUID: ClipStudioEdit] = [:]
        if !studioProjects.isEmpty {
            let mediaIDByLocal = Dictionary(allMedia.map { ($0.localIdentifier, $0.id) },
                                            uniquingKeysWith: { a, _ in a })
            let mediaSessionIDs = Set(allMedia.map(\.sessionID))
            for p in studioProjects where mediaSessionIDs.contains(p.sessionID) {
                edits.merge(ClipStudioEdit.byMedia(clips: p.clips, mediaIDByLocalID: mediaIDByLocal)) { a, _ in a }
            }
        }
        var bySession: [UUID: [MediaInput]] = [:]
        for m in allMedia { bySession[m.sessionID, default: []].append(MediaInput.from(m, edit: edits[m.id])) }

        // climbUUID → name/grade/angle, snapshotted from the logs (latest log wins).
        var climbMeta: [String: ClipFeedClimbMeta] = [:]
        for log in kilterLogs.sorted(by: { $0.date < $1.date }) {
            climbMeta[log.climbUUID] = ClipFeedClimbMeta(name: log.climbName, gradeLabel: log.gradeLabel, angle: log.angle)
        }

        // SessionExercise.id → display name (resolved off the pure path, on the MainActor).
        var exerciseName: [UUID: String] = [:]
        for w in workoutSessions {
            for ex in w.exercises {
                exerciseName[ex.id] = ex.displayName ?? ExerciseCatalog.byID[ex.exerciseId]?.name ?? ex.exerciseId
            }
        }

        // How each climb went, per Kilter session (prompt 161) — the session's log row per climb.
        var kilterResults: [UUID: [String: ClipFeedClimbResult]] = [:]
        for log in kilterLogs {
            guard let sid = log.sessionId else { continue }
            let r = ClipFeedClimbResult(status: log.status, attempts: log.attempts)
            kilterResults[sid, default: [:]][log.climbUUID] =
                kilterResults[sid]?[log.climbUUID].map { $0.merged(with: r) } ?? r
        }

        let kilterByID = Dictionary(kilterSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let workoutByID = Dictionary(workoutSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var bundles: [ClipFeedComposer.SessionBundle] = []
        var hr: [UUID: ClipFeedHR] = [:]
        for (sid, clips) in bySession {
            if let k = kilterByID[sid] {
                bundles.append(.init(meta: ClipFeedSessionMeta(id: sid, kind: .kilter,
                    title: k.title ?? "Kilter session", startedAt: k.startedAt, endedAt: k.endedAt,
                    angle: k.angle), clips: clips, climbResults: kilterResults[sid] ?? [:]))
                hr[sid] = ClipFeedHR(series: k.hrSeries, maxHR: k.maxHR ?? 190, restHR: k.restHR)
            } else if let w = workoutByID[sid] {
                bundles.append(.init(meta: ClipFeedSessionMeta(id: sid, kind: .gym,
                    title: w.routineName, startedAt: w.startedAt, endedAt: w.completedAt,
                    angle: nil, isFromAppleWatch: w.isFromAppleWatch), clips: clips,
                    climbResults: Self.quickSessionClimbResults(w.exercises)))
                hr[sid] = ClipFeedHR(series: w.hrSeries, maxHR: w.maxHR ?? 190, restHR: w.restHR)
            }
            // else: media whose session was deleted — skip (no orphan posts).
        }
        return FeedSnapshot(bundles: bundles, climbMeta: climbMeta, exerciseNames: exerciseName,
                            festivalMeta: makeFestivalMeta(workoutByID: workoutByID),
                            hr: hr, tiles: sessionHRTile, style: overlayStore.style)
    }

    /// A Quick Session's climbs → their per-attempt outcomes (prompt 161), keyed like the post group
    /// (`SessionExercise.id`). Climbs with no logged outcome are left out.
    private static func quickSessionClimbResults(_ exercises: [SessionExercise]) -> [String: ClipFeedClimbResult] {
        var out: [String: ClipFeedClimbResult] = [:]
        for ex in exercises where ex.kind == .climbAttempt {
            if let r = ClipFeedClimbResult.fromAttempts(
                ex.sets.map { $0.climbStatusRaw.flatMap(KilterAscentStatus.init(rawValue:)) }) {
                out[ex.id.uuidString] = r
            }
        }
        return out
    }

    /// media id → festival flavor (festival prompt 03), from denormalized rows only — no pack
    /// inflation on the compose path. Resolved tags flavor their clip into an artist·stage set
    /// post; a festival session's posted reels get name/day-only flavor (they keep their reel
    /// title but read as festival).
    private func makeFestivalMeta(workoutByID: [UUID: WorkoutSession]) -> [UUID: ClipFeedFestivalMeta] {
        guard !festivalLineups.isEmpty else { return [:] }
        let lineupByPack = Dictionary(festivalLineups.map { ($0.packID, $0) },
                                      uniquingKeysWith: { a, _ in a })
        let mediaByID = Dictionary(allMedia.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var out: [UUID: ClipFeedFestivalMeta] = [:]
        for tag in festivalTags where tag.isResolved {
            guard let lineup = lineupByPack[tag.packID],
                  let media = mediaByID[tag.mediaID],
                  let session = workoutByID[tag.sessionID] else { continue }
            let capturedAt = session.startedAt.addingTimeInterval(max(0, media.offsetSec))
            out[tag.mediaID] = ClipFeedFestivalMeta(
                setKey: tag.setID.uuidString,
                artist: tag.artist,
                stage: tag.stage,
                festivalName: lineup.name,
                dayLabel: FestivalTagging.posterWeekday(for: capturedAt,
                                                        utcOffsetSeconds: lineup.utcOffsetSeconds))
        }
        // Festival-session reels: sessionID → packID via the attendance rows.
        let packBySession = Dictionary(festivalAttendance.map { ($0.sessionID, $0.packID) },
                                       uniquingKeysWith: { a, _ in a })
        for media in allMedia where media.isReel {
            guard out[media.id] == nil,
                  let packID = packBySession[media.sessionID],
                  let lineup = lineupByPack[packID],
                  let session = workoutByID[media.sessionID] else { continue }
            out[media.id] = ClipFeedFestivalMeta(
                setKey: nil, artist: nil, stage: nil,
                festivalName: lineup.name,
                dayLabel: FestivalTagging.posterWeekday(for: session.startedAt,
                                                        utcOffsetSeconds: lineup.utcOffsetSeconds))
        }
        return out
    }

    /// The heavy part — compose the posts + slice every clip's HR payload. Pure over the snapshot, so it
    /// runs on a background task (prompt 106): the feed's first build and every data-driven rebuild used
    /// to do all of this synchronously on the MainActor, which froze the UI on media-heavy libraries.
    nonisolated private static func compose(_ snap: FeedSnapshot) -> ComposedFeed {
        let names = snap.exerciseNames
        let posts = ClipFeedComposer.posts(sessions: snap.bundles, climbMeta: snap.climbMeta,
                                           exerciseName: { names[$0] ?? "Exercise" },
                                           festivalMeta: snap.festivalMeta)
        var payloads: [UUID: ClipHROverlay.Payload] = [:]
        for post in posts {
            let hr = snap.hr[post.sessionID] ?? ClipFeedHR(series: [], maxHR: 190, restHR: nil)
            // Precedence (prompt 163): the session's Studio tile → the user's default → (inside `make`,
            // when neither would draw anything) the built-in scorebug.
            let tile = snap.style.tile(sessionTile: snap.tiles[post.sessionID], restHR: hr.restHR)
            for item in post.clips where !item.media.isReel {
                // A posted reel already carries the burned scorebug in its pixels (highlights P2) —
                // composing a live overlay for it would double-draw, same rule as a baked clip.
                if let p = ClipHROverlay.make(clip: item.media, hrSeries: hr.series,
                                              maxHR: hr.maxHR, restHR: hr.restHR, tile: tile) {
                    payloads[item.media.id] = p
                }
            }
        }
        return ComposedFeed(posts: posts, hr: snap.hr, tiles: snap.tiles, payloads: payloads)
    }

    /// A cheap Equatable signature of the @Query inputs — recompute the cached feed only when this changes
    /// (add/remove, an aspect backfill, a Studio-tile edit), NOT on a `playingClip`/`page` write.
    private struct FeedKey: Equatable {
        var media: Int, aspects: Int, kSessions: Int, kLogs: Int, wSessions: Int, projects: Int
        var newestEdit: Date?
        /// Order-insensitive signature of the festival tag rows (festival prompt 03): counts alone
        /// miss a Change › re-pick (same row count, new setID), so hash the identity-bearing fields.
        var festivalTagKey: Int = 0
    }
    private var feedKey: FeedKey {
        FeedKey(media: allMedia.count,
                aspects: allMedia.reduce(0) { $0 + ($1.aspectRatio != nil ? 1 : 0) },
                kSessions: kilterSessions.count, kLogs: kilterLogs.count,
                wSessions: workoutSessions.count, projects: studioProjects.count,
                newestEdit: studioProjects.first?.updatedAt,
                festivalTagKey: festivalTags.reduce(0) { acc, t in
                    var h = Hasher()
                    h.combine(t.mediaID); h.combine(t.setID); h.combine(t.sourceRaw)
                    return acc ^ h.finalize()
                })
    }

    /// Rebuild the cached posts + per-session HR context/tile + per-clip HR payloads — snapshot on the
    /// MainActor, compose on a background task, assign back in one shot (prompt 106). Cancel-and-restart:
    /// a burst of `feedKey` changes (the per-post aspect backfill) coalesces via `debounce` into one
    /// rebuild; the first appearance builds immediately so the feed paints without an artificial delay.
    /// `Task.detached` (not a nonisolated-async hop) so the compose is off-main regardless of the
    /// language mode's isolation-inheritance default.
    private func rebuildFeed(debounce: Bool = false, delay: Duration = .milliseconds(200)) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            overlayStore.attach(context)   // re-read the saved style (picks up a restore)
            let snap = makeSnapshot()
            let composed = await Task.detached(priority: .userInitiated) { Self.compose(snap) }.value
            guard !Task.isCancelled else { return }   // a newer rebuild superseded this one
            // Favorites (prompt 162): re-read the rows each rebuild (picks up a backup restore) and move
            // any prompt-88 post-id hearts onto the freshly composed posts' clips, once.
            reactions.attach(context)
            reactions.migrateLegacy(posts: composed.posts)
            cachedPosts = composed.posts
            cachedHRContext = composed.hr
            cachedHRTiles = composed.tiles
            cachedPayloads = composed.payloads
        }
    }

    /// How many cards ahead of the one just shown to warm. Three is about one screen of scrolling at
    /// a normal flick — far enough to hide a ~100 ms decode, near enough that a fast scroll doesn't
    /// queue work the user will never see (the frame-0 pre-bake is throttled besides).
    private static let prefetchDepth = 3

    /// Warm the FIRST clip of the next few posts — the one whose poster drives the tile. Later clips
    /// in a post's carousel stay windowed by `loadPoster` (prompt 106); this is purely about the card
    /// you are scrolling toward.
    private func prefetchPosters(after index: Int, in posts: [ClipFeedPost], width: CGFloat) {
        let upcoming = posts.dropFirst(index + 1).prefix(Self.prefetchDepth)
        guard !upcoming.isEmpty else { return }
        let items: [AssetPosterLoader.Prefetch] = upcoming.compactMap { post -> AssetPosterLoader.Prefetch? in
            guard let first = post.clips.first else { return nil }
            // The SAME poster time the card will request (a Studio-trimmed clip posters at its kept
            // range's start) — otherwise the warmed cache key wouldn't match and the work is wasted.
            return AssetPosterLoader.Prefetch(localIdentifier: first.media.localIdentifier,
                                              isVideo: first.media.kind == "video",
                                              posterTime: ClipHROverlay.playedRange(first.media).start)
        }
        guard !items.isEmpty else { return }
        // Match the tile geometry the card will request, so the warmed bitmap is the one it wants.
        AssetPosterLoader.prefetch(items, pointSize: CGSize(width: width, height: width / defaultTileAspect))
    }

    /// The tile aspect posters are warmed at — the composer's default until a real aspect resolves.
    private var defaultTileAspect: CGFloat { CGFloat(ClipFeedComposer.defaultAspect) }

    /// sessionID → the session's SAVED Studio HR tile (the WYSIWYG override, prompt 89), present only when
    /// the user customized it in the Studio; otherwise the poster keeps the house-style `.feedClipScorebug`.
    private var sessionHRTile: [UUID: HRTile] {
        Dictionary(studioProjects.compactMap { p in p.hrOverlay?.tile.map { (p.sessionID, $0) } },
                   uniquingKeysWith: { a, _ in a })
    }

}
