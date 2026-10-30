import SwiftUI

// The Clips feed's chrome above and between the posts — split out of ClipsFeedView.swift (prompt 168,
// mechanical move, no behaviour change): the Health offer card, the Weekly Highlight Reel hero, the pinned
// session header and the filter chip strip.

// MARK: - "Connect Apple Health" offer card (highlights P5)

/// The contextual watch-import primer: a dismissible card, NOT an onboarding step — the Health
/// sheet fires only from its Connect tap. Renders on the empty state and atop the feed while
/// `ClipsHealthOffer.shouldShow` holds; either button resolves it forever.
struct ClipsHealthOfferCard: View {
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // Prompt 216: one quiet row (was a big green card) — same Connect / dismiss.
        HStack(spacing: 10) {
            Image(systemName: "applewatch")
                .font(.system(size: 15))
                .foregroundStyle(SnappetColor.ink)
                .frame(width: 32, height: 32)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Show Apple Watch workouts").font(.system(size: 14, weight: .medium)).foregroundStyle(SnappetColor.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("Heart rate included").snappetLabel()
            }
            Spacer(minLength: 4)
            Button(action: onConnect) {
                Text("Connect").font(.system(size: 13, weight: .medium)).snappetPill(selected: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clips.healthOffer.connect")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SnappetColor.textTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clips.healthOffer.dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
        .padding(.horizontal, SnappetSpacing.lg)
        // `.contain` keeps the Connect/dismiss buttons' OWN identifiers reachable under the
        // card's (identifier-on-container otherwise flattens them out of the UITest tree —
        // the habit.row precedent).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clips.healthOffer")
    }
}

// MARK: - Weekly Highlight Reel hero (highlights P4 · P5 polish)

/// The Sunday-drop card at the top of Clips: a calm panel (prompt 216; was a coral hero) — the label + count,
/// the title with an accent ▶, and a static filmstrip. A `NavigationLink` into the shared reel builder
/// (`WeeklyReelHostView`); everything on it is a plain shape (no players, thumbnails or blur), so the feed's
/// scroll perf is untouched (the prompt 92/97 discipline).
struct WeeklyReelHeroCard: View {
    let offer: WeeklyHighlights.Offer

    var body: some View {
        NavigationLink(value: WeeklyReelRoute()) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Weekly highlights").snappetLabel()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your week in highlights").snappetTitle()
                        Text(offer.subtitle).snappetDetail()
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SnappetColor.onBrand)
                        .frame(width: 34, height: 34)
                        .background(SnappetColor.reels, in: Circle())
                }
                HStack(spacing: 4) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(SnappetColor.surfaceMuted)
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                    }
                }
                .allowsHitTesting(false)
            }
            .snappetPanel()
            .padding(.horizontal, SnappetSpacing.lg)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("clips.weeklyReel")
        .accessibilityLabel("Weekly Highlight Reel — \(offer.subtitle)")
    }
}

// MARK: - Session header (prompt 167)

/// The pinned header above a session's posts: kind glyph · session name · "Tue 30 Sep · Kilter · 40°" ·
/// post count. Opaque so posts scroll under it cleanly.
struct ClipSessionHeader: View {
    let section: ClipFeedSection

