import SwiftUI
import UIKit

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
    /// "✦ Make reel" for a month or a selection (the headers live in UIKit cells, so a Button sets this rather
    /// than a NavigationLink, which can't see the stack from there).
    @State private var reelRoute: ClipsReelRoute?
    @State private var fullscreen: ClipGridFullscreen?
    @State private var studio: GridStudio?
    @State private var shareItem: GridShareItem?
    @State private var preparingShare = false
    @State private var shareFailed = false
    /// Select mode (prompt 175): the picked posts' ids; nil = not selecting.
    @State private var selection: Set<String>?
    @State private var shareItems: GridShareItems?

    /// The zoom level — Year (9-across mosaic) · Months (5) · All (3); pinch or the segmented control
    /// (2026-10-10). Remembered as the column count under the prompt-176 key, but held in @State while the grid
    /// is open and saved on close: writing UserDefaults mid-pinch re-ran the FEED's body behind this sheet (its
    /// @AppStorage reacts to any defaults change) — the 120–160 ms hitch on every pinch, measured on device.
    @State private var level = ClipGridLevel(columns: UserDefaults.standard.integer(forKey: ClipsGridView.levelKey))
    static let levelKey = "clips.grid.columns"
    /// Scroll position + fast-scroll handle state, kept OUT of this view's body (2026-10-10 perf): the
    /// scroll fraction changes every frame and only `ClipGridScrubber` reads it.
    @State private var scrub = ClipGridScrubState()
    /// Drives the UIKit grid from here (scrubber jumps, day-strip taps).
    @State private var controller = ClipGridController()
    /// Months + years computed once per posts / HR-payload change, not on every body evaluation.
    @State private var monthsCache: [ClipGridModel.Month] = []
    @State private var yearsCache: [String: ClipGridModel.Year] = [:]
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
                    // Photos-style zoom on a UICollectionView (2026-10-10) — see ClipGridCollectionView.swift.
                    ClipGridCollection(
                        months: monthsCache, years: yearsCache, level: level, selection: selection,
                        controller: controller, scrub: scrub,
                        model: { cellModel($0) },
                        header: { AnyView(monthHeader($0)) },
                        onTap: { post in
                            if selection != nil { toggle(post.id) }   // select mode
                            else { onPick(post.id); dismiss() }
                        },
                        menu: { menuElements($0) },
                        preview: { AnyView(preview($0)) },
                        onLevelChange: { level = $0 })
                    // The handle reads the scrub state itself; it jumps the grid directly (instant).
                    .overlay(alignment: .trailing) {
                        ClipGridScrubber(state: scrub, months: monthsCache, jump: { controller.jump(toMonth: $0) })
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            levelPicker
                            chipStrip
                        }
                        .background(SnappetColor.paper)
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
            .onChange(of: posts, initial: true) { _, _ in rebuildMonths() }
            .onDisappear { UserDefaults.standard.set(level.columns, forKey: Self.levelKey) }
            .onChange(of: payloads.count) { _, _ in rebuildMonths() }
            // "✦ Make reel" for a month (prompt 173) or a selection — the shared reel builder.
            .navigationDestination(item: $reelRoute) { route in WeeklyReelHostView(scope: route.scope) }
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
            Button { reelRoute = ClipsReelRoute(scope: .clips(ClipGridModel.mediaIDs(of: picked, in: posts))) } label: {
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

    private func menuElements(_ post: ClipFeedPost) -> [UIMenuElement] {
        func action(_ title: String, _ icon: String, id: String? = nil, destructive: Bool = false,
                    _ run: @escaping () -> Void) -> UIAction {
            let a = UIAction(title: title, image: UIImage(systemName: icon),
                             attributes: destructive ? .destructive : []) { _ in run() }
            if let id { a.accessibilityIdentifier = id }
            return a
        }
        var out: [UIMenuElement] = [action("Open in feed", "arrow.up.forward", id: "clips.grid.menu.open") {
            onPick(post.id); dismiss()
        }]
        guard let actions else { return out }
        if let f = actions.fullscreen(post) {
            out.append(action("Play fullscreen", "play.fill", id: "clips.grid.menu.fullscreen") { fullscreen = f })
        }
        let fav = actions.isFavorite(post)
        out.append(action(fav ? "Unfavorite" : "Favorite", fav ? "heart.slash" : "heart",
                          id: fav ? "clips.grid.menu.unfavorite" : "clips.grid.menu.favorite") { actions.toggleFavorite(post) })
        if actions.sharePlan(post) != nil {
            out.append(action("Share with heart rate", "heart.text.square") { share(post) })
        }
        if actions.canEdit(post) {
            out.append(action("Edit in Studio", "slider.horizontal.3") {
                if let s = actions.studio(post) { studio = GridStudio(project: s.project, focus: s.focus, visible: s.visible) }
            })
        }
        out.append(action("Go to session", "arrow.up.forward.square", id: "clips.grid.menu.session") {
            dismiss(); actions.goToSession(post)
        })
        out.append(action("Hide from Clips", "eye.slash", id: "clips.grid.menu.hide", destructive: true) { actions.hide(post) })
        return out
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
        yearsCache = ClipGridModel.years(months)
    }

    /// A post's peak HR — the highest peak across its clips' overlay windows.
    private func peakHR(of post: ClipFeedPost) -> Double? {
        post.clips.compactMap { payloads[$0.media.id]?.values.rawPeakBpm }.max()
    }

    /// Year · Months · All — the same levels a pinch moves through.
    private var levelPicker: some View {
        Picker("Zoom", selection: $level) {
            ForEach([ClipGridLevel.year, .months, .all]) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
        .accessibilityIdentifier("clips.grid.level")
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
                Button { reelRoute = ClipsReelRoute(scope: .month(month.interval, title: month.title)) } label: {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        if let p = month.firstPost(onDay: day, calendar: calendar) { controller.scroll(toPost: p.id) }
                    }
                    .accessibilityHidden(level == 0)
                    .accessibilityLabel("Day \(day)")
            }
        }
        .accessibilityIdentifier("clips.grid.dayStrip")
    }

    // MARK: Cover

    /// Everything a cover draws, as plain values — an unchanged cover isn't touched when the grid refreshes.
    private func cellModel(_ post: ClipFeedPost) -> ClipGridCellModel {
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
            isMulti: post.clipCount > 1)
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

// MARK: - Cover model + fast-scroll handle (2026-10-10 perf rework)

/// What one cover draws — plain values, so the UIKit cover can skip re-applying an unchanged one.
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
    /// Put a month (by id) at the top of the grid (instant).
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
                                    jump(m.id)
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
