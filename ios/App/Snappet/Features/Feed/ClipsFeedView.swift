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
// store. Read-only vertical slice: reactions / share / explore-grid are a follow-up.

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

    @Query private var allMedia: [SessionMedia]
    @Query(sort: \KilterSession.startedAt, order: .reverse) private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var workoutSessions: [WorkoutSession]
    /// Studio projects — so the feed poster can render the session's SAVED HR tile (WYSIWYG, prompt 89);
    /// @Query so editing the HR chart in the Studio re-renders the feed. Sorted newest-edit-first so the
    /// per-session first-wins pick is deterministic (and is the latest edit) if a session ever has two
    /// projects (e.g. a backup that carried duplicates).
    @Query(sort: \StudioProject.updatedAt, order: .reverse) private var studioProjects: [StudioProject]
    /// The feed's single active inline clip + scroll flag — "last tapped wins", so only ONE clip plays across
    /// the whole feed (prompt 85). Tap-driven, NOT scroll-driven (the R12 hero's scroll-center coordinator is
    /// what rendered a black box in the scrolling card). Lifted into `@Observable` (prompt 97) so a swipe
    /// updating `playback.playing` re-renders ONLY the affected leaf page, not the whole feed body.
    @State private var playback = ClipFeedPlayback()
    /// Explore-grid sheet (prompt 86) + the post id to scroll the feed to when a grid cover is picked.
    @State private var showGrid = false
    @State private var scrollTarget: String?
    /// Favorite reactions (prompt 88) — UserDefaults-backed, no new @Model.
    @State private var reactions = ClipReactionStore()
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
        let visible = filter.apply(posts, isFavorite: reactions.isFavorite)
        return NavigationStack {
            Group {
                if posts.isEmpty {
                    emptyState
                } else {
                  // Measure the feed width ONCE here (stable) so each card's tile height is correct from the
                  // first render — no per-card width measurement that pops the height during scroll (prompt 92).
                  GeometryReader { feedGeo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 18) {
                                // Filter chips — visible, not buried in a toolbar glyph (the #264 lesson);
                                // scrolls away with content so browsing costs no vertical space. Hidden
                                // while the search field is up (one control in charge at a time).
                                ClipFilterChipStrip(filter: $filter)
                                if filter.isActive {
                                    resultLine(visible: visible.count, total: posts.count)
                                }
                                if visible.isEmpty, filter.isActive {
                                    noMatchState
                                } else {
                                    ForEach(visible) { post in
                                        ClipPostCard(post: post,
                                                     hr: cachedHRContext[post.sessionID] ?? ClipFeedHR(series: [], maxHR: 190, restHR: nil),
                                                     allMedia: allMedia, playback: playback,
                                                     reactions: reactions, hrTile: cachedHRTiles[post.sessionID],
                                                     payloads: cachedPayloads,
                                                     autoplayActive: autoplayActive,
                                                     contentWidth: feedGeo.size.width)
                                            .id(post.id)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("clips.feed")
                        // The standard iOS pull-down search field — invisible until wanted (prompt 107).
                        .searchable(text: $filter.query,
                                    placement: .navigationBarDrawer(displayMode: .automatic),
                                    prompt: "Search climbs, exercises & sessions")
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
            // Build the cached feed on first appearance and ONLY when the underlying @Query data changes —
            // never on a playingClip/page write (prompt 92 perf: keeps the heavy composition off the swipe).
            // Composition runs on a background task; data-driven rebuilds debounce so a burst of saves
            // (the aspect backfill) coalesces into one recompute (prompt 106).
            .task { rebuildFeed() }
            .onChange(of: feedKey) { _, _ in rebuildFeed(debounce: true) }
            // Audio session (prompt 93): driven from `ClipFeedPlayback.playing`'s didSet (NOT an `.onChange`
            // here — that would re-read `playing` and re-introduce the whole-feed invalidation prompt 97 removes).
            .onDisappear { ClipAudioSession.deactivate() }
            .navigationTitle("Clips")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !posts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Autoplay-on-scroll toggle (prompt 90) — opt-in, off by default.
                        Button { autoplayEnabled.toggle() } label: {
                            Image(systemName: autoplayEnabled ? "play.circle.fill" : "play.slash")
                        }
                        .accessibilityIdentifier("clips.autoplay.toggle")
                        .accessibilityLabel(autoplayEnabled ? "Turn off autoplay" : "Turn on autoplay")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showGrid = true } label: { Image(systemName: "square.grid.3x3") }
                            .accessibilityIdentifier("clips.grid.button")
                    }
                }
            }
            .sheet(isPresented: $showGrid) {
                // The grid inherits the active search/filter (prompt 107) so it always agrees with the feed.
                ClipsGridView(posts: visible, onPick: { scrollTarget = $0 })
            }
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
        /// Per-session HR context — **media-bearing sessions only**. Building it for every historical
        /// session decoded every `hrSeries` blob per rebuild (and retained them) for posts that don't exist.
        var hr: [UUID: ClipFeedHR]
        var tiles: [UUID: HRTile]
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

        let kilterByID = Dictionary(kilterSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let workoutByID = Dictionary(workoutSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var bundles: [ClipFeedComposer.SessionBundle] = []
        var hr: [UUID: ClipFeedHR] = [:]
        for (sid, clips) in bySession {
            if let k = kilterByID[sid] {
                bundles.append(.init(meta: ClipFeedSessionMeta(id: sid, kind: .kilter,
                    title: k.title ?? "Kilter session", startedAt: k.startedAt, endedAt: k.endedAt,
                    angle: k.angle), clips: clips))
                hr[sid] = ClipFeedHR(series: k.hrSeries, maxHR: k.maxHR ?? 190, restHR: k.restHR)
            } else if let w = workoutByID[sid] {
                bundles.append(.init(meta: ClipFeedSessionMeta(id: sid, kind: .gym,
                    title: w.routineName, startedAt: w.startedAt, endedAt: w.completedAt,
                    angle: nil, isFromAppleWatch: w.isFromAppleWatch), clips: clips))
                hr[sid] = ClipFeedHR(series: w.hrSeries, maxHR: w.maxHR ?? 190, restHR: w.restHR)
            }
            // else: media whose session was deleted — skip (no orphan posts).
        }
        return FeedSnapshot(bundles: bundles, climbMeta: climbMeta, exerciseNames: exerciseName,
                            hr: hr, tiles: sessionHRTile)
    }

    /// The heavy part — compose the posts + slice every clip's HR payload. Pure over the snapshot, so it
    /// runs on a background task (prompt 106): the feed's first build and every data-driven rebuild used
    /// to do all of this synchronously on the MainActor, which froze the UI on media-heavy libraries.
    nonisolated private static func compose(_ snap: FeedSnapshot) -> ComposedFeed {
        let names = snap.exerciseNames
        let posts = ClipFeedComposer.posts(sessions: snap.bundles, climbMeta: snap.climbMeta,
                                           exerciseName: { names[$0] ?? "Exercise" })
        var payloads: [UUID: ClipHROverlay.Payload] = [:]
        for post in posts {
            let hr = snap.hr[post.sessionID] ?? ClipFeedHR(series: [], maxHR: 190, restHR: nil)
            let tile = snap.tiles[post.sessionID]
            for item in post.clips {
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
    }
    private var feedKey: FeedKey {
        FeedKey(media: allMedia.count,
                aspects: allMedia.reduce(0) { $0 + ($1.aspectRatio != nil ? 1 : 0) },
                kSessions: kilterSessions.count, kLogs: kilterLogs.count,
                wSessions: workoutSessions.count, projects: studioProjects.count,
                newestEdit: studioProjects.first?.updatedAt)
    }

    /// Rebuild the cached posts + per-session HR context/tile + per-clip HR payloads — snapshot on the
    /// MainActor, compose on a background task, assign back in one shot (prompt 106). Cancel-and-restart:
    /// a burst of `feedKey` changes (the per-post aspect backfill) coalesces via `debounce` into one
    /// rebuild; the first appearance builds immediately so the feed paints without an artificial delay.
    /// `Task.detached` (not a nonisolated-async hop) so the compose is off-main regardless of the
    /// language mode's isolation-inheritance default.
    private func rebuildFeed(debounce: Bool = false) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            let snap = makeSnapshot()
            let composed = await Task.detached(priority: .userInitiated) { Self.compose(snap) }.value
            guard !Task.isCancelled else { return }   // a newer rebuild superseded this one
            cachedPosts = composed.posts
            cachedHRContext = composed.hr
            cachedHRTiles = composed.tiles
            cachedPayloads = composed.payloads
        }
    }

    /// sessionID → the session's SAVED Studio HR tile (the WYSIWYG override, prompt 89), present only when
    /// the user customized it in the Studio; otherwise the poster keeps the house-style `.feedClipScorebug`.
    private var sessionHRTile: [UUID: HRTile] {
        Dictionary(studioProjects.compactMap { p in p.hrOverlay?.tile.map { (p.sessionID, $0) } },
                   uniquingKeysWith: { a, _ in a })
    }

}

// MARK: - Filter chip strip (prompt 107)

/// The Clips filter chips: ♥ Favorites · Climbs · Gym · Videos · Photos. Visible above the feed (the
/// #264 lesson — filters people can SEE get used), scrolls away with content, and hides entirely while
/// the search field is up (one control in charge at a time; matches the wireframe). Discipline and
/// media-kind pairs are mutually exclusive by construction (one enum value each); Favorites stacks
/// with anything. Tapping an active chip turns it off.
private struct ClipFilterChipStrip: View {
    @Binding var filter: ClipFeedFilter
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if !isSearching {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Favorites", icon: "heart.fill", accent: SnappetColor.brand,
                         on: filter.favoritesOnly, id: "clips.filter.favorites") {
                        filter.favoritesOnly.toggle()
                    }
                    chip("Climbs", icon: "figure.climbing", accent: SnappetColor.kilter,
                         on: filter.discipline == .climbs, id: "clips.filter.climbs") {
                        filter.discipline = filter.discipline == .climbs ? .all : .climbs
                    }
                    chip("Gym", icon: "figure.strengthtraining.traditional", accent: SnappetColor.workout,
                         on: filter.discipline == .gym, id: "clips.filter.gym") {
                        filter.discipline = filter.discipline == .gym ? .all : .gym
                    }
                    chip("Videos", icon: "play.rectangle", accent: SnappetColor.brand,
                         on: filter.kind == .videos, id: "clips.filter.videos") {
                        filter.kind = filter.kind == .videos ? .all : .videos
                    }
                    chip("Photos", icon: "photo", accent: SnappetColor.brand,
                         on: filter.kind == .photos, id: "clips.filter.photos") {
                        filter.kind = filter.kind == .photos ? .all : .photos
                    }
                }
                .padding(.horizontal, SnappetSpacing.lg)
            }
            .accessibilityIdentifier("clips.filter.chips")
        }
    }

    private func chip(_ label: String, icon: String, accent: Color, on: Bool,
                      id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? accent : SnappetColor.textSecondary)
            .background(on ? accent.opacity(0.16) : SnappetColor.surfaceMuted, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? accent : SnappetColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - One post (header · carousel · meta · ⋯ menu)

private struct StudioPresentation: Identifiable {
    let id = UUID()
    let project: StudioProject
    let focus: UUID?
    let visible: Set<UUID>?
}

/// An exported clip video to share via `ShareSheet` (prompt 87).
private struct ClipShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The Clips fullscreen presentation (prompt 94): a post's clips + HR context, opened at the tapped page.
private struct ClipFullscreen: Identifiable {
    let id = UUID()
    let clips: [MediaInput]
    let startIndex: Int
    let series: [HRPoint]
    let maxHR: Double
    let restHR: Double?
    let title: String
    let tile: HRTile?
}

private struct ClipPostCard: View {
    let post: ClipFeedPost
    let hr: ClipFeedHR
    let allMedia: [SessionMedia]
    /// The feed's single active inline clip + scroll flag (prompt 85/97) — `@Observable`, passed by reference.
    /// The card's `body` reads ONLY `playback.isScrolling` (which a horizontal carousel swipe never flips), so a
    /// swipe writing `playback.playing` does NOT re-evaluate this card; only the matching leaf `ClipPosterView`
    /// (which reads `playback.playing`) re-renders.
    let playback: ClipFeedPlayback
    /// Favorite reactions (prompt 88) — shared UserDefaults-backed store.
    let reactions: ClipReactionStore
    /// The session's saved Studio HR tile (WYSIWYG override, prompt 89); nil → the house-style scorebug.
    let hrTile: HRTile?
    /// Precomputed per-clip HR overlay payloads (keyed by clip media id) — built once off the swipe path so a
    /// page change doesn't re-slice/re-stat the HR window per page (prompt 92 perf).
    let payloads: [UUID: ClipHROverlay.Payload]
    /// Autoplay is on + allowed (prompt 90) — when this card is on-screen it plays its clip muted.
    let autoplayActive: Bool
    /// The feed's content width (measured once at the feed level) — drives the adaptive tile height, so it's
    /// correct from the first render and never pops during scroll.
    let contentWidth: CGFloat

    @Environment(\.modelContext) private var context
    @Environment(SuiteRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var studio: StudioPresentation?
    /// Whether this card is substantially on-screen (drives autoplay; prompt 90).
    @State private var isOnScreen = false
    /// Whether this card is even slightly on-screen — drives WARM preloading (the adjacent post above/below
    /// loads its player paused so it plays instantly when you settle on it; the R12 black-box risk area).
    @State private var isNearScreen = false
    /// Share-a-clip (prompt 87): the exported temp video handed to the system share sheet, + a busy flag.
    @State private var shareItem: ClipShareItem?
    @State private var preparingShare = false
    @State private var shareFailed = false
    /// Tap a playing clip → the fullscreen player with play/pause + scrubber (prompt 94).
    @State private var fullscreen: ClipFullscreen?

    private var accent: Color {
        // Apple Watch imports get the perf-green source tint (a data/state hue, not a wayfinding accent)
        // so they read as "from your watch" regardless of the underlying discipline (watch-workouts-clips P3).
        if post.isFromAppleWatch { return SnappetColor.perfFresh }
        switch post.discipline {
        case .climbing: return SnappetColor.kilter
        case .strength: return SnappetColor.workout
        case .general: return SnappetColor.brand
        }
    }

    /// Adaptive tile height (prompt 92): the full-bleed card width ÷ the post's clamped aspect, so the
    /// media fills the tile with no letterbox/pillarbox bars. Falls back to a sensible width until measured.
    private var carouselHeight: CGFloat {
        let w = contentWidth > 0 ? contentWidth : 393
        return (w / CGFloat(post.aspect)).rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            carousel
            meta
        }
        // Lazy-backfill the post's first-clip aspect on appearance (prompt 92) so the tile resizes to the
        // media; one-shot per clip (skips when already resolved), cached, persisted to SessionMedia.
        .task(id: post.id) { await backfillAspect() }
        // Autoplay-on-scroll (prompt 90 + polish): when autoplay is allowed and this card is substantially
        // on-screen, it becomes the single active clip and plays MUTED. A per-card visibility signal, NOT
        // scroll-center geometry / a coordinator (the R12 black-box mechanism). At 0.7, only one full-width
        // card qualifies. Playback only STARTS when the scroll is SETTLED (`!isScrolling`) — so cards don't
        // churn still↔player while you fling past them (the flicker). A card leaving the screen still clears.
        .onScrollVisibilityChange(threshold: 0.7) { visible in
            isOnScreen = visible
            // Start the centred clip only once SETTLED. Do NOT stop a playing clip mid-scroll — that froze
            // the video to its poster on every card you flung past (a flicker). The playing clip keeps
            // playing as it translates; the settle handler below switches to the newly-centred one cleanly.
            if visible, !playback.isScrolling, autoplayActive {
                playback.playing = PlayingClipRef(postID: post.id, page: page, muted: true)
            }
        }
        // When the feed settles, the on-screen card becomes the single active (muted) clip.
        .onChange(of: playback.isScrolling) { _, scrolling in
            guard autoplayActive, !scrolling, isOnScreen else { return }
            playback.playing = PlayingClipRef(postID: post.id, page: page, muted: true)
        }
        // WARM preload: any-visible posts mount their current page's player (paused) so scrolling onto them
        // plays instantly. A low threshold so the post above/below warms before it's the active one.
        .onScrollVisibilityChange(threshold: 0.02) { visible in isNearScreen = visible }
        .fullScreenCover(item: $studio) { p in
            StudioEditorView(project: p.project, context: context,
                             focusClipMediaID: p.focus, visibleClipMediaIDs: p.visible)
        }
        // Tap-to-fullscreen player (prompt 94): the post's clips at the tapped page, with play/pause +
        // scrubber + the WYSIWYG HR tile. The viewer takes the audio session while open; re-assert the
        // feed's mute state on dismiss.
        .fullScreenCover(item: $fullscreen, onDismiss: {
            if let pc = playback.playing, !pc.muted { ClipAudioSession.activate() } else { ClipAudioSession.deactivate() }
        }) { f in
            MediaBrowserView.clipsViewer(clips: f.clips, startIndex: f.startIndex,
                                         hrSeries: f.series, maxHR: f.maxHR, restHR: f.restHR,
                                         nameFor: { _ in f.title }, tile: f.tile)
        }
        // Share-a-clip (prompt 87): the system share sheet for the exported clip; delete the temp export
        // once the sheet completes (shared or cancelled) so it doesn't accumulate in tmp.
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url], onComplete: { _, _ in try? FileManager.default.removeItem(at: item.url) })
        }
        .overlay {
            if preparingShare {
                ProgressView("Preparing…").padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .alert("Couldn’t prepare this clip", isPresented: $shareFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("The clip couldn’t be exported to share. Try again, or open it in the Studio.") }
    }

    // The "yellow circle": session + exercise/climb name; the "red circle": the ⋯ options menu.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.16), in: Circle())
                .overlay(Circle().strokeBorder(accent, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(post.title).font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                    if post.isFromAppleWatch { watchSourceBadge }
                }
                Text(post.subtitle).font(.caption).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            favoriteButton
            optionsMenu
        }
        .padding(.horizontal, SnappetSpacing.lg)
    }

    /// The ⌚ "Apple Watch" source chip on a watch-imported post's header (watch-workouts-clips P3).
    private var watchSourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "applewatch").font(.system(size: 9, weight: .bold))
            Text("Apple Watch").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(SnappetColor.perfFresh)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(SnappetColor.perfFresh.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(SnappetColor.perfFresh.opacity(0.5), lineWidth: 1))
        .accessibilityLabel("From Apple Watch")
    }

    // ❤️ favorite reaction (prompt 88) — a button (not a double-tap) so it can't fight the tap-to-play poster.
    private var favoriteButton: some View {
        Button { reactions.toggle(post.id) } label: {
            Image(systemName: reactions.isFavorite(post.id) ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(reactions.isFavorite(post.id) ? .red : SnappetColor.ink)
                .symbolEffect(.bounce, value: reduceMotion ? false : reactions.isFavorite(post.id))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("clips.post.favorite")
        .accessibilityLabel(reactions.isFavorite(post.id) ? "Unfavorite" : "Favorite")
    }

    private var glyph: String {
        if post.isFromAppleWatch { return "applewatch" }
        switch post.discipline {
        case .climbing: return "figure.climbing"
        case .strength: return "figure.strengthtraining.traditional"
        case .general: return "sparkles"
        }
    }

    private var optionsMenu: some View {
        Menu {
            // The Studio is a VIDEO editor — photos aren't clip-editable (mirrors
            // `SessionDetailView.editClip`'s `kind == .video` guard), so a photo / photo-only post
            // opening the editor would land on an empty timeline. Scope the edit actions to videos.
            if currentClip.media.kind == "video" {
                Button { editCurrentClip() } label: { Label("Edit this clip", systemImage: "slider.horizontal.3") }
                Button { shareCurrentClip() } label: { Label("Share clip", systemImage: "square.and.arrow.up") }
            }
            if editableClipIDs.count > 1 {
                Button { editAllClips() } label: { Label("Edit all · \(editableClipIDs.count)", systemImage: "rectangle.stack") }
            }
            Button { goToSession() } label: { Label("Go to session", systemImage: "arrow.up.forward.square") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SnappetColor.ink)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("clips.post.menu")
    }

    /// Whether carousel page `idx` should be WARM-mounted (paused, ready) based ONLY on this card's own @State
    /// — deliberately does NOT read `playback.playing` (the leaf `ClipPosterView` OR-s in the playing case), so
    /// the card `body` doesn't depend on `playback.playing` and a swipe doesn't re-evaluate the whole card
    /// (prompt 97). The on-screen post warms the current page ± its carousel neighbours (instant swipe); any
    /// near-screen post warms just its current page. Bounded (~3 + 1 per neighbour) to limit the R12 risk.
    private func warmLive(_ idx: Int) -> Bool {
        guard autoplayActive else { return false }                      // autoplay off → mount only on tap (leaf)
        if idx == page { return isOnScreen || isNearScreen }            // the current page is warm immediately
        // Warm the ±1 carousel neighbours off the CURRENT `page` DIRECTLY (no 80ms-delayed copy). The delay was
        // a round-3 workaround to keep a new player's mount off the snap frame — obsolete now that the build is
        // OFF-MAIN (prompt 97) and no longer re-renders the feed: an eager mount can't block the slide. Warming
        // during the DWELL gives the neighbour's layer time to become isReadyForDisplay (decode its first frame)
        // BEFORE you swipe, so a fast swipe lands on an already-decoded frame instead of a poster that pops to
        // video at the snap (the "abrupt second half"; slow swipes already had that lead time). Bounded ±1 (R12).
        return isOnScreen && abs(idx - page) <= 1
    }

    private var carousel: some View {
        VStack(spacing: 8) {
            TabView(selection: $page) {
                ForEach(Array(post.clips.enumerated()), id: \.element.id) { idx, item in
                    // `TabView(.page)` is EAGER — it builds every page up front, so a clip-heavy post (a
                    // session with 50 untagged videos = one 50-page post) fired 50 concurrent frame-0
                    // decodes the moment the card scrolled in (prompt 106). The scale fix is to window the
                    // HEAVY WORK, not the view: every page keeps its (cheap) `ClipPosterView` mounted with
                    // STABLE identity, and only the poster-bitmap load is gated to ±3 of the current page
                    // (`loadPoster`). The first cut of this windowed the VIEW instead — an `if/else` swapping
                    // `ClipPosterView` ↔ placeholder — but branch changes are identity changes: every snap
                    // commit destroyed two pages and mounted two fresh ones ON the settle frame, which read
                    // as carousel jitter (round 2; the same identity discipline prompt 97 is built on). The
                    // warm/live player bound (±1, `warmLive`) is unchanged.
                    //
                    // Tap a still video poster → it plays INLINE here (prompt 85), becoming the feed's single
                    // active clip; tapping the playing video pauses/resumes it (handled inside the surface).
                    ClipPosterView(item: item, post: post,
                                   playback: playback, postID: post.id, postIndex: idx,
                                   payload: payloads[item.media.id],   // precomputed off the swipe path (perf)
                                   warmLive: warmLive(idx),
                                   loadPoster: abs(idx - page) <= 3,
                                   isCurrentPage: idx == page,
                                   postOnScreen: isOnScreen,
                                   onTapToPlay: {
                                       guard item.media.kind == "video" else { return }   // photos stay still
                                       playback.playing = PlayingClipRef(postID: post.id, page: idx)   // tap → unmuted
                                   },
                                   onToggleMute: {
                                       if var pc = playback.playing, pc.matches(post.id, idx) { pc.muted.toggle(); playback.playing = pc }
                                   },
                                   onOpenFullscreen: {
                                       // Stop the inline player first so it isn't decoding + emitting audio
                                       // UNDER the fullscreen player (doubled audio/decode — prompt 94 review).
                                       // The snapshot below carries its own clips/startIndex, so it's
                                       // independent of playback.playing; clearing it releases the inline audio
                                       // session via ClipFeedPlayback.playing's didSet.
                                       playback.playing = nil
                                       fullscreen = ClipFullscreen(
                                           clips: post.clips.map(\.media), startIndex: idx,
                                           series: hr.series, maxHR: hr.maxHR, restHR: hr.restHR,
                                           title: post.title, tile: hrTile)
                                   })
                        .tag(idx)
                        .accessibilityIdentifier("clips.post.page")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: carouselHeight)
            // Animate the height resolve, but NOT while scrolling — an implicit frame animation mid-scroll
            // re-lays-out the whole paged container every frame (a jerk source).
            .animation(playback.isScrolling ? nil : .easeInOut(duration: 0.25), value: carouselHeight)
            // Swiping the carousel: autoplay follows to the new page (muted); a tap-play stops (you moved off
            // it, prompt 85). Either way one live player.
            .onChange(of: page) { _, newPage in
                if autoplayActive, isOnScreen, !playback.isScrolling {
                    playback.playing = PlayingClipRef(postID: post.id, page: newPage, muted: true)
                } else if let pc = playback.playing, pc.postID == post.id, pc.page != newPage {
                    playback.playing = nil
                }
                // (No warm-window defer: `warmLive` now warms the ±1 neighbours off `page` directly — prompt 97.)
            }
            .overlay(alignment: .topTrailing) {
                if post.clipCount > 1 {
                    Text("\(min(page, post.clipCount - 1) + 1)/\(post.clipCount)")
                        .font(.caption2.weight(.heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(10)
                }
            }
            // One dot per clip stops scaling fast — 50 clips would draw a ~550 pt row that overflows the
            // card. Above 8 the dots go; the "n/N" counter overlay (always on for multi-clip posts) carries
            // the position instead.
            if post.clipCount > 1, post.clipCount <= 8 {
                HStack(spacing: 5) {
                    ForEach(0..<post.clipCount, id: \.self) { i in
                        Circle().fill(i == page ? accent : SnappetColor.textSecondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var meta: some View {
        Text("\(post.clipCount) clip\(post.clipCount == 1 ? "" : "s") · \(post.captureAt.formatted(.relative(presentation: .named)))")
            .font(.caption).foregroundStyle(SnappetColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SnappetSpacing.lg)
    }

    // MARK: ⋯ actions — reuse the existing Studio + session-detail entry points

    /// The clip currently centered in the carousel (clamped — `page` can outlive a clip-count change).
    private var currentClip: ClipFeedItem { post.clips[min(max(0, page), post.clips.count - 1)] }

    /// The post's editable clips: VIDEOS only (the Studio's main track seeds from videos — photos
    /// aren't clip-editable). The ⋯ edit actions scope to these so the editor never opens empty.
    private var editableClipIDs: [UUID] { post.clips.filter { $0.media.kind == "video" }.map(\.media.id) }

    private func project() -> StudioProject {
        StudioEntry.resolveProject(forSessionID: post.sessionID, title: post.title, media: allMedia, context: context)
    }

    private func editCurrentClip() {
        let clip = currentClip
        guard clip.media.kind == "video" else { return }
        studio = StudioPresentation(project: project(), focus: clip.media.id, visible: [clip.media.id])
    }

    /// Share the centered clip's RAW video via the system share sheet (prompt 87) — export off the main
    /// actor, then present `ShareSheet`. (The HR-overlay-burned share is ⋯ → Edit this clip → Studio.)
    private func shareCurrentClip() {
        let clip = currentClip
        guard clip.media.kind == "video", !preparingShare else { return }
        preparingShare = true
        Task { @MainActor in
            let url = await ClipShareService.exportForSharing(localIdentifier: clip.media.localIdentifier)
            preparingShare = false
            if let url { shareItem = ClipShareItem(url: url) } else { shareFailed = true }
        }
    }

    private func editAllClips() {
        let ids = editableClipIDs
        guard !ids.isEmpty else { return }
        studio = StudioPresentation(project: project(), focus: ids.first, visible: Set(ids))
    }

    private func goToSession() {
        router.open(module: post.moduleID)
        if post.kind == .kilter { router.push(KilterSessionRoute(id: post.sessionID)) }
        else { router.push(SessionRoute(id: post.sessionID)) }
    }

    /// Resolve + persist the post's first-clip oriented aspect (prompt 92) — the one that drives the tile
    /// height. Skips when already known; the resolver caches, and the `@Query` re-render resizes the tile.
    private func backfillAspect() async {
        guard let item = post.clips.first,
              let media = allMedia.first(where: { $0.id == item.media.id }),
              media.aspectRatio == nil else { return }
        if let a = await ClipAspectResolver.shared.aspect(localIdentifier: media.localIdentifier,
                                                          isVideo: media.kind == .video) {
            media.aspectRatio = a
            try? context.save()
        }
    }
}


// MARK: - One carousel poster — still frame + name overlay + HR scorebug

private struct ClipPosterView: View {
    let item: ClipFeedItem
    let post: ClipFeedPost
    /// The feed's active-clip state (prompt 97). This LEAF reads `playback.playing` (via the `playing` computed
    /// below) so a swipe re-renders ONLY the two pages whose playing/live actually changed — not the card or the
    /// feed. The card passes `playback` + this page's identity; the leaf decides if IT plays.
    let playback: ClipFeedPlayback
    let postID: String
    let postIndex: Int
    /// The clip's HR overlay — built ONCE by the card (not per live-HR tick); drives the surface + the tile.
    let payload: ClipHROverlay.Payload?
    /// Card-decided WARM mount (preloaded + paused), from the card's own @State only (no `playback.playing`).
    /// `live` below OR-s this with `playing` so the active clip always mounts even when not warm.
    let warmLive: Bool
    /// Whether this page should LOAD its poster bitmap (±3 of the current page — prompt 106 round 2).
    /// The view itself stays mounted regardless (stable identity, no snap-frame churn); a far page just
    /// shows the placeholder gradient until the window reaches it and the thumbnail request fires.
    let loadPoster: Bool
    /// This poster is the carousel's CURRENT page (idx == page). A non-current page is a carousel sibling
    /// sitting OFF to the side (clipped by the TabView) — its warm player can stay visible (paused frame) so
    /// a swipe reveals an already-correct frame, no crossfade.
    let isCurrentPage: Bool
    /// This post is substantially on-screen (it's the one you're viewing) vs a feed neighbour above/below.
    let postOnScreen: Bool
    /// Tap a still video → ask the feed to make this the active clip.
    let onTapToPlay: () -> Void
    /// Toggle this clip's audio (prompt 93) — the speaker button + a tap on a muted autoplaying surface
    /// both call it; the feed flips `playback.playing.muted` (the single source of truth) both ways.
    let onToggleMute: () -> Void
    /// Tap the PLAYING video → open the fullscreen player with play/pause + scrubber (prompt 94).
    let onOpenFullscreen: () -> Void
    /// Live playhead written by the inline `ClipMediaSurface`; the HR tile reads it while playing.
    @State private var liveFraction: Double = ClipHROverlay.atEndFraction

    /// This clip is the feed's single ACTIVE inline clip → it plays (isActive); warm clips stay paused. Reading
    /// `playback.playing` HERE (not in the card) is what scopes a swipe's re-render to just this leaf (prompt 97).
    private var playing: Bool { playback.playing?.matches(postID, postIndex) == true }
    /// This clip should have a MOUNTED player — playing OR card-warmed. Drives whether `ClipMediaSurface` exists.
    private var live: Bool { playing || warmLive }
    /// Start the inline player muted (autoplay; prompt 90) — mirrors the old card-passed value (false for a
    /// non-active page; the active ref's `muted` otherwise). Consumers gate on `playing` first regardless.
    private var muted: Bool { playing ? (playback.playing?.muted ?? true) : false }

    var body: some View {
        // Size the media to the actual carousel page (not a hard-coded size) so it fills full-bleed.
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // The still poster is ALWAYS the base (no still↔player swap), so it shows through while the
                // player loads (the surface's loading state is transparent) and reappears instantly when the
                // clip stops — eliminating the spinner/black flash on every autoplay start/stop.
                ClipThumbnail(localIdentifier: item.media.localIdentifier, kind: item.media.kind,
                              size: geo.size, enabled: loadPoster,
                              posterTime: ClipHROverlay.playedRange(item.media).start)
                    .contentShape(Rectangle())
                    .onTapGesture { onTapToPlay() }
                // The inline player, overlaid on the still whenever this clip is LIVE (playing OR warm). A
                // warm clip is mounted with isActive:false → loaded + paused → it starts instantly when it
                // becomes the active clip. Only the PLAYING clip is interactive (tap → fullscreen, audio);
                // warm clips let taps fall through to the still (onTapToPlay makes them the active clip).
                if live, item.media.kind == "video" {
                    ClipMediaSurface(clip: item.media, isActive: playing, payload: payload,
                                     fraction: $liveFraction, background: .clear, muted: playing ? muted : true,
                                     onUnmute: onToggleMute,
                                     onSurfaceTap: playing ? onOpenFullscreen : nil, fill: true)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(playing)
                        // Keep the CAROUSEL sibling's video frame visible (opacity 1) so a swipe shows
                        // continuous video — the outgoing clip just PAUSES in place instead of cutting back
                        // to its poster, and the incoming clip is already its own frame (the clear backing
                        // shows the still poster through until the frame decodes, so no black). This removes
                        // the video↔poster cuts that were the swipe jerk. Hide ONLY a vertically-visible feed
                        // NEIGHBOUR's current page (idx==page on an off-screen post) so it can't flash a frame
                        // during a vertical scroll.
                        .opacity((!playing && isCurrentPage && !postOnScreen) ? 0 : 1)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 10) {
                    nameOverlay
                    // HR scorebug on every page (so it slides smoothly with the carousel, no pop-in). It's
                    // cheap now: the inline tile uses a flat scrim (liveBlur: false), not a live backdrop
                    // blur, so sliding it doesn't re-rasterize a blur every frame.
                    hrOverlay
                }
                .padding(12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .background(Color.black)
            // Seed the live playhead at the at-rest boundary the moment this clip becomes the active
            // one: the @State default (1.0) is the TAIL END under an extended window, and a cold
            // tap-to-play would flash the dot into the off-camera tail for a tick before the surface's
            // load()/ticker writes the real position (prompt 116 review).
            .onChange(of: playing) { _, isPlaying in
                if isPlaying { liveFraction = ClipHROverlay.atEnd(for: payload) }
            }
            // Instagram-style mute toggle (prompt 93): only on the PLAYING video, top-leading so it can't
            // collide with the bottom HR scorebug or the top-trailing page counter. Driven by `muted`
            // (== playingClip.muted) so it stays in sync with autoplay + the scroll/transfer logic.
            .overlay(alignment: .topLeading) {
                if playing, item.media.kind == "video" { muteButton.padding(12) }
            }
            // Studio-trimmed clip (prompt 116): a subtle chip naming the kept range — the honest signal
            // that the feed plays the edit (and that speed/filters/text live in the export/bake).
            // Gated + labelled by the EFFECTIVE kept range (the same `keptRange` verdict playback and
            // the HR window use) — a degenerate/whole-clip stored trim plays raw and shows NO chip.
            .overlay(alignment: .topTrailing) {
                if item.media.isBaked {
                    bakedChip.padding(12)
                } else if let kept = item.media.edit?.keptRange(rawDurationSec: item.media.durationSec ?? 0) {
                    editedChip(kept).padding(12)
                }
            }
        }
    }

    /// A bake wrote the edit into the pixels (prompt 117): full parity — trims, filters, text, the HR
    /// tile at the user's placement — because it's just video; the app's live overlay stands down.
    private var bakedChip: some View {
        Text("BAKED ✓")
            .font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(0.4)
            .foregroundStyle(SnappetColor.perfFresh)   // "done/positive" state → the perf ramp token
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(SnappetColor.perfFresh.opacity(0.6), lineWidth: 1))
            .accessibilityIdentifier("clips.post.baked")
    }

    private func editedChip(_ kept: ClosedRange<Double>) -> some View {
        Text("EDITED · \(SetMeasure.formatDuration(kept.lowerBound))–\(SetMeasure.formatDuration(kept.upperBound))")
            .font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(0.4)
            .foregroundStyle(SnappetColor.workout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(SnappetColor.workout.opacity(0.6), lineWidth: 1))
            .accessibilityIdentifier("clips.post.edited")
    }

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("clips.post.mute")
        .accessibilityLabel(muted ? "Unmute" : "Mute")
    }

    // The climb-name lower-third (OverlayItem.climbName look) + the per-clip attempt/set chip.
    private var nameOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(post.title).font(.title3.weight(.heavy)).foregroundStyle(.white).lineLimit(1)
            if !post.overlayDetail.isEmpty {
                Text(post.overlayDetail).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
            }
            if let attempt = item.attemptLabel {
                Text(attempt).font(.caption2.weight(.bold)).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.top, 3)
            }
        }
        .padding(10)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // The HR scorebug — the ONE `ClipHROverlay` mapping the poster, the inline player, and the fullscreen
    // viewer share. While this clip plays inline it sweeps off the live `liveFraction`; otherwise it shows
    // the clip's at-end reading.
    @ViewBuilder private var hrOverlay: some View {
        if let payload {
            HRTileView(tile: payload.tile, values: payload.values,
                       fraction: playing ? liveFraction : ClipHROverlay.atEnd(for: payload),
                       liveBlur: false)   // flat scrim, not a live backdrop blur → cheap to slide (prompt 92)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                // Glide the BPM dot from the at-end reading into the live sweep at takeover instead of snapping
                // — the small HR-overlay discontinuity the frame-0 poster fix doesn't touch (round 5 graft).
                .animation(.easeOut(duration: 0.18), value: playing)
                .allowsHitTesting(false)
                .accessibilityIdentifier("clips.post.hrTile")
        }
    }
}
