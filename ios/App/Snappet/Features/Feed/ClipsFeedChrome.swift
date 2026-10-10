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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "applewatch")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SnappetColor.perfFresh)
                    .frame(width: 44, height: 44)
                    .background(SnappetColor.perfFresh.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("See your Apple Watch workouts here")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(SnappetColor.ink)
                    Text("Connect Apple Health and workouts you record on your watch appear in Clips automatically — heart rate included.")
                        .font(.caption)
                        .foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SnappetColor.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(SnappetColor.surfaceMuted, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("clips.healthOffer.dismiss")
                .accessibilityLabel("Dismiss")
            }
            Button(action: onConnect) {
                Text("Connect Apple Health")
                    .font(.footnote.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.perfFresh)
            .accessibilityIdentifier("clips.healthOffer.connect")
        }
        .padding(12)
        .background(SnappetColor.perfFresh.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(SnappetColor.perfFresh.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, SnappetSpacing.lg)
        // `.contain` keeps the Connect/dismiss buttons' OWN identifiers reachable under the
        // card's (identifier-on-container otherwise flattens them out of the UITest tree —
        // the habit.row precedent).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clips.healthOffer")
    }
}

// MARK: - Weekly Highlight Reel hero (highlights P4 · P5 polish)

/// The Sunday-drop card at the top of Clips, per the wireframe (workout-reels-v2 screen 1): a
/// dark coral-gradient canvas, the ✦ WEEKLY HIGHLIGHTS tag, a play badge, and a mini filmstrip.
/// A `NavigationLink` into the shared reel builder (`WeeklyReelHostView`) — everything on it is
/// a decorative gradient/shape (no players, no thumbnails, no live blur), so the feed's scroll
/// perf is untouched (the prompt 92/97 discipline).
struct WeeklyReelHeroCard: View {
    let offer: WeeklyHighlights.Offer

    /// The wireframe's warm dark canvas — deliberately the same in light and dark mode (a media
    /// hero commits to the dark look, like the posters below it).
    private let canvasTop = Color(red: 0.23, green: 0.14, blue: 0.13)
    private let canvasMid = Color(red: 0.13, green: 0.07, blue: 0.09)
    private let canvasBottom = Color(red: 0.09, green: 0.05, blue: 0.07)
    /// The filmstrip's six static frame fills — decoration standing in for "your week's footage".
    private static let frameTints: [(Color, Color)] = [
        (Color(red: 0.29, green: 0.31, blue: 0.35), Color(red: 0.17, green: 0.18, blue: 0.21)),
        (Color(red: 0.34, green: 0.25, blue: 0.17), Color(red: 0.20, green: 0.15, blue: 0.10)),
        (Color(red: 0.29, green: 0.31, blue: 0.35), Color(red: 0.17, green: 0.18, blue: 0.21)),
        (Color(red: 0.17, green: 0.29, blue: 0.22), Color(red: 0.10, green: 0.17, blue: 0.13)),
        (Color(red: 0.29, green: 0.31, blue: 0.35), Color(red: 0.17, green: 0.18, blue: 0.21)),
        (Color(red: 0.34, green: 0.25, blue: 0.17), Color(red: 0.20, green: 0.15, blue: 0.10)),
    ]

    var body: some View {
        NavigationLink(value: WeeklyReelRoute()) {
            ZStack {
                LinearGradient(colors: [canvasTop, canvasMid, canvasBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // The two decorative glows (coral + amber radials) — gradient fills, not .blur,
                // so nothing re-rasterizes while the card slides.
                RadialGradient(colors: [SnappetColor.reels.opacity(0.32), .clear],
                               center: .init(x: 0.2, y: 0.28), startRadius: 0, endRadius: 150)
                RadialGradient(colors: [Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.20), .clear],
                               center: .init(x: 0.85, y: 0.75), startRadius: 0, endRadius: 170)

                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(red: 0.16, green: 0.04, blue: 0.02))
                    .frame(width: 46, height: 46)
                    .background(SnappetColor.reels.opacity(0.92), in: Circle())
                    .shadow(color: SnappetColor.reels.opacity(0.45), radius: 12, y: 6)
                    .offset(y: -22)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                        Text("WEEKLY HIGHLIGHTS").font(.system(size: 10, weight: .heavy)).tracking(0.5)
                    }
                    .foregroundStyle(SnappetColor.reels)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().strokeBorder(SnappetColor.reels.opacity(0.5), lineWidth: 1))

                    Spacer(minLength: 0)

                    filmstrip
                        .padding(.bottom, 10)
                    Text("Your week in highlights")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                    Text(offer.subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .strokeBorder(SnappetColor.reels.opacity(0.55), lineWidth: 1.5))
            .padding(.horizontal, SnappetSpacing.lg)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("clips.weeklyReel")
        .accessibilityLabel("Weekly Highlight Reel — \(offer.subtitle)")
    }

