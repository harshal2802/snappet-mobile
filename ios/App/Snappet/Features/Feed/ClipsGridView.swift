import SwiftUI

// MARK: - Clips feed — explore grid (prompt 86 · months 167 · a grid you can act on 173)
//
// An IG-profile-style grid of all Clips POSTS (covers), grouped by month with pinned headers. Prompt 173
// (wireframes docs/ux-research/clips-grid/) makes it more than a jump list:
// - covers say what they are: video length, SENT/FLASH, ✦ REEL, peak ♥, favourite;
// - each month header summarises it (sessions · sends · peak HR), shows a day strip of the days you trained
//   (tap a day → jump to it) and offers "✦ Make reel" for the month (the shared reel builder);
// - the feed's filter chips sit at the top — the grid shows exactly what the feed shows.
// Tapping a cover still dismisses the grid and scrolls the feed to that post. Derive-on-read, no new storage.

/// The chip strip's inputs, computed by the feed (prompt 173 — the grid shows the same chips).
struct ClipGridChips {
    var hiddenCount: Int
    var activities: [ClipFeedPost.Discipline]
    var festivals: [ClipFestivalChips.Festival]
    var artistRow: (artists: [String], untagged: Int)?
}

/// What a long-pressed cover can do (prompt 174) — supplied by the feed, which owns the data each action needs.
struct ClipGridActions {
    var isFavorite: (ClipFeedPost) -> Bool
    var toggleFavorite: (ClipFeedPost) -> Void
    var hide: (ClipFeedPost) -> Void
    var goToSession: (ClipFeedPost) -> Void
    /// The fullscreen viewer's inputs — nil when the post has nothing to play.
    var fullscreen: (ClipFeedPost) -> ClipGridFullscreen?
    /// "Share with heart rate" for the post's first video — nil when there's no HR to burn.
    var sharePlan: (ClipFeedPost) -> ClipSharePlan.Plan?
    /// Whether "Edit in Studio" applies (a non-reel video), and the project + clips to open it with.
    var canEdit: (ClipFeedPost) -> Bool
    var studio: (ClipFeedPost) -> (project: StudioProject, focus: UUID?, visible: Set<UUID>)?
}

struct ClipGridFullscreen: Identifiable {
    let id = UUID()
    var clips: [MediaInput]
    var series: [HRPoint]
    var maxHR: Double
    var restHR: Double?
    var title: String
    var tile: HRTile?
}

private struct GridStudio: Identifiable {
    let id = UUID()
    let project: StudioProject
    let focus: UUID?
    let visible: Set<UUID>
}

private struct GridShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct GridShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ClipsGridView: View {
    let posts: [ClipFeedPost]
    /// Per-clip HR payloads (media id → payload) — a cover's peak ♥ and the month's peak.
    var payloads: [UUID: ClipHROverlay.Payload] = [:]
    var reactions: ClipReactionStore? = nil
    /// The feed's filter — shared, so a chip tapped here filters the feed too.
    var filter: Binding<ClipFeedFilter>? = nil
    var chips: ClipGridChips? = nil
    /// Long-press actions (prompt 174); nil → covers only jump to the feed.
    var actions: ClipGridActions? = nil
    /// The picked post id → the feed scrolls to it.
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var scrollTarget: String?
    @State private var fullscreen: ClipGridFullscreen?
    @State private var studio: GridStudio?
    @State private var shareItem: GridShareItem?
    @State private var preparingShare = false
    @State private var shareFailed = false
    /// Select mode (prompt 175): the picked posts' ids; nil = not selecting.
    @State private var selection: Set<String>?
    @State private var shareItems: GridShareItems?

