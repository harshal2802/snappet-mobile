import Foundation

// MARK: - Clips feed — transient messages (prompt 164 · 166, pure)

/// The feed's one short-lived message: "Clip hidden · Undo" (prompt 164) or an autoplay confirmation
/// (prompt 166). `id` makes two identical messages distinct so a re-tap restarts the timer.
struct ClipFeedToast: Equatable {
    var id = UUID()
    var message: String
    /// Set when the toast offers Undo for a hide.
    var undoHidden: Set<UUID>? = nil
}

/// What the autoplay control says when tapped (prompt 166). Says when the SYSTEM is holding autoplay back,
/// so "on" never silently does nothing (autoplay stands down under Reduce Motion / Low Power Mode).
enum ClipAutoplayCopy {
    static func message(enabled: Bool, reduceMotion: Bool, lowPower: Bool) -> String {
        guard enabled else { return "Autoplay off — tap a clip to play it" }
        if lowPower { return "Autoplay on — paused while Low Power Mode is on" }
        if reduceMotion { return "Autoplay on — paused while Reduce Motion is on" }
        return "Autoplay on — clips play muted as you scroll"
    }
}
