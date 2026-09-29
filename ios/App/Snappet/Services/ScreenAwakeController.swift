import SwiftUI
import UIKit

/// The one owner of `UIApplication.isIdleTimerDisabled` (prompt 135). Surfaces take a named **hold**
/// while they need the screen on and release it when done; the flag is derived from the set of live
/// holds + the user's `KeepScreenAwakeMode` via the pure `ScreenAwakePolicy`. Nothing else writes the
/// flag — before this, three covers each set it `true` on appear and `false` on disappear, so closing
/// a timed set turned auto-lock back on under a still-open workout.
@MainActor
final class ScreenAwakeController {
    private var holds: [String: ScreenAwakeReason] = [:]
    private let apply: (Bool) -> Void

    var mode: KeepScreenAwakeMode {
        didSet { if mode != oldValue { reassert() } }
    }

    /// `apply` is injectable so the hold bookkeeping is unit-tested without touching `UIApplication`.
    init(mode: KeepScreenAwakeMode = KeepScreenAwakeMode.resolve(
            UserDefaults.standard.string(forKey: KeepScreenAwakeMode.storageKey)),
         apply: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.mode = mode
        self.apply = apply
    }

    /// Take (or re-take) the hold named `id`. Idempotent per id.
    func hold(_ id: String, reason: ScreenAwakeReason) {
        holds[id] = reason
        reassert()
    }

    /// Drop the hold named `id` — only that one; other surfaces' holds are untouched.
    func release(_ id: String) {
        guard holds.removeValue(forKey: id) != nil else { return }
        reassert()
    }

    /// Hold while `active`, release otherwise — for state-driven surfaces (a timer's `isRunning`).
    func set(_ id: String, reason: ScreenAwakeReason, active: Bool) {
        active ? hold(id, reason: reason) : release(id)
    }

    var isKeepingAwake: Bool { ScreenAwakePolicy.shouldKeepAwake(mode: mode, holding: holds.values) }

    /// Re-write the flag from current state. Also called on foregrounding, so the value is right
    /// after the app returns from the background.
    func reassert() { apply(isKeepingAwake) }
}

extension EnvironmentValues {
    /// Optional so reusable views (`StopwatchView`) stay usable in previews / hosts without an AppModel;
    /// `nil` makes every hold a no-op.
    @Entry var screenAwake: ScreenAwakeController? = nil
}
