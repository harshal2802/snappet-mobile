import SwiftUI
import SwiftData

// One Clips post — header, carousel of posters, ⋯ menu — and its poster view. Split out of
// ClipsFeedView.swift (prompt 168, mechanical move, no behaviour change). The poster + the presentation
// helpers stay private to this file.

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

struct ClipPostCard: View {
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
    /// The user's default HR tile + title (prompt 163).
    let style: ClipOverlayStyle
    /// The feed is showing hidden clips (prompt 164) → the ⋯ menu offers Unhide instead of Hide.
    let showingHidden: Bool
    let onHide: (Set<UUID>) -> Void
    let onUnhide: (Set<UUID>) -> Void

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
        // A posted reel reads as a REEL first (reels-coral), whatever session it came from.
        if post.isReel { return SnappetColor.reels }
        // Apple Watch imports get the perf-green source tint (a data/state hue, not a wayfinding accent)
        // so they read as "from your watch" regardless of the underlying discipline (watch-workouts-clips P3).
        if post.isFromAppleWatch { return SnappetColor.perfFresh }
        switch post.discipline {
        case .climbing: return SnappetColor.kilter
        case .strength: return SnappetColor.workout
        case .festival: return SnappetColor.festival
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
                    if post.isReel { reelBadge }
                    if let result = post.climbResult, let word = result.badge { outcomeBadge(result.status, word) }
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

    /// The ✦ REEL chip on a posted highlight reel's header (highlights P2) — reels-coral, the
    /// same accent as the builder that made it.
    private var reelBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
            Text("REEL").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(SnappetColor.reels)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(SnappetColor.reels.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(SnappetColor.reels.opacity(0.5), lineWidth: 1))
        .accessibilityLabel("Highlight reel")
    }

