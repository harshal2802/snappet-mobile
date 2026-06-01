import Foundation
import CoreGraphics
import SwiftData

/// A text overlay on a clip — a `Codable` value stored inline in `ClipEdit.textOverlays`
/// (a composite, like `WorkoutSession.exercises`/`hrSeries`, not a separate `@Model`).
///
/// `normalizedPosition` is the overlay's center in 0…1 of the output canvas (**top-left
/// origin**, SwiftUI-style); `VideoStudio` maps it to a `CALayer` point via
/// `ClipEditGeometry.layerPoint`. `colorHex` is `#RRGGBB`. The overlay is visible only while
/// `startSec ≤ playhead ≤ endSec` (in *output*/edited time).
struct TextOverlay: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var string: String
    /// Center position, normalized 0…1 (top-left origin).
    var normalizedPosition: CGPoint
    var fontSize: Double
    /// `#RRGGBB`.
    var colorHex: String
    /// Visible window in output (edited) seconds.
    var startSec: Double
    var endSec: Double

    init(id: UUID = UUID(), string: String,
         normalizedPosition: CGPoint = CGPoint(x: 0.5, y: 0.5),
         fontSize: Double = 48, colorHex: String = "#FFFFFF",
         startSec: Double = 0, endSec: Double = .greatestFiniteMagnitude) {
        self.id = id
        self.string = string
        self.normalizedPosition = normalizedPosition
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// A **non-destructive** edit on a single source clip (B3) — the edit list is *data, not baked
/// pixels*. `VideoStudio` (`Services/`) turns a `ClipEdit` + its source `PHAsset` into a
/// playable/exportable `AVMutableComposition` + `AVMutableVideoComposition`; nothing is rendered
/// or copied until export, so editing is instant and reversible.
///
/// Keyed to its source `SessionMedia` by `sessionMediaID` (a `UUID` **foreign key**, NOT a
/// SwiftData `@Relationship` — the suite convention, matching `SessionMedia.sessionID`), with the
/// PHAsset `localIdentifier` **denormalized** so the studio can resolve the source asset without a
/// second fetch. **Split** = two `ClipEdit`s with adjacent, non-overlapping trims (see
/// `ClipEditGeometry.split`); `splitOrder` keeps them in sequence.
///
/// All geometry/timing fields are resolution-independent (seconds / normalized 0…1) so the same
/// edit applies at any render size — the pure math lives in `ClipEditGeometry`.
@Model
final class ClipEdit {
    var id: UUID
    /// FK to `SessionMedia.id` (NOT a relationship).
    var sessionMediaID: UUID
    /// Denormalized PHAsset id (from `SessionMedia.localIdentifier`) so `VideoStudio` resolves
    /// the source without re-fetching the `SessionMedia`.
    var localIdentifier: String

    // Trim (split = two ClipEdits with adjacent trims).
    /// Trim start within the source, seconds.
    var trimStart: Double
    /// Trim end within the source, seconds. `nil` = use the asset's full duration (resolved lazily,
    /// since the source duration isn't known until the asset loads).
    var trimEnd: Double?
    /// Order among ClipEdits split from the same source (0 for an unsplit clip).
    var splitOrder: Int

    // Crop / transform / output aspect.
    /// Normalized crop rect (origin + size in 0…1 of the source). Default = full frame.
    var cropX: Double
    var cropY: Double
    var cropWidth: Double
    var cropHeight: Double
    /// `OutputAspect.rawValue` — the render canvas (mixed-orientation normalization).
    var aspectRaw: String

    // Speed.
    /// Playback-rate multiplier (0.25…4.0), applied via `scaleTimeRange`.
    var speed: Double

    // Overlays (inline Codable composite).
    var textOverlays: [TextOverlay]

    // Audio.
    var mutedOriginalAudio: Bool
    /// Optional background-music track name (resolved by `VideoStudio` to a bundled asset; `nil`
    /// keeps the original audio per `mutedOriginalAudio`).
    var musicTrackName: String?

    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), sessionMediaID: UUID, localIdentifier: String,
         trimStart: Double = 0, trimEnd: Double? = nil, splitOrder: Int = 0,
         cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
         aspect: ClipEditGeometry.OutputAspect = .portrait9x16,
         speed: Double = 1.0, textOverlays: [TextOverlay] = [],
         mutedOriginalAudio: Bool = false, musicTrackName: String? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.sessionMediaID = sessionMediaID
        self.localIdentifier = localIdentifier
        self.trimStart = max(0, trimStart)
        self.trimEnd = trimEnd
        self.splitOrder = splitOrder
        self.cropX = cropRect.minX
        self.cropY = cropRect.minY
        self.cropWidth = cropRect.width
        self.cropHeight = cropRect.height
        self.aspectRaw = aspect.rawValue
        self.speed = ClipEditGeometry.clampSpeed(speed)
        self.textOverlays = textOverlays
        self.mutedOriginalAudio = mutedOriginalAudio
        self.musicTrackName = musicTrackName
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - Convenience accessors (typed views over the stored fields)

    var cropRect: CGRect {
        get { CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight) }
        set {
            cropX = newValue.minX; cropY = newValue.minY
            cropWidth = newValue.width; cropHeight = newValue.height
        }
    }

    var aspect: ClipEditGeometry.OutputAspect {
        get { ClipEditGeometry.OutputAspect(rawValue: aspectRaw) ?? .portrait9x16 }
        set { aspectRaw = newValue.rawValue }
    }

    /// A fresh `ClipEdit` for a `SessionMedia` source (the editor's starting point).
    static func makeDefault(for media: SessionMedia) -> ClipEdit {
        ClipEdit(sessionMediaID: media.id, localIdentifier: media.localIdentifier)
    }
}
