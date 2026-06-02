import SwiftUI

/// App-wide transition + animation vocabulary, so every screen-to-screen change in the suite uses
/// one consistent motion language instead of ad-hoc per-view tuning. Centralizing it here means a
/// tweak to the suite's "feel" is a one-file change, and new screens get the same motion for free.
///
/// - `Animation.snappyNav` — the standard spring for navigation/section changes.
/// - `AnyTransition.workoutPhase` — the exercise → rest → done cross-fade-and-slide in the player.
/// - `AnyTransition.liveBanner` — the live-workout banner's insert/remove from the bottom.
/// - `AnyTransition.sectionSwap` — the workout section switcher's horizontal swap.
enum Motion {
    /// The suite's default navigation spring — used for section swaps, banner insertion, and
    /// any `withAnimation { … }` that should feel like the rest of the app's chrome.
    static let nav: Animation = .snappy(duration: 0.32, extraBounce: 0.04)
    /// A gentler ease for content cross-fades (player phases) where a spring would feel busy.
    static let content: Animation = .smooth(duration: 0.30)
}

extension Animation {
    /// Convenience alias so call sites read `.snappyNav` at the modifier.
    static var snappyNav: Animation { Motion.nav }
}

extension AnyTransition {
    /// Player phase change (exercise ↔ rest ↔ done): the outgoing screen fades while the incoming
    /// one slides up a touch and fades in — distinct enough to read as "a new step" without a
    /// jarring full slide.
    static var workoutPhase: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -10))
        )
    }

    /// The live-workout banner sliding in from / out to the bottom edge with a fade.
    static var liveBanner: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    /// The workout section switcher (segmented control) swapping its body horizontally.
    static var sectionSwap: AnyTransition {
        .asymmetric(
            insertion: .push(from: .trailing).combined(with: .opacity),
            removal: .opacity
        )
    }
}