    /// How the climb went this session (prompt 161) — FLASH / SENT / PROJECT in the ascent palette the
    /// session summaries use (`KilterAscentStyle`). A plain attempt gets no badge.
    private func outcomeBadge(_ status: KilterAscentStatus, _ word: String) -> some View {
        let tint = KilterAscentStyle.color(status)
        return HStack(spacing: 3) {
            Image(systemName: KilterAscentStyle.glyph(status)).font(.system(size: 9, weight: .bold))
            Text(word.uppercased()).font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .accessibilityIdentifier("clips.post.outcome")
        .accessibilityLabel(word)
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
        Button { reactions.toggle(post) } label: {
            Image(systemName: reactions.isFavorite(post) ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(reactions.isFavorite(post) ? .red : SnappetColor.ink)
                .symbolEffect(.bounce, value: reduceMotion ? false : reactions.isFavorite(post))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("clips.post.favorite")
        .accessibilityLabel(reactions.isFavorite(post) ? "Unfavorite" : "Favorite")
    }

    private var glyph: String {
        if post.isReel { return "sparkles.tv" }
        if post.isFromAppleWatch { return "applewatch" }
        switch post.discipline {
        case .climbing: return "figure.climbing"
        case .strength: return "figure.strengthtraining.traditional"
        case .festival: return "music.mic"
        case .general: return "sparkles"
        }
    }

    private var optionsMenu: some View {
        Menu {
            // The Studio is a VIDEO editor — photos aren't clip-editable (mirrors
            // `SessionDetailView.editClip`'s `kind == .video` guard), so a photo / photo-only post
            // opening the editor would land on an empty timeline. Scope the edit actions to videos.
            // A posted reel shares but never edits (highlights P5) — the Studio timeline excludes
            // reels, so "Edit this clip" would land on an empty editor too.
            if currentClip.media.kind == "video" {
                if !currentClip.media.isReel {
                    Button { editCurrentClip() } label: { Label("Edit this clip", systemImage: "slider.horizontal.3") }
                }
                // Share (prompt 160): the HR-burned render is the primary share when there's HR to burn;
                // a reel / baked clip already carries it in the pixels, so its raw share IS the burned one.
                switch shareOffer {
                case .burnedAndRaw:
                    Button { shareCurrentClip(withHeartRate: true) } label: {
                        Label("Share with heart rate", systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("clips.post.shareHR")
                    Button { shareCurrentClip(withHeartRate: false) } label: {
                        Label("Share original clip", systemImage: "square.and.arrow.up")
                    }
                case .raw:
                    Button { shareCurrentClip(withHeartRate: false) } label: {
                        Label("Share clip", systemImage: "square.and.arrow.up")
                    }
                case .none:
                    EmptyView()
                }
            }
            if editableClipIDs.count > 1 {
                Button { editAllClips() } label: { Label("Edit all · \(editableClipIDs.count)", systemImage: "rectangle.stack") }
            }
            Button { goToSession() } label: { Label("Go to session", systemImage: "arrow.up.forward.square") }
            // Hide from Clips (prompt 164) — non-destructive: the clip stays in the session and Photos.
            Divider()
            let all = Set(post.clips.map(\.media.id))
            if showingHidden {
                Button { onUnhide([currentClip.media.id]) } label: { Label("Unhide this clip", systemImage: "eye") }
                    .accessibilityIdentifier("clips.post.unhide")
                if all.count > 1 {
                    Button { onUnhide(all) } label: { Label("Unhide all \(all.count)", systemImage: "eye") }
                }
            } else {
                Button { onHide([currentClip.media.id]) } label: { Label("Hide this clip from Clips", systemImage: "eye.slash") }
                    .accessibilityIdentifier("clips.post.hide")
                if all.count > 1 {
                    Button { onHide(all) } label: { Label("Hide post (\(all.count) clips)", systemImage: "eye.slash") }
                }
            }
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
                    ClipPosterView(item: item, post: post, style: style,
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
                                           title: post.title,
                                           tile: style.tile(sessionTile: hrTile, restHR: hr.restHR))
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
                        .padding(.top, topReserve)   // below a top-edge tile/title (prompt 163)
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

    /// How far the top chrome (page counter) drops to clear the style's top-edge overlays (prompt 163).
    private var topReserve: CGFloat {
        ClipOverlayChrome.topReserve(style: style, title: style.titleText(post.titleValues(for: currentClip)),
                                     tileTemplate: payloads[currentClip.media.id]?.tile.template,
                                     width: contentWidth)
    }

    /// The clip currently centered in the carousel (clamped — `page` can outlive a clip-count change).
    private var currentClip: ClipFeedItem { post.clips[min(max(0, page), post.clips.count - 1)] }

    /// The post's editable clips: non-reel VIDEOS only (the Studio's main track seeds from videos
    /// and excludes posted reels). The ⋯ edit actions scope to these so the editor never opens empty.
    private var editableClipIDs: [UUID] {
        post.clips.filter { $0.media.kind == "video" && !$0.media.isReel }.map(\.media.id)
    }

    private func project() -> StudioProject {
        StudioEntry.resolveProject(forSessionID: post.sessionID, title: post.title, media: allMedia, context: context)
    }

    private func editCurrentClip() {
        let clip = currentClip
        guard clip.media.kind == "video", !clip.media.isReel else { return }
        studio = StudioPresentation(project: project(), focus: clip.media.id, visible: [clip.media.id])
    }

    /// Which share actions the centred clip offers (prompt 160) — from the SAME payload its poster draws.
    private var shareOffer: ClipSharePlan.Offer {
        ClipSharePlan.offer(for: currentClip.media, payload: payloads[currentClip.media.id])
    }

    /// Share the centered clip via the system share sheet — export off the main actor, then present
    /// `ShareSheet`. `withHeartRate` (prompt 160) burns the poster's HR tile + title — at the user's
    /// overlay style (prompt 163) — over the kept range; otherwise the RAW video (prompt 87).
    private func shareCurrentClip(withHeartRate: Bool) {
        let clip = currentClip
        guard clip.media.kind == "video", !preparingShare else { return }
        let plan = withHeartRate
            ? ClipSharePlan.plan(clip: clip.media, payload: payloads[clip.media.id],
                                 title: style.titleText(post.titleValues(for: clip)), style: style)
            : nil
        if withHeartRate, plan == nil { shareFailed = true; return }
        preparingShare = true
        Task { @MainActor in
            let url: URL?
            if let plan { url = await ClipShareService.exportWithHeartRate(plan) }
            else { url = await ClipShareService.exportForSharing(localIdentifier: clip.media.localIdentifier) }
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
    /// The user's default title + tile layout (prompt 163) — drawn by the shared `ClipOverlayChrome`.
    let style: ClipOverlayStyle
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
                // Legibility scrims behind whichever edges carry overlays.
                if usesEdge(.bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                if usesEdge(.top) {
                    LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .center)
                        .allowsHitTesting(false)
                }
                // Title + HR tile at the user's style (prompt 163) — the SAME view the ✎ sheet previews.
                // The tile is on every page (so it slides with the carousel, no pop-in) and cheap: a flat
                // scrim (liveBlur: false), not a live backdrop blur.
                ClipOverlayChrome(style: style, title: titleText, payload: payload,
                                  fraction: playing ? liveFraction : ClipHROverlay.atEnd(for: payload),
                                  width: geo.size.width, playing: playing)
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
                if playing, item.media.kind == "video" { muteButton.padding(12).padding(.top, topReserve(geo.size.width)) }
            }
            // Studio-trimmed clip (prompt 116): a subtle chip naming the kept range — the honest signal
            // that the feed plays the edit (and that speed/filters/text live in the export/bake).
            // Gated + labelled by the EFFECTIVE kept range (the same `keptRange` verdict playback and
            // the HR window use) — a degenerate/whole-clip stored trim plays raw and shows NO chip.
            .overlay(alignment: .topTrailing) {
                Group {
                    if item.media.isBaked {
                        bakedChip.padding(12)
                    } else if let kept = item.media.edit?.keptRange(rawDurationSec: item.media.durationSec ?? 0) {
                        editedChip(kept).padding(12)
                    }
                }
                .padding(.top, topReserve(geo.size.width))
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

    // The title at the user's style (prompt 163). Built-in = today's lower-third: name, grade · angle,
    // and the attempt/set as a white chip. Drawn with the tile by `ClipOverlayChrome`, whose HR tile is
    // the ONE `ClipHROverlay` mapping the poster, the inline player and the fullscreen viewer share.
    private var titleText: ClipOverlayStyle.TitleText? { style.titleText(post.titleValues(for: item)) }

    /// Whether anything (title or tile) sits on `edge` — drives the legibility scrims.
    private func usesEdge(_ edge: ClipOverlayStyle.Edge) -> Bool {
        (style.hrEdge == edge && payload != nil) || (style.titleEdge == edge && titleText != nil)
    }

    /// How far this page's top chrome (mute, EDITED/BAKED chip) drops below top-edge overlays.
    private func topReserve(_ width: CGFloat) -> CGFloat {
        ClipOverlayChrome.topReserve(style: style, title: titleText,
                                     tileTemplate: payload?.tile.template, width: width)
    }
}
