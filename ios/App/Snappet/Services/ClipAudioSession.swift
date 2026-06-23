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
enum ClipAudioSession {

    /// Route clip audio through `.playback` so an unmuted clip plays over the silent switch and takes the
    /// audio focus. Idempotent; safe to call repeatedly.
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
    }

    /// Release the session so the user's other audio resumes once no clip is unmuted.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
