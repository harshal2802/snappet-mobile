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

struct ClipsGridView: View {
    let posts: [ClipFeedPost]
    /// Per-clip HR payloads (media id → payload) — a cover's peak ♥ and the month's peak.
    var payloads: [UUID: ClipHROverlay.Payload] = [:]
    var reactions: ClipReactionStore? = nil
    /// The feed's filter — shared, so a chip tapped here filters the feed too.
    var filter: Binding<ClipFeedFilter>? = nil
    var chips: ClipGridChips? = nil
    /// The picked post id → the feed scrolls to it.
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scrollTarget: String?

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
                                                .onTapGesture { onPick(post.id); dismiss() }
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
            .navigationTitle("All clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // "✦ Make reel" for a month (prompt 173) — the shared reel builder over that month's sessions.
            .navigationDestination(for: ClipsReelRoute.self) { route in WeeklyReelHostView(scope: route.scope) }
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