    /// Six static gradient "frames" — the wireframe's filmstrip strip, as pure decoration.
    private var filmstrip: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.frameTints.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Self.frameTints[i].0, Self.frameTints[i].1],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
            }
        }
        .opacity(0.85)
        .allowsHitTesting(false)
    }
}

// MARK: - Session header (prompt 167)

/// The pinned header above a session's posts: kind glyph · session name · "Tue 30 Sep · Kilter · 40°" ·
/// post count. Opaque so posts scroll under it cleanly.
struct ClipSessionHeader: View {
    let section: ClipFeedSection

    /// The session's ACTIVITY drives glyph + accent (prompt 170) — an imported climbing workout reads as a
    /// climb, not a dumbbell.
    private var activity: ClipFeedPost.Discipline { section.discipline ?? .general }
    private var accent: Color { activity.accent }
    private var glyph: String { activity.symbol }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title).font(.footnote.weight(.bold)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                if let detail = section.detail {
                    Text(detail).font(.caption2).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(section.countLabel).font(.caption2.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
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
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if !isSearching {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Favorites", icon: "heart.fill", accent: SnappetColor.brand,
                         on: filter.favoritesOnly, id: "clips.filter.favorites") {
                        filter.favoritesOnly.toggle()
                    }
                    chip("Reels", icon: "sparkles.tv", accent: SnappetColor.reels,
                         on: filter.reelsOnly, id: "clips.filter.reels") {
                        filter.reelsOnly.toggle()
                    }
                    // Activity chips (prompt 170) — only activities you HAVE posts for, in a fixed order;
                    // one at a time. Sends rides right after Climbing (it's a climbing outcome).
                    ForEach(activities, id: \.self) { a in
                        chip(a.label, icon: a.symbol, accent: a.accent,
                             on: filter.activity == a, id: "clips.filter.\(a.rawValue)") {
                            filter.activity = filter.activity == a ? nil : a
                        }
                        if a == .climbing {
                            // Sends (prompt 161): flashes + sends, Kilter or Quick Session. Stacks like Favorites.
                            chip("Sends", icon: "checkmark.seal.fill", accent: SnappetColor.perfFresh,
                                 on: filter.sendsOnly, id: "clips.filter.sends") {
                                filter.sendsOnly.toggle()
                            }
                        }
                    }
                    chip("Videos", icon: "play.rectangle", accent: SnappetColor.brand,
                         on: filter.kind == .videos, id: "clips.filter.videos") {
                        filter.kind = filter.kind == .videos ? .all : .videos
                    }
                    chip("Photos", icon: "photo", accent: SnappetColor.brand,
                         on: filter.kind == .photos, id: "clips.filter.photos") {
                        filter.kind = filter.kind == .photos ? .all : .photos
                    }
                    // Where hidden clips live (prompt 164): last, and only when there's something hidden.
                    if hiddenCount > 0 || filter.showHidden {
                        chip("Hidden · \(hiddenCount)", icon: "eye.slash", accent: SnappetColor.textSecondary,
                             on: filter.showHidden, id: "clips.filter.hidden") {
                            filter.showHidden.toggle()
                        }
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
                    .accessibilityHidden(true)   // the label says it; some symbols carry their own traits
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

// MARK: - Activity accents (prompt 170)

extension ClipFeedPost.Discipline {
    /// The activity's colour — existing tokens: climbing = Kilter amber, strength = Workout orange,
    /// cardio = blue, dance = purple, mobility = teal, festival = orchid, other = brand.
    var accent: Color {
        switch self {
        case .climbing: return SnappetColor.kilter
        case .strength: return SnappetColor.workout
        case .cardio: return SnappetColor.budget
        case .dance: return SnappetColor.journal
        case .mobility: return SnappetColor.tip
        case .festival: return SnappetColor.festival
        case .general: return SnappetColor.brand
        }
    }
}
