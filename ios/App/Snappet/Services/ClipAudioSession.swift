import AVFoundation

// MARK: - Clips feed — audio session for unmuted playback (prompt 93)
//
// The app otherwise never configures an `AVAudioSession`, so playback runs on the default ambient
// category — which the hardware ring/silent switch silences, making clip audio inaudible even when the
// player is unmuted. This routes an UNMUTED clip through `.playback` (Instagram/TikTok style): audio plays
// through the silent switch and interrupts the user's other audio while a clip is unmuted; releasing the
// session restores their music/podcast. Driven purely by the feed's single source of truth
// (`PlayingClipRef.muted`): `activate()` when a clip is unmuted, `deactivate()` when none is.
//
// AVFoundation I/O lives here (Services), not in the pure feed. Failures are swallowed — an audio-session
// hiccup must never crash playback (the clip just stays silent, as before).
//
// PERF (prompt 106 round 3): `AVAudioSession.setActive` round-trips to mediaserverd and can block the
// calling thread ~50–200 ms. Unguarded on the main thread, every carousel page change (which rewrites
// `ClipFeedPlayback.playing` → its didSet → `deactivate()` for a muted clip) stalled the exact frame the
// swipe snap commits on — measured on device as a one-frame jump-cut + ~100 ms freeze (the "teleporting"
// carousel). Two rules now: (1) track the active state and NO-OP when nothing changes — muted autoplay
// never activated the session, so its per-swipe deactivate was pure waste; (2) when the state DOES change,
// do the mediaserverd round-trip on a background serial queue, never the caller's thread.
@MainActor
enum ClipAudioSession {

    /// Whether WE hold the session active — the guard that makes repeated calls free. Tracks intent, not
    /// mediaserverd truth (good enough: we're the only in-app writer, and a stale `false` just means one
    /// redundant background `setActive`).
    private static var active = false
    /// Serial so a rapid activate → deactivate → activate lands in call order.
    private static let queue = DispatchQueue(label: "com.snappet.clip-audio", qos: .userInitiated)

    /// Route clip audio through `.playback` so an unmuted clip plays over the silent switch and takes the
    /// audio focus. Idempotent; safe to call repeatedly (repeats are a guarded no-op).
    static func activate() {
        guard !active else { return }
        active = true
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback)
            try? session.setActive(true)
        }
    }

    /// Release the session so the user's other audio resumes once no clip is unmuted.
    static func deactivate() {
        guard active else { return }
        active = false
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