    /// The session's ACTIVITY drives the glyph (prompt 170) — an imported climbing workout reads as a
    /// climb, not a dumbbell.
    private var activity: ClipFeedPost.Discipline { section.discipline ?? .general }
    private var glyph: String { activity.symbol }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 12))
                .foregroundStyle(SnappetColor.textSecondary)
                .frame(width: 28, height: 28)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title).font(.system(size: 14, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                if let detail = section.detail {
                    Text(detail).snappetLabel().lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(section.countLabel).snappetLabel()
        }
        .padding(.horizontal, SnappetSpacing.lg).padding(.vertical, 8)
        .background(SnappetColor.paper.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(SnappetColor.hairline).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clips.session.header")
    }
}

// MARK: - Filter chip strip (prompt 107)

/// The Clips filter chips: ♥ Favorites · Reels · the activities you have (Climbing + Sends, Strength,
/// Cardio, Dance, Mobility, Festival, Other — prompt 170) · Videos · Photos · Hidden. Visible above the feed (the
/// #264 lesson — filters people can SEE get used), scrolls away with content, and hides entirely while
/// the search field is up (one control in charge at a time; matches the wireframe). Discipline and
/// media-kind pairs are mutually exclusive by construction (one enum value each); Favorites stacks
/// with anything. Tapping an active chip turns it off.
struct ClipFilterChipStrip: View {
    @Binding var filter: ClipFeedFilter
    /// Clips hidden from Clips (prompt 164) — the Hidden chip appears only when there are some.
    let hiddenCount: Int
    /// The activities present in the feed, in chip order (prompt 170) — plus the selected one, so a chip
    /// that filtered everything away can still be turned off.
    let activities: [ClipFeedPost.Discipline]
    /// One chip per festival you have clips from (prompt 171) — replaces the generic Festival chip.
    let festivals: [ClipFestivalChips.Festival]
    /// The selected festival's artists (matched clips) + its unmatched count — the second row.
    let artistRow: (artists: [String], untagged: Int)?
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if !isSearching {
            VStack(alignment: .leading, spacing: 8) {
                mainRow
                if filter.festivalPack != nil, let row = artistRow { artistChips(row) }
            }
        }
    }

    private var mainRow: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Favorites", icon: "heart.fill", on: filter.favoritesOnly, id: "clips.filter.favorites") {
                        filter.favoritesOnly.toggle()
                    }
                    chip("Reels", icon: "sparkles.tv", on: filter.reelsOnly, id: "clips.filter.reels") {
                        filter.reelsOnly.toggle()
                    }
                    // Activity chips (prompt 170) — only activities you HAVE posts for, in a fixed order;
                    // one at a time. Sends rides right after Climbing (it's a climbing outcome).
                    ForEach(activities, id: \.self) { a in
                        chip(a.label, icon: a.symbol, on: filter.activity == a, id: "clips.filter.\(a.rawValue)") {
                            filter.activity = filter.activity == a ? nil : a
                            filter.festivalPack = nil; filter.festivalArtist = nil   // one "what" at a time
                        }
                        if a == .climbing {
                            // Sends (prompt 161): flashes + sends, Kilter or Quick Session. Stacks like Favorites.
                            chip("Sends", icon: "checkmark.seal.fill", on: filter.sendsOnly, id: "clips.filter.sends") {
                                filter.sendsOnly.toggle()
                            }
                        }
                    }
                    // Festivals (prompt 171): one chip each; picking one opens its artist row below.
                    ForEach(festivals) { f in
                        chip(f.name, icon: "music.mic", on: filter.festivalPack == f.packID, id: "clips.filter.festival") {
                            let on = filter.festivalPack == f.packID
                            filter.festivalPack = on ? nil : f.packID
                            filter.festivalArtist = nil
                            filter.activity = nil
                        }
                    }
                    chip("Videos", icon: "play.rectangle", on: filter.kind == .videos, id: "clips.filter.videos") {
                        filter.kind = filter.kind == .videos ? .all : .videos
                    }
                    chip("Photos", icon: "photo", on: filter.kind == .photos, id: "clips.filter.photos") {
                        filter.kind = filter.kind == .photos ? .all : .photos
                    }
                    // Where hidden clips live (prompt 164): last, and only when there's something hidden.
                    if hiddenCount > 0 || filter.showHidden {
                        chip("Hidden · \(hiddenCount)", icon: "eye.slash", on: filter.showHidden, id: "clips.filter.hidden") {
                            filter.showHidden.toggle()
                        }
                    }
                }
                .padding(.horizontal, SnappetSpacing.lg)
            }
            .accessibilityIdentifier("clips.filter.chips")
    }

    /// The selected festival's artists — All · each artist you have matched clips of · Untagged (N).
    private func artistChips(_ row: (artists: [String], untagged: Int)) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", icon: "music.note.list", on: filter.festivalArtist == nil, id: "clips.filter.artist.all") {
                    filter.festivalArtist = nil
                }
                ForEach(row.artists, id: \.self) { a in
                    chip(a, icon: "music.mic", on: filter.festivalArtist == .artist(a), id: "clips.filter.artist") {
                        filter.festivalArtist = filter.festivalArtist == .artist(a) ? nil : .artist(a)
                    }
                }
                if row.untagged > 0 {
                    chip("Untagged · \(row.untagged)", icon: "questionmark.circle", on: filter.festivalArtist == .untagged, id: "clips.filter.artist.untagged") {
                        filter.festivalArtist = filter.festivalArtist == .untagged ? nil : .untagged
                    }
                }
            }
            .padding(.horizontal, SnappetSpacing.lg)
        }
        .accessibilityIdentifier("clips.filter.artists")
    }

    private func chip(_ label: String, icon: String, on: Bool,
                      id: String, action: @escaping () -> Void) -> some View {
        // Prompt 216: one outlined pill style, the user's accent when on (per-activity colours stay off chrome).
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                    .accessibilityHidden(true)   // the label says it; some symbols carry their own traits
                Text(label).font(.system(size: 13))
            }
            .snappetPill(selected: on)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Activity accents (prompt 170)

extension ClipFeedPost.Discipline {
    /// The activity's colour — existing tokens: climbing = Kilter amber, strength = Workout orange,
    /// cardio = blue, dance = purple, mobility = teal, festival = orchid, other = brand.
    var accent: Color {
        switch self {
        case .climbing: return SnappetColor.kilter
        case .strength: return SnappetColor.workout
        case .cardio: return SnappetColor.budget
        case .racket: return SnappetColor.household
        case .dance: return SnappetColor.journal
        case .mobility: return SnappetColor.tip
        case .festival: return SnappetColor.festival
        case .general: return SnappetColor.brand
        }
    }
}
