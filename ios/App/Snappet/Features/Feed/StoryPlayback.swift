import Foundation

// MARK: - Recap Feed — pure Story playback state machine (F6)
//
// Owns scene index / per-scene progress / pause. The view feeds it a `tick(dt)` (and pause/resume on
// touch) — no Timer/UI here, so it unit-tests without a simulator. Auto-advance is gated by the view
// (it skips ticking under Reduce Motion).

struct StoryPlayback: Equatable, Sendable {
    let sceneCount: Int
    let perSceneDuration: Double
    private(set) var index: Int = 0
    private(set) var elapsed: Double = 0
    private(set) var isPaused: Bool = false

    init(sceneCount: Int, perSceneDuration: Double = 5) {
        self.sceneCount = max(1, sceneCount)
        self.perSceneDuration = max(0.1, perSceneDuration)
    }

    /// 0…1 progress through the current scene.
    var progress: Double { min(1, elapsed / perSceneDuration) }

    /// Advance the auto-play clock. Returns true when the player should DISMISS (finished the last scene).
    mutating func tick(_ dt: Double) -> Bool {
        guard !isPaused, dt > 0 else { return false }
        elapsed += dt
        guard elapsed >= perSceneDuration else { return false }
        if index < sceneCount - 1 { index += 1; elapsed = 0; return false }
        elapsed = perSceneDuration
        return true
    }

    /// Tap-right. Returns true when it should dismiss (advanced past the last scene).
    mutating func next() -> Bool {
        if index < sceneCount - 1 { index += 1; elapsed = 0; return false }
        return true
    }

    /// Tap-left.
    mutating func back() {
        if index > 0 { index -= 1 }
        elapsed = 0
    }

    mutating func pause() { isPaused = true }
    mutating func resume() { isPaused = false }
}
