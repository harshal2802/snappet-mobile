import SwiftUI

// MARK: - Clips feed — explore grid (prompt 86)
//
// An IG-profile-style grid of all Clips POSTS (covers) to browse at a glance and jump to one. Derive-on-
// read over the same `ClipFeedComposer` posts — no new persistence. Tapping a cover dismisses the grid and
// scrolls the feed to that post (the feed is where inline playback + the ⋯ menu live).

struct ClipsGridView: View {
    let posts: [ClipFeedPost]
    /// The picked post id → the feed scrolls to it.
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if posts.isEmpty {
                    ContentUnavailableView {
                        Label("No clips yet", systemImage: "square.grid.3x3")
                    } description: {
                        Text("Film a workout or a climb and your clips show up here.")
                    }
                    .accessibilityIdentifier("clips.grid.empty")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(posts) { post in
                                cell(post)
                                    .onTapGesture { onPick(post.id); dismiss() }
                            }
                        }
                        .padding(2)
                    }
                    .accessibilityIdentifier("clips.grid")
                }
            }
            .background(SnappetColor.paper)
            .navigationTitle("All clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // One square cover cell: the post's first clip thumbnail (sized to the cell, not a fixed 300pt) + its
    // name + a stack badge for multi-clip posts.
    private func cell(_ post: ClipFeedPost) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)   // square cell sized to the column width
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .bottomLeading) {
                        if let first = post.clips.first {
                            ClipThumbnail(localIdentifier: first.media.localIdentifier, kind: first.media.kind,
                                          size: geo.size)
                        } else {
                            Color.black
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                            .allowsHitTesting(false)
                        Text(post.title).font(.caption2.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                            .padding(6)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .overlay(alignment: .topTrailing) {
                if post.clipCount > 1 {
                    Image(systemName: "rectangle.stack.fill").font(.caption2).foregroundStyle(.white)
                        .shadow(radius: 2).padding(5)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityIdentifier("clips.grid.cell")
    }
}
