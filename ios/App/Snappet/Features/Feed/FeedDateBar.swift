import SwiftUI

// MARK: - Recap Feed — scroll date bar (F8)
//
// One slim element pinned at the top of the feed: a persistent era "whisper" while you read
// ("This week"), expanding to the precise day + a glass backing + a thin progress underline while you
// scroll ("This week · Wed · Jun 17"), then receding ~1.2s after you stop. It sits in the top inset and
// never overlaps a card. The orientation strings are pure (`FeedTimeBucket`); this view is layout only.

struct FeedDateBar: View {
    let label: FeedDateLabel
    /// True while scrolling (and for ~1.2s after): reveal the precise day + glass + progress underline.
    let revealed: Bool
    /// Scroll depth 0…1, drives the progress underline (only shown while revealed).
    let progress: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label.era.uppercased())
                .font(.caption2.weight(.heavy)).tracking(1.2)
                .foregroundStyle(revealed ? SnappetColor.ink : SnappetColor.textSecondary)
            Spacer(minLength: 0)
            if revealed {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(label.day)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(SnappetColor.ink)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, SnappetSpacing.lg)
        .padding(.vertical, 7)
        .background {
            // Glass only while revealed; at rest the era is a transparent whisper over the feed.
            if revealed { Rectangle().fill(.ultraThinMaterial) }
        }
        .overlay(alignment: .bottom) {
            if revealed {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        SnappetColor.hairline
                        LinearGradient(colors: [SnappetColor.kilter, SnappetColor.workout],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * max(0, min(1, progress)))
                    }
                }
                .frame(height: 2)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: revealed)
        .accessibilityIdentifier("feed.dateBar")
        .accessibilityLabel(revealed ? "\(label.era), \(label.day)" : label.era)
    }
}
