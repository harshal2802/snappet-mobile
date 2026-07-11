import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The suite's one thin haptics wrapper (issue #80) — every commit point fires through
/// here so the tactile language stays consistent and there's a single seam to tune.
/// Originally private to the workout player; promoted when the rest of the suite gained
/// commit feedback. UIKit is fine in the app target; only `HighlightEngine` is
/// platform-free. Each call is a no-op where UIKit is unavailable.
enum Haptics {
    /// A commit landed: habit checked, climb logged, expense/settlement/journal saved,
    /// export finished, focus block completed.
    @MainActor static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Something needs attention (break over, contact lost) — softer than an error.
    @MainActor static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// A light tick for small state flips (favorite toggle, chip selection).
    @MainActor static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
