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

/// Per-session HR context the posters slice their scorebug window from.
struct ClipFeedHR: Equatable {
    var series: [HRPoint]
    var maxHR: Double
    var restHR: Double?
}

/// Identifies the feed's single active inline clip — a post + the carousel page within it (prompt 85).
struct PlayingClipRef: Equatable {
    var postID: String
    var page: Int
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
    /// The feed's single active inline clip — "last tapped wins", so only ONE clip plays across the whole
    /// feed (prompt 85). Tap-driven, NOT scroll-driven (the R12 hero's scroll-center coordinator is what
    /// rendered a black box in the scrolling card).
    @State private var playingClip: PlayingClipRef?
    /// Explore-grid sheet (prompt 86) + the post id to scroll the feed to when a grid cover is picked.
    @State private var showGrid = false
    @State private var scrollTarget: String?
    /// Favorite reactions (prompt 88) — UserDefaults-backed, no new @Model.
    @State private var reactions = ClipReactionStore()

    var body: some View {
        let posts = composedPosts()
        return NavigationStack {
            Group {
                if posts.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 18) {
                                ForEach(posts) { post in
                                    ClipPostCard(post: post, hr: hrContext(for: post.sessionID),
                                                 allMedia: allMedia, playingClip: $playingClip,
                                                 reactions: reactions, hrTile: sessionHRTile[post.sessionID])
                                        .id(post.id)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("clips.feed")
                        // Scrolling the feed stops the inline player, so a tapped clip can't keep playing audio
                        // after its card scrolls off-screen (prompt 85). This is a feed-level gesture signal —
                        // NOT per-card scroll geometry, which is the R12 coordinator that rendered a black box.
                        .onScrollPhaseChange { _, newPhase, _ in
                            if newPhase != .idle, playingClip != nil { playingClip = nil }
                        }
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
            .background(SnappetColor.paper)
            .navigationTitle("Clips")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !posts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showGrid = true } label: { Image(systemName: "square.grid.3x3") }
                            .accessibilityIdentifier("clips.grid.button")
                    }
                }
            }
            .sheet(isPresented: $showGrid) {
                ClipsGridView(posts: posts, onPick: { scrollTarget = $0 })
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

    // MARK: Derivation (derive-on-read; no persistence)

    private func composedPosts() -> [ClipFeedPost] {
        // Bucket media by its owning session (MediaInput drops sessionID, so do it at the @Model edge).
        var bySession: [UUID: [MediaInput]] = [:]
        for m in allMedia { bySession[m.sessionID, default: []].append(MediaInput.from(m)) }
        guard !bySession.isEmpty else { return [] }

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
        for (sid, clips) in bySession {
            if let k = kilterByID[sid] {
                bundles.append(.init(meta: ClipFeedSessionMeta(id: sid, kind: .kilter,
                    title: k.title ?? "Kilter session", startedAt: k.startedAt, angle: k.angle), clips: clips))
            } else if let w = workoutByID[sid] {
                bundles.append(.init(meta: ClipFeedSessionMeta(id: sid, kind: .gym,
                    title: w.routineName, startedAt: w.startedAt, angle: nil), clips: clips))
            }
            // else: media whose session was deleted — skip (no orphan posts).
        }
        return ClipFeedComposer.posts(sessions: bundles, climbMeta: climbMeta,
                                      exerciseName: { exerciseName[$0] ?? "Exercise" })
    }

    /// sessionID → the session's SAVED Studio HR tile (the WYSIWYG override, prompt 89), present only when
    /// the user customized it in the Studio; otherwise the poster keeps the house-style `.feedClipScorebug`.
    private var sessionHRTile: [UUID: HRTile] {
        Dictionary(studioProjects.compactMap { p in p.hrOverlay?.tile.map { (p.sessionID, $0) } },
                   uniquingKeysWith: { a, _ in a })
    }

    private func hrContext(for sid: UUID) -> ClipFeedHR {
        if let k = kilterSessions.first(where: { $0.id == sid }) {
            return ClipFeedHR(series: k.hrSeries, maxHR: k.maxHR ?? 190, restHR: k.restHR)
        }
        if let w = workoutSessions.first(where: { $0.id == sid }) {
            return ClipFeedHR(series: w.hrSeries, maxHR: w.maxHR ?? 190, restHR: w.restHR)
        }
        return ClipFeedHR(series: [], maxHR: 190, restHR: nil)
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

private struct ClipPostCard: View {
    let post: ClipFeedPost
    let hr: ClipFeedHR
    let allMedia: [SessionMedia]
    /// The feed's single active inline clip (prompt 85) — this card plays the page that matches it.
    @Binding var playingClip: PlayingClipRef?
    /// Favorite reactions (prompt 88) — shared UserDefaults-backed store.
    let reactions: ClipReactionStore
    /// The session's saved Studio HR tile (WYSIWYG override, prompt 89); nil → the house-style scorebug.
    let hrTile: HRTile?

    @Environment(\.modelContext) private var context
    @Environment(SuiteRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var studio: StudioPresentation?
    /// Share-a-clip (prompt 87): the exported temp video handed to the system share sheet, + a busy flag.
    @State private var shareItem: ClipShareItem?
    @State private var preparingShare = false
    @State private var shareFailed = false

    private var accent: Color {
        switch post.discipline {
        case .climbing: return SnappetColor.kilter
        case .strength: return SnappetColor.workout
        case .general: return SnappetColor.brand
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            carousel
            meta
        }
        .fullScreenCover(item: $studio) { p in
            StudioEditorView(project: p.project, context: context,
                             focusClipMediaID: p.focus, visibleClipMediaIDs: p.visible)
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
                Text(post.title).font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                Text(post.subtitle).font(.caption).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            favoriteButton
            optionsMenu
        }
        .padding(.horizontal, SnappetSpacing.lg)
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

    private var carousel: some View {
        VStack(spacing: 8) {
            TabView(selection: $page) {
                ForEach(Array(post.clips.enumerated()), id: \.element.id) { idx, item in
                    // Tap a still video poster → it plays INLINE here (prompt 85), becoming the feed's single
                    // active clip; tapping the playing video pauses/resumes it (handled inside the surface).
                    ClipPosterView(item: item, post: post,
                                   payload: ClipHROverlay.make(clip: item.media, hrSeries: hr.series,
                                                               maxHR: hr.maxHR, restHR: hr.restHR, tile: hrTile),
                                   isPlaying: playingClip == PlayingClipRef(postID: post.id, page: idx),
                                   onTapToPlay: {
                                       guard item.media.kind == "video" else { return }   // photos stay still
                                       playingClip = PlayingClipRef(postID: post.id, page: idx)
                                   })
                        .tag(idx)
                        .accessibilityIdentifier("clips.post.page")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 460)
            // Swiping the carousel off the playing clip stops it (you've moved away) — keeps one live player.
            .onChange(of: page) { _, newPage in
                if let pc = playingClip, pc.postID == post.id, pc.page != newPage { playingClip = nil }
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
            if post.clipCount > 1 {
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
}

// MARK: - One carousel poster — still frame + name overlay + HR scorebug

private struct ClipPosterView: View {
    let item: ClipFeedItem
    let post: ClipFeedPost
    /// The clip's HR overlay — built ONCE by the card (not per live-HR tick); drives the surface + the tile.
    let payload: ClipHROverlay.Payload?
    /// This clip is the feed's active inline clip → play it in place (prompt 85).
    let isPlaying: Bool
    /// Tap a still video → ask the feed to make this the active clip.
    let onTapToPlay: () -> Void
    /// Live playhead written by the inline `ClipMediaSurface`; the HR tile reads it while playing.
    @State private var liveFraction: Double = ClipHROverlay.atEndFraction

    var body: some View {
        // Size the media to the actual carousel page (not a hard-coded size) so it fills full-bleed.
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // The inline player when this is the feed's active video; otherwise the still poster (tap → play).
                if isPlaying, item.media.kind == "video" {
                    ClipMediaSurface(clip: item.media, isActive: true, payload: payload,
                                     fraction: $liveFraction, background: .black)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ClipThumbnail(localIdentifier: item.media.localIdentifier, kind: item.media.kind,
                                  size: geo.size)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapToPlay() }
                }
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 10) {
                    nameOverlay
                    hrOverlay
                }
                .padding(12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .background(Color.black)
        }
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
                       fraction: isPlaying ? liveFraction : ClipHROverlay.atEndFraction)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .allowsHitTesting(false)
                .accessibilityIdentifier("clips.post.hrTile")
        }
    }
}
