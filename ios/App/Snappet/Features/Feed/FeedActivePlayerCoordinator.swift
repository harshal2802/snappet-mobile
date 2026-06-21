import Foundation
import CoreGraphics

// MARK: - Recap Feed — single-active-player index math (F3, pure)
//
// The scroll-center rule (`_locked-design.md:75`, `198`): at most ONE clip plays at a
// time — the card whose frame vertical center is nearest the viewport vertical center.
// On scroll the active player hands off (pause+release old, attach+play new), with
// HYSTERESIS so a card straddling center doesn't thrash: a new candidate only wins when
// it beats the CURRENT card's distance-to-center by more than `hysteresis`.
//
// PURE: Foundation + CoreGraphics only — NO SwiftUI/AVFoundation. The view (R2) feeds in
// the cards' frames + the viewport (both in a shared coordinate space) and gets back the
// index that should be active; the AVPlayer attach/teardown is the device edge.

enum FeedActivePlayerCoordinator {

    /// The index of the card that should hold the single active player, or `nil` when there
    /// are no on-screen candidates.
    ///
    /// "On-screen" = the card's vertical span overlaps the viewport's vertical span (a card
    /// fully scrolled past never wins). Among on-screen cards, the one whose vertical center
    /// is nearest the viewport's vertical center wins — with hysteresis: if `current` is still
    /// on-screen, a different candidate must beat `current`'s distance by MORE than `hysteresis`
    /// to take over, so a card sitting right at center can't flip-flop on tiny scroll jitter.
    ///
    /// - Parameters:
    ///   - cardFrames: each card's frame in the shared (scroll/global) coordinate space.
    ///   - viewport: the visible viewport in the same coordinate space.
    ///   - current: the currently-active index, if any (drives hysteresis).
    ///   - hysteresis: minimum distance-to-center improvement a challenger must show to win.
    static func activeIndex(cardFrames: [CGRect],
                            viewport: CGRect,
                            current: Int?,
                            hysteresis: CGFloat) -> Int? {
        guard !cardFrames.isEmpty else { return nil }
        let viewportCenterY = viewport.midY

        // Candidates: cards whose vertical span overlaps the viewport (visible at all).
        func isOnScreen(_ f: CGRect) -> Bool {
            f.maxY > viewport.minY && f.minY < viewport.maxY
        }
        func distance(_ f: CGRect) -> CGFloat { abs(f.midY - viewportCenterY) }

        // Best (nearest-center) on-screen candidate; ties broken by lowest index for stability.
        var best: (index: Int, dist: CGFloat)? = nil
        for (i, f) in cardFrames.enumerated() where isOnScreen(f) {
            let d = distance(f)
            if let b = best {
                if d < b.dist { best = (i, d) }
            } else {
                best = (i, d)
            }
        }
        guard let best else { return nil }   // nothing on screen → no active player

        // Hysteresis: keep the current card unless a challenger beats it by > hysteresis.
        if let current, current >= 0, current < cardFrames.count, isOnScreen(cardFrames[current]) {
            let currentDist = distance(cardFrames[current])
            if best.index == current { return current }
            // The challenger only wins when it's strictly closer by more than the band.
            if currentDist - best.dist > hysteresis { return best.index }
            return current
        }

        return best.index
    }
}
