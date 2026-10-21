import SwiftUI

/// **An activity's progress album** — the Clips feed's Exercises level (prompt 197, wireframe screen 3): Then vs Now
/// (its first and latest filmed session), the gain, a timeline of sessions, and Open (its Activity page) /
/// Progress reel (every session's first video, oldest → newest).
struct ClipAlbumCard: View {
    let album: ClipFeedAlbum
    let unit: WeightUnit

    private var accent: Color { album.discipline.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if album.posts.count > 1 {
                HStack(spacing: 6) {
                    still(album.first, caption: "Then")
                    still(album.latest, caption: "Now")
                }
                .padding(.horizontal, SnappetSpacing.lg)
                if let gain = ClipFeedLevels.gain(album, unit: unit) {
                    (Text("Then vs Now · ").foregroundStyle(SnappetColor.ink)
                     + Text(gain).foregroundStyle(SnappetColor.perfFresh))
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, SnappetSpacing.lg)
                        .accessibilityIdentifier("clips.album.gain")
                }
            } else {
                still(album.latest, caption: nil).padding(.horizontal, SnappetSpacing.lg)
            }
            timeline
            HStack(spacing: 16) {
                NavigationLink(value: ActivityRoute(key: album.key, title: album.title)) {
                    Text("Open \(album.title) ›").font(.caption.weight(.semibold)).foregroundStyle(accent)
                }
                .accessibilityIdentifier("clips.album.open")
                if let reel = reelScope {
                    NavigationLink(value: reel) {
                        Label("Progress reel", systemImage: "sparkles").font(.caption.weight(.semibold))
                            .foregroundStyle(SnappetColor.reels)
                    }
                    .accessibilityIdentifier("clips.album.reel")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, SnappetSpacing.lg)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clips.album")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: album.discipline.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.16), in: Circle())
                .overlay(Circle().strokeBorder(accent, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                    .accessibilityIdentifier("clips.album.title")
                Text("\(album.clipCount) \(album.clipCount == 1 ? "clip" : "clips") · \(album.sessionCount) \(album.sessionCount == 1 ? "session" : "sessions") · since \(album.since.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.caption).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SnappetSpacing.lg)
    }

    /// A session's first clip, labelled with its date + what you did ("Aug 12 · 4 × 8 @ 60 kg").
    private func still(_ post: ClipFeedPost, caption: String?) -> some View {
        let item = post.clips.first
        let line = [post.sessionStartedAt.formatted(.dateTime.day().month(.abbreviated)),
                    post.stats?.line ?? post.climbResult?.status.label].compactMap { $0 }.joined(separator: " · ")
        return NavigationLink(value: ActivityRoute(key: album.key, title: album.title)) {
            ZStack(alignment: .bottomLeading) {
                if let item {
                    ClipThumbnail(localIdentifier: item.media.localIdentifier, kind: item.media.kind,
                                  size: CGSize(width: 180, height: 230), exactFrame: false)
                        .frame(maxWidth: .infinity).frame(height: 190).clipped()
                } else {
                    Rectangle().fill(SnappetColor.surface).frame(height: 190)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let caption { Text(caption.uppercased()).font(.system(size: 9, weight: .heavy)).opacity(0.8) }
                    Text(line).font(.caption2.weight(.bold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Every session, newest first.
    private var timeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(album.posts.reversed(), id: \.id) { post in
                    VStack(alignment: .leading, spacing: 2) {
                        if let item = post.clips.first {
                            ClipThumbnail(localIdentifier: item.media.localIdentifier, kind: item.media.kind,
                                          size: CGSize(width: 58, height: 58), exactFrame: false)
                                .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        Text(post.sessionStartedAt.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.system(size: 9)).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
            }
            .padding(.horizontal, SnappetSpacing.lg)
        }
    }

    /// Each session's first video, oldest → newest, captioned with its date + effort — the activity's progress reel.
    private var reelScope: ClipsReelScope? {
        let picks = album.posts.compactMap { p in p.clips.first(where: { $0.media.kind == "video" }).map { (p, $0) } }
        guard picks.count >= 2 else { return nil }
        let captions = Dictionary(picks.map { p, item in
            (item.media.localIdentifier,
             [p.sessionStartedAt.formatted(.dateTime.day().month(.abbreviated)), p.stats?.line].compactMap { $0 }
                .joined(separator: " · "))
        }, uniquingKeysWith: { a, _ in a })
        return .progress(Set(picks.map(\.1.media.id)), title: album.title, captions: captions)
    }
}
