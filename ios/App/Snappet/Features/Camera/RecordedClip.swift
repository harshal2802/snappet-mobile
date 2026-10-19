import Foundation

/// A clip (or photo) captured in-session with the in-app camera (`SnappetCameraView`) and already saved to the user's Photos library, awaiting a
/// session tag. Carries the saved asset's `localIdentifier`, the wall-clock instant recording **began**
/// (mapped to a session-relative offset when the clip is attached, via `SessionMediaService.candidate`),
/// and its measured duration. A plain value type so it can be accumulated in a cover and handed up to the
/// session at commit time.
struct RecordedClip: Identifiable, Sendable, Equatable {
    let id: UUID
    /// The PHAsset `localIdentifier` of the just-saved recording (the same handle every `SessionMedia` row
    /// stores — bytes stay in Photos).
    let localIdentifier: String
    /// Wall-clock instant recording started → the session-relative `offsetSec` at attach time.
    let capturedAt: Date
    /// Measured video duration in seconds; `nil` when it couldn't be read (and for a photo).
    let durationSec: Double?
    /// A still from the in-app camera's PHOTO mode / mid-clip (prompt 190) rather than a video.
    var isPhoto: Bool = false

    init(id: UUID = UUID(), localIdentifier: String, capturedAt: Date, durationSec: Double?, isPhoto: Bool = false) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.capturedAt = capturedAt
        self.durationSec = durationSec
        self.isPhoto = isPhoto
    }
}
