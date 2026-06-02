import SwiftUI

/// "Snappet Pulse" motion tokens (issue #30 §5). Motion is purposeful, fast (150–300ms),
/// interruptible, native-spring based, and **always gated behind Reduce Motion**.
///
/// Usage: read `@Environment(\.accessibilityReduceMotion)` at the call site and pass it
/// to `snappetAnimation(_:reduceMotion:)`, or use the `.snappetAnimation(_:value:)`
/// View modifier which reads the environment for you.
enum SnappetMotion {
    /// Taps, toggles, chip selection. ~150ms.
    static let quick: Animation = .snappy(duration: 0.15)
    /// Cards, nav, sheets.
    static let standard: Animation = .spring(response: 0.35, dampingFraction: 0.82)
    /// Celebratory / hero moments.
    static let expressive: Animation = .spring(response: 0.5, dampingFraction: 0.7)
    /// A quiet cross-fade used as the Reduce-Motion fallback for content changes.
    static let reduced: Animation = .easeInOut(duration: 0.2)
}

/// Returns the requested animation, or a Reduce-Motion-friendly fallback when
/// `reduceMotion` is true. Spring-y tokens become a gentle cross-fade so value/content
/// changes still update smoothly without translation or bounce.
func snappetAnimation(_ token: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? SnappetMotion.reduced : token
}

private struct SnappetAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let token: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(snappetAnimation(token, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Like `.animation(_:value:)` but uses a Pulse motion token and automatically
    /// degrades to a cross-fade when Reduce Motion is on (reads the environment).
    func snappetAnimation<V: Equatable>(_ token: Animation, value: V) -> some View {
        modifier(SnappetAnimationModifier(token: token, value: value))
    }
}