    /// 3 or 5 columns — pinch to switch (prompt 176), remembered per device.
    @AppStorage("clips.grid.columns") private var columnCount = 3
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount) }
    /// Scroll position + fast-scroll handle state, kept OUT of this view's body (2026-10-10 perf): the
    /// scroll fraction changes every frame, and as @State here it re-ran the WHOLE grid body per frame — the
    /// prompt-97 lesson again. Only `ClipGridScrubber` reads it.
    @State private var scrub = ClipGridScrubState()
    /// One column switch per pinch — it switches as the pinch crosses the threshold, not on release.
    @State private var pinchSwitched = false
    /// Months computed once per posts / HR-payload change, not on every body evaluation.
    @State private var monthsCache: [ClipGridModel.Month] = []
    /// Each post's position in the grid, for warming the thumbnails just below the fold.
    @State private var flatOrder: [ClipFeedPost] = []
    @State private var orderIndex: [String: Int] = [:]
    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            Group {
                if posts.isEmpty {
                    VStack(spacing: 0) {
                        chipStrip
                        ContentUnavailableView {
                            Label("No clips yet", systemImage: "square.grid.3x3")
                        } description: {
                            Text(filter?.wrappedValue.isActive == true
                                 ? "Nothing matches these filters." : "Film a workout or a climb and your clips show up here.")
                        }
                        .accessibilityIdentifier("clips.grid.empty")
                    }
                } else {
                    GeometryReader { viewport in
                    let side = cellSide(width: viewport.size.width)
                    ScrollViewReader { proxy in
                        ScrollView {
                          VStack(spacing: 0) {
                            chipStrip
                            // Grouped by month with pinned headers (prompt 167) — the "jump to a month" view.
                            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                                ForEach(monthsCache) { month in
                                    Section {
                                        ForEach(month.posts) { post in
                                            // Equatable cover from precomputed values: unchanged covers skip their
                                            // body when the grid re-renders (2026-10-10 perf).
                                            ClipGridCell(model: cellModel(post, side: side))
                                                .equatable()
                                                .id(post.id)
                                                .onAppear { warmThumbnails(after: post.id, side: side) }
                                                .onTapGesture {
                                                    if selection != nil { toggle(post.id) }   // select mode
                                                    else { onPick(post.id); dismiss() }
                                                }
                                                .overlay(alignment: .bottomTrailing) {
                                                    if let selection { selectMark(selection.contains(post.id)) }
                                                }
                                                .contextMenu { if selection == nil { menu(post) } } preview: { preview(post) }
                                        }
                                    } header: {
                                        monthHeader(month)
                                    }
                                }
                            }
                            .padding(.horizontal, 2)
                          }
                          // Pinch to switch 3 ⇄ 5 columns (prompt 176). The content is at least a screen tall with a
                          // hit shape, so a pinch anywhere — even below a short month — reaches the gesture.
                          .frame(minHeight: viewport.size.height, alignment: .top)
                          .contentShape(Rectangle())
                          // Switch as soon as the pinch crosses the threshold (not on release), without animating the
                          // whole grid's re-layout — that animation was the lag (2026-10-10 device feedback).
                          .simultaneousGesture(MagnifyGesture()
                              .onChanged { value in
                                  guard !pinchSwitched else { return }
                                  let next = ClipGridModel.columns(afterPinch: value.magnification, current: columnCount)
                                  if next != columnCount { pinchSwitched = true; setColumns(next) }
                              }
                              .onEnded { _ in pinchSwitched = false })
                        }
                        .accessibilityIdentifier("clips.grid")
                        .onScrollGeometryChange(for: Double.self) { g in
                            let range = g.contentSize.height - g.containerSize.height
                            return range > 0 ? min(1, max(0, g.contentOffset.y / range)) : 0
                        } action: { _, f in scrub.scrollFraction = f }
                        .onScrollPhaseChange { _, phase in
                            if phase != .idle { scrub.show() } else { scrub.scheduleHide() }
                        }
                        // The handle reads the scrub state itself; it jumps the grid directly (instant — an
                        // animation per month would lag the finger), never through this body's state.
                        .overlay(alignment: .trailing) {
                            ClipGridScrubber(state: scrub, months: monthsCache,
                                             jump: { proxy.scrollTo($0, anchor: .top) })
                        }
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            withAnimation { proxy.scrollTo(target, anchor: .top) }
                            scrollTarget = nil
                        }
                    }
                    }
                }
            }
            .background(SnappetColor.paper)
            .navigationTitle(selection.map { "\($0.count) selected" } ?? "All clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Select mode (prompt 175): Select ⇄ Cancel on the left; Done ⇄ All on the right.
                ToolbarItem(placement: .topBarLeading) {
                    if actions != nil, !posts.isEmpty {
                        Button(selection == nil ? "Select" : "Cancel") {
                            selection = selection == nil ? [] : nil
                        }
                        .accessibilityIdentifier("clips.grid.select")
                    }
                }
                // Column count (prompt 176): a visible 3 ⇄ 5 toggle — pinch does the same, but a button is
                // discoverable, accessible, and works where a pinch inside the scroll view isn't recognised.
                ToolbarItem(placement: .topBarTrailing) {
                    if selection == nil, !posts.isEmpty {
                        Button {
                            setColumns(columnCount == 3 ? 5 : 3)
                        } label: {
                            Image(systemName: columnCount == 3 ? "square.grid.3x3" : "square.grid.4x3.fill")
                        }
                        .accessibilityIdentifier("clips.grid.columns")
                        .accessibilityLabel(columnCount == 3 ? "Show more per row" : "Show bigger covers")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selection != nil {
                        Button("All") { selection = Set(posts.map(\.id)) }
                            .accessibilityIdentifier("clips.grid.selectAll")
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { if let selection { selectBar(selection) } }
            .onChange(of: posts, initial: true) { _, _ in rebuildMonths() }
            .onChange(of: payloads.count) { _, _ in rebuildMonths() }
            // "✦ Make reel" for a month (prompt 173) — the shared reel builder over that month's sessions.
            .navigationDestination(for: ClipsReelRoute.self) { route in WeeklyReelHostView(scope: route.scope) }
        }
        // Long-press destinations (prompt 174).
        .fullScreenCover(item: $fullscreen) { f in
            MediaBrowserView.clipsViewer(clips: f.clips, startIndex: 0, hrSeries: f.series, maxHR: f.maxHR,
                                         restHR: f.restHR, nameFor: { _ in f.title }, tile: f.tile)
        }
        .fullScreenCover(item: $studio) { s in
            StudioEditorView(project: s.project, context: context, focusClipMediaID: s.focus,
                             visibleClipMediaIDs: s.visible)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url], onComplete: { _, _ in try? FileManager.default.removeItem(at: item.url) })
        }
        .sheet(item: $shareItems) { items in
            ShareSheet(items: items.urls, onComplete: { _, _ in
                for u in items.urls { try? FileManager.default.removeItem(at: u) }
            })
        }
        .overlay {
            if preparingShare {
                ProgressView("Preparing…").padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .alert("Couldn’t prepare this clip", isPresented: $shareFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("The clip couldn’t be exported to share. Try again from the post’s ⋯ menu.") }
    }

    // MARK: Select mode (prompt 175)

    private func toggle(_ id: String) {
        guard var s = selection else { return }
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        selection = s
    }

    private func selectMark(_ on: Bool) -> some View {
        ZStack {
            Circle().fill(on ? SnappetColor.brand : .black.opacity(0.3))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
        }
        .frame(width: 20, height: 20)
        .padding(5)
        .allowsHitTesting(false)
        .accessibilityIdentifier(on ? "clips.grid.selected" : "clips.grid.unselected")
    }

    /// Favorite · ✦ Make reel · Share · Hide for the picked posts.
    private func selectBar(_ picked: Set<String>) -> some View {
        let none = picked.isEmpty
        let allFav = reactions.map { r in ClipGridModel.allFavorite(picked, in: posts, isFavorite: r.isFavorite) } ?? false
        return HStack {
            barButton(allFav ? "Unfavorite" : "Favorite", allFav ? "heart.slash" : "heart", id: "clips.grid.bulk.favorite") {
                guard let actions else { return }
                for p in posts where picked.contains(p.id) && actions.isFavorite(p) == allFav { actions.toggleFavorite(p) }
            }
            NavigationLink(value: ClipsReelRoute(scope: .clips(ClipGridModel.mediaIDs(of: picked, in: posts)))) {
                barLabel("Make reel", "sparkles", hot: true)
            }
            .accessibilityIdentifier("clips.grid.bulk.reel")
            barButton("Share", "square.and.arrow.up", id: "clips.grid.bulk.share") { shareMany(picked) }
            barButton("Hide", "eye.slash", id: "clips.grid.bulk.hide") {
                guard let actions else { return }
                for p in posts where picked.contains(p.id) { actions.hide(p) }
                selection = []
            }
        }
        .disabled(none)
        .opacity(none ? 0.45 : 1)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        .background(.bar)
    }

    private func barButton(_ title: String, _ icon: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(title, icon, hot: false) }
            .accessibilityIdentifier(id)
    }

    private func barLabel(_ title: String, _ icon: String, hot: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
            Text(title).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(hot ? SnappetColor.reels : SnappetColor.ink)
        .frame(maxWidth: .infinity)
    }

    /// Share the picked posts' videos (one per post, raw) in one share sheet.
    private func shareMany(_ picked: Set<String>) {
        let ids = ClipGridModel.shareables(of: picked, in: posts)
        guard !preparingShare else { return }
        guard !ids.isEmpty else { shareFailed = true; return }
        preparingShare = true
        Task { @MainActor in
            var urls: [URL] = []
            for id in ids { if let u = await ClipShareService.exportForSharing(localIdentifier: id) { urls.append(u) } }
            preparingShare = false
            if urls.isEmpty { shareFailed = true } else { shareItems = GridShareItems(urls: urls) }
        }
    }

    // MARK: Long-press (prompt 174)

    @ViewBuilder private func menu(_ post: ClipFeedPost) -> some View {
        Button { onPick(post.id); dismiss() } label: { Label("Open in feed", systemImage: "arrow.up.forward") }
            .accessibilityIdentifier("clips.grid.menu.open")
        if let actions {
            if actions.fullscreen(post) != nil {
                Button { fullscreen = actions.fullscreen(post) } label: { Label("Play fullscreen", systemImage: "play.fill") }
                    .accessibilityIdentifier("clips.grid.menu.fullscreen")
            }
            let fav = actions.isFavorite(post)
            Button { actions.toggleFavorite(post) } label: {
                Label(fav ? "Unfavorite" : "Favorite", systemImage: fav ? "heart.slash" : "heart")
            }
            .accessibilityIdentifier(fav ? "clips.grid.menu.unfavorite" : "clips.grid.menu.favorite")
            if actions.sharePlan(post) != nil {
                Button { share(post) } label: { Label("Share with heart rate", systemImage: "heart.text.square") }
            }
            if actions.canEdit(post) {
                Button {
                    if let s = actions.studio(post) { studio = GridStudio(project: s.project, focus: s.focus, visible: s.visible) }
                } label: { Label("Edit in Studio", systemImage: "slider.horizontal.3") }
            }
            Button { dismiss(); actions.goToSession(post) } label: {
                Label("Go to session", systemImage: "arrow.up.forward.square")
            }
            .accessibilityIdentifier("clips.grid.menu.session")
            Button(role: .destructive) { actions.hide(post) } label: {
                Label("Hide from Clips", systemImage: "eye.slash")
            }
            .accessibilityIdentifier("clips.grid.menu.hide")
        }
    }

    /// The long-press preview: the cover, big, with what it is.
    private func preview(_ post: ClipFeedPost) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let first = post.clips.first {
                ClipThumbnail(localIdentifier: first.media.localIdentifier, kind: first.media.kind,
                              size: CGSize(width: 320, height: 320))
            } else {
                Color.black
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.title).font(.headline.weight(.heavy)).foregroundStyle(.white)
                Text(post.overlayDetail.isEmpty ? post.subtitle : post.overlayDetail)
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(12)
        }
        .overlay(alignment: .topLeading) { badges(post).padding(8) }
        .frame(width: 320, height: 320)
    }

    private func share(_ post: ClipFeedPost) {
        guard let actions, let plan = actions.sharePlan(post), !preparingShare else { return }
        preparingShare = true
        Task { @MainActor in
            let url = await ClipShareService.exportWithHeartRate(plan)
            preparingShare = false
            if let url { shareItem = GridShareItem(url: url) } else { shareFailed = true }
        }
    }

    /// Recompute the month sections — only when the posts or their HR payloads change.
    private func rebuildMonths() {
        let months = ClipGridModel.months(posts, peak: peakHR(of:), calendar: calendar)
        monthsCache = months
        flatOrder = months.flatMap(\.posts)
        orderIndex = Dictionary(flatOrder.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The square cover side for the current column count (2pt gutters, 2pt edge padding).
    private func cellSide(width: CGFloat) -> CGFloat {
        let n = CGFloat(columnCount)
        return max(40, ((width - 4) - (n - 1) * 2) / n)
    }

    /// Warm Photos' thumbnail cache for the next couple of rows as covers appear (cheap, deduped).
    private func warmThumbnails(after id: String, side: CGFloat) {
        guard let i = orderIndex[id] else { return }
        let upcoming = flatOrder.dropFirst(i + 1).prefix(columnCount * 3)
        AssetPosterLoader.warmThumbnails(upcoming.compactMap { $0.clips.first?.media.localIdentifier },
                                         pointSize: CGSize(width: side, height: side))
    }

    /// A post's peak HR — the highest peak across its clips' overlay windows.
    private func peakHR(of post: ClipFeedPost) -> Double? {
        post.clips.compactMap { payloads[$0.media.id]?.values.rawPeakBpm }.max()
    }

    @ViewBuilder private var chipStrip: some View {
        if let filter, let chips {
            ClipFilterChipStrip(filter: filter, hiddenCount: chips.hiddenCount, activities: chips.activities,
                                festivals: chips.festivals, artistRow: chips.artistRow)
                .padding(.vertical, 8)
        }
    }

    // MARK: Month scrubber (prompt 176 · reworked 2026-10-10)

    /// Switch columns instantly with a light tap (no re-layout animation — it lagged on a big grid).
    private func setColumns(_ n: Int) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { columnCount = n }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Month header

    private func monthHeader(_ month: ClipGridModel.Month) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(month.title).font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.ink)
                        .accessibilityIdentifier("clips.grid.month")
                    Text(month.summary).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer()
                NavigationLink(value: ClipsReelRoute(scope: .month(month.interval, title: month.title))) {
                    Label("Make reel", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SnappetColor.reels)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(SnappetColor.reels.opacity(0.14), in: Capsule())
                }
                .accessibilityIdentifier("clips.grid.monthReel")
            }
            dayStrip(month)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(SnappetColor.paper.opacity(0.97))
    }

    /// One square per day of the month, shaded by how many posts that day; tap a day to jump to it.
    private func dayStrip(_ month: ClipGridModel.Month) -> some View {
        HStack(spacing: 2) {
            ForEach(1...month.daysInMonth, id: \.self) { day in
                let level = ClipGridModel.dayLevel(month.postsByDay[day] ?? 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(level == 0 ? SnappetColor.surfaceMuted
                          : SnappetColor.reels.opacity([0, 0.4, 0.7, 1.0][level]))
                    .frame(height: 8)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        if let p = month.firstPost(onDay: day, calendar: calendar) { scrollTarget = p.id }
                    }
                    .accessibilityHidden(level == 0)
                    .accessibilityLabel("Day \(day)")
            }
        }
        .accessibilityIdentifier("clips.grid.dayStrip")
    }

    // MARK: Cover

    /// Everything a cover draws, precomputed so `ClipGridCell` can skip unchanged covers.
    private func cellModel(_ post: ClipFeedPost, side: CGFloat) -> ClipGridCellModel {
        let first = post.clips.first
        let send = post.climbResult.flatMap { $0.status.isSend ? $0.status : nil }
        return ClipGridCellModel(
            id: post.id,
            localIdentifier: first?.media.localIdentifier, kind: first?.media.kind ?? "photo",
            title: post.title,
            duration: first.flatMap { f in
                f.media.kind == "video" ? ClipGridModel.durationLabel(ClipHROverlay.playedRange(f.media).span) : nil },
            isReel: post.isReel,
            sendLabel: send?.label.uppercased(), sendColor: send.map { KilterAscentStyle.color($0) },
            peak: peakHR(of: post).map { Int($0.rounded()) },
            isFavorite: reactions?.isFavorite(post) == true,
            isMulti: post.clipCount > 1,
            side: side)
    }

    @ViewBuilder private func badges(_ post: ClipFeedPost) -> some View {
        HStack(spacing: 3) {
            if post.isReel { badge("✦ REEL", fg: Color(red: 0.16, green: 0.04, blue: 0.02), bg: SnappetColor.reels) }
            if let r = post.climbResult, r.status.isSend {
                badge(r.status.label.uppercased(), fg: .white, bg: KilterAscentStyle.color(r.status))
            }
            if let peak = peakHR(of: post) {
                badge("♥\(Int(peak.rounded()))", fg: Color(red: 1, green: 0.55, blue: 0.48), bg: .black.opacity(0.55))
            }
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .heavy)).foregroundStyle(fg)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(bg, in: Capsule())
    }
}

