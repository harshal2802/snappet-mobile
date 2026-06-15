import SwiftUI

/// App-wide screen-transition helpers. There is **one** motion vocabulary in the suite —
/// `SnappetMotion` (the Reduce-Motion-gated Pulse tokens) — and this file's `Motion` simply
/// re-exports those tokens so older call sites keep reading, while the transition factories below
/// degrade to a plain cross-fade under Reduce Motion (#79). Centralizing it means a tweak to the
/// suite's "feel" is a one-file change, and new screens get the same motion for free.
enum Motion {
    /// The suite's default navigation animation — now an alias of the one vocabulary's `standard`
    /// token, so there's no second, ungated motion language to drift (#79).
    static let nav: Animation = SnappetMotion.standard
    /// Content cross-fades (player phases). Also folded onto the shared tokens.
    static let content: Animation = SnappetMotion.standard
}

extension Animation {
    /// Convenience alias so call sites read `.snappyNav` at the modifier.
    static var snappyNav: Animation { Motion.nav }
}

extension AnyTransition {
    /// Player phase change (exercise ↔ rest ↔ done): the outgoing screen fades while the incoming one
    /// slides up a touch and fades in — distinct enough to read as "a new step". Under Reduce Motion
    /// it's a plain cross-fade, no translation (#79).
    static func workoutPhase(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -10))
        )
    }

    /// The live-workout / focus banner sliding in from / out to the bottom edge with a fade — a plain
    /// fade under Reduce Motion.
    static func liveBanner(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// The workout section switcher (segmented control) swapping its body horizontally — a plain
    /// cross-fade under Reduce Motion, no horizontal push (#79).
    static func sectionSwap(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .push(from: .trailing).combined(with: .opacity),
            removal: .opacity
        )
    }
}
