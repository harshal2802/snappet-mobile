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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
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
                    ScrollViewReader { proxy in
                        ScrollView {
                            chipStrip
                            // Grouped by month with pinned headers (prompt 167) — the "jump to a month" view.
                            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                                ForEach(months) { month in
                                    Section {
                                        ForEach(month.posts) { post in
                                            cell(post)
                                                .id(post.id)
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
                        .accessibilityIdentifier("clips.grid")
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            withAnimation { proxy.scrollTo(target, anchor: .top) }
                            scrollTarget = nil
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

    private var months: [ClipGridModel.Month] {
        ClipGridModel.months(posts, peak: peakHR(of:), calendar: calendar)
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

    /// One square cover: the first clip's thumbnail, name, and what it is — length, outcome, reel, peak ♥,
    /// favourite, multi-clip.
    private func cell(_ post: ClipFeedPost) -> some View {
        let first = post.clips.first
        return Color.clear
            .aspectRatio(1, contentMode: .fit)   // square cell sized to the column width
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .bottomLeading) {
                        if let first {
                            ClipThumbnail(localIdentifier: first.media.localIdentifier, kind: first.media.kind,
                                          size: geo.size)
                        } else {
                            Color.black
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                            .allowsHitTesting(false)
                        HStack(alignment: .bottom, spacing: 4) {
                            Text(post.title).font(.caption2.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                            Spacer(minLength: 0)
                            if let f = first, f.media.kind == "video",
                               let d = ClipGridModel.durationLabel(ClipHROverlay.playedRange(f.media).span) {
                                Text(d).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(5)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .overlay(alignment: .topLeading) { badges(post).padding(4) }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 3) {
                    if reactions?.isFavorite(post) == true {
                        Image(systemName: "heart.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                    if post.clipCount > 1 {
                        Image(systemName: "rectangle.stack.fill").font(.caption2).foregroundStyle(.white)
                    }
                }
                .shadow(radius: 2).padding(5)
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityIdentifier("clips.grid.cell")
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