// MARK: - Grid cover + fast-scroll handle (2026-10-10 perf rework)

/// What one cover draws — plain values, so an unchanged cover compares equal and skips its body.
struct ClipGridCellModel: Equatable {
    var id: String
    var localIdentifier: String?
    var kind: String
    var title: String
    var duration: String?
    var isReel: Bool
    var sendLabel: String?
    var sendColor: Color?
    var peak: Int?
    var isFavorite: Bool
    var isMulti: Bool
    var side: CGFloat
}

/// One square cover. No GeometryReader (the side is computed once for the grid) and a CHEAP Photos thumbnail
/// (`exactFrame: false`) — the exact frame-0 decode (70–120 ms a video) matters for the feed's poster→video
/// handoff, not for a grid square.
struct ClipGridCell: View, Equatable {
    let model: ClipGridCellModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let id = model.localIdentifier {
                ClipThumbnail(localIdentifier: id, kind: model.kind,
                              size: CGSize(width: model.side, height: model.side), exactFrame: false)
            } else {
                Color.black
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 4) {
                Text(model.title).font(.caption2.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                    .accessibilityIdentifier("clips.grid.cell.title")
                Spacer(minLength: 0)
                if let d = model.duration {
                    Text(d).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(5)
        }
        .frame(width: model.side, height: model.side)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 3) {
                if model.isReel { badge("✦ REEL", fg: Color(red: 0.16, green: 0.04, blue: 0.02), bg: SnappetColor.reels) }
                if let l = model.sendLabel, let c = model.sendColor { badge(l, fg: .white, bg: c) }
                if let p = model.peak { badge("♥\(p)", fg: Color(red: 1, green: 0.55, blue: 0.48), bg: .black.opacity(0.55)) }
            }
            .padding(4)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                if model.isFavorite {
                    Image(systemName: "heart.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
                if model.isMulti {
                    Image(systemName: "rectangle.stack.fill").font(.caption2).foregroundStyle(.white)
                }
            }
            .shadow(radius: 2).padding(5)
        }
        .clipped()
        .contentShape(Rectangle())
        // `.contain` keeps the title's own identifier reachable under the cover's (the habit.row precedent).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clips.grid.cell")
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .heavy)).foregroundStyle(fg)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(bg, in: Capsule())
    }
}

/// The fast-scroll handle's state — observed only by `ClipGridScrubber`, so the per-frame scroll position
/// never re-renders the grid.
@MainActor @Observable
final class ClipGridScrubState {
    var scrollFraction: Double = 0
    var handleVisible = false
    var dragFraction: Double?
    var scrubbing: String?
    private var hideToken = 0

    func show() {
        hideToken += 1
        if !handleVisible { withAnimation(.easeOut(duration: 0.15)) { handleVisible = true } }
    }

    func scheduleHide() {
        hideToken += 1
        let token = hideToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, token == self.hideToken, self.dragFraction == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.handleVisible = false }
        }
    }
}

/// A Photos-style fast-scroll handle: a small pill on the trailing edge that appears while you scroll, rides your
/// position in the grid, and drags through months with a bubble naming the month. Shown once there are 3+ months.
struct ClipGridScrubber: View {
    let state: ClipGridScrubState
    let months: [ClipGridModel.Month]
    /// Scroll the grid to a post id (instant).
    let jump: (String) -> Void

    var body: some View {
        if months.count >= 3 {
            GeometryReader { geo in
                let handleH: CGFloat = 44
                let travel = max(1, geo.size.height - handleH)
                let y = (state.dragFraction ?? state.scrollFraction) * travel
                ZStack(alignment: .topTrailing) {
                    Color.clear.allowsHitTesting(false)
                    if let scrubbing = state.scrubbing {
                        Text(scrubbing).font(.subheadline.weight(.heavy))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .offset(x: -44, y: y + handleH / 2 - 18)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("clips.grid.scrubBubble")
                    }
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SnappetColor.ink))
                        .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                        .frame(width: 28, height: handleH)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                        .contentShape(Rectangle().inset(by: -10))
                        .offset(x: -4, y: y)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("clipsGridTrack"))
                            .onChanged { g in
                                state.show()
                                let f = min(1, max(0, (g.location.y - handleH / 2) / travel))
                                state.dragFraction = f
                                guard let i = ClipGridModel.monthIndex(atFraction: f, count: months.count) else { return }
                                let m = months[i]
                                if state.scrubbing != m.title {
                                    state.scrubbing = m.title
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    if let first = m.posts.first { jump(first.id) }
                                }
                            }
                            .onEnded { _ in
                                state.dragFraction = nil
                                withAnimation(.easeOut(duration: 0.2)) { state.scrubbing = nil }
                                state.scheduleHide()
                            })
                        .accessibilityLabel("Fast scroll by month")
                        .accessibilityIdentifier("clips.grid.scrubber")
                }
                .coordinateSpace(name: "clipsGridTrack")
            }
            .frame(width: 220)
            .padding(.vertical, 16)
            .opacity(state.handleVisible || state.dragFraction != nil ? 1 : 0)
            .allowsHitTesting(state.handleVisible || state.dragFraction != nil)
        }
    }
}
