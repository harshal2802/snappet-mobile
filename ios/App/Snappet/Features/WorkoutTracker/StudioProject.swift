import Foundation
import CoreGraphics
import SwiftData

// MARK: - Animation primitives

/// Easing curve for a keyframe segment. Pure mapping in `StudioGeometry.ease`.
enum StudioEasing: String, Codable, Sendable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut
}

/// One keyframe of a scalar animated over **output** (edited) time. Sequences of these drive
/// Ken-Burns scale, overlay position/opacity, filter intensity, etc. Interpolated by the pure
/// `StudioGeometry.value(of:at:)` — the editor stores intent, the compositor renders it.
struct StudioKeyframe: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var timeSec: Double
    var value: Double
    var easing: StudioEasing

    init(id: UUID = UUID(), timeSec: Double, value: Double, easing: StudioEasing = .easeInOut) {
        self.id = id
        self.timeSec = timeSec
        self.value = value
        self.easing = easing
    }
}

// MARK: - Main-track clip

/// Built-in colour treatment. Rendered by the (device-only) `StudioCompositor` via Core Image;
/// here it's just stored intent so the timeline + tests stay platform-free.
enum StudioFilter: String, Codable, Sendable, CaseIterable {
    case none, mono, noir, vivid, warm, cool, fade
    var display: String { self == .none ? "None" : rawValue.capitalized }
}

/// Manual colour **Adjust** for a clip (the edits "Adjust" tool) — brightness/contrast/saturation,
/// applied via `CIColorControls` in the compositor's filter path. Stored as a single optional on
/// `TimelineClip` (nil = neutral) so adding it is a migration-safe Codable change.
struct ClipAdjust: Codable, Hashable, Sendable {
    /// `CIColorControls` ranges: brightness −1…1 (0 = none), contrast 0…2 (1 = none), saturation
    /// 0…2 (1 = none).
    var brightness: Double
    var contrast: Double
    var saturation: Double

    static let neutral = ClipAdjust(brightness: 0, contrast: 1, saturation: 1)
    var isNeutral: Bool { brightness == 0 && contrast == 1 && saturation == 1 }
}

/// One clip on the **main video track**: a source (video or photo) with trim, speed, crop, a
/// colour filter, and optional Ken-Burns scale keyframes (photos). Non-destructive and
/// resolution-independent (seconds / normalized 0…1), like `ClipEdit` — generalized to many clips.
/// `order` sequences the track; **split** = two clips with adjacent trims (same `order` neighbours).
struct TimelineClip: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    /// Source `SessionMedia.id` (nil only for a synthetic/imported source); `localIdentifier` is the
    /// denormalized PHAsset id the compositor resolves.
    var sessionMediaID: UUID?
    var localIdentifier: String
    var isPhoto: Bool
    /// Position on the track (0-based). Ties broken by `id` for determinism.
    var order: Int

    // Trim (videos) — seconds within the source.
    var trimStart: Double
    var trimEnd: Double?
    /// Playback-rate multiplier (0.25…4.0), applied via `scaleTimeRange` (videos only).
    var speed: Double
    /// On-screen duration for a **photo** (no intrinsic duration); ignored for videos.
    var photoDurationSec: Double

    // Crop (normalized 0…1 of the source). Default = full frame.
    var cropX: Double, cropY: Double, cropWidth: Double, cropHeight: Double

    // Colour.
    var filterRaw: String
    var filterIntensity: Double
    /// Manual colour adjust (brightness/contrast/saturation). `nil` = neutral. Optional so adding it
    /// is a migration-safe Codable change (old persisted clips decode it as `nil`).
    var adjust: ClipAdjust?
    /// Original-audio volume 0…1 (`nil` = full = 1; `0` = muted). Optional → migration-safe; applied
    /// via an `AVAudioMix` in the compositor.
    var volume: Double?

    /// Ken-Burns / zoom scale over the clip's output time (empty = static). Value = scale factor.
    var scaleKeyframes: [StudioKeyframe]

    init(id: UUID = UUID(), sessionMediaID: UUID?, localIdentifier: String, isPhoto: Bool,
         order: Int, trimStart: Double = 0, trimEnd: Double? = nil, speed: Double = 1,
         photoDurationSec: Double = 3,
         cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
         filter: StudioFilter = .none, filterIntensity: Double = 1,
         adjust: ClipAdjust? = nil, volume: Double? = nil,
         scaleKeyframes: [StudioKeyframe] = []) {
        self.id = id
        self.sessionMediaID = sessionMediaID
        self.localIdentifier = localIdentifier
        self.isPhoto = isPhoto
        self.order = order
        self.trimStart = max(0, trimStart)
        self.trimEnd = trimEnd
        self.speed = StudioGeometry.clampSpeed(speed)
        self.photoDurationSec = max(0.1, photoDurationSec)
        self.cropX = cropRect.minX; self.cropY = cropRect.minY
        self.cropWidth = cropRect.width; self.cropHeight = cropRect.height
        self.filterRaw = filter.rawValue
        self.filterIntensity = min(1, max(0, filterIntensity))
        self.adjust = adjust
        self.volume = volume
        self.scaleKeyframes = scaleKeyframes
    }

    var filter: StudioFilter {
        get { StudioFilter(rawValue: filterRaw) ?? .none }
        set { filterRaw = newValue.rawValue }
    }
    var cropRect: CGRect {
        get { CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight) }
        set { cropX = newValue.minX; cropY = newValue.minY; cropWidth = newValue.width; cropHeight = newValue.height }
    }
}

// MARK: - Transitions

/// Transition between two adjacent main-track clips. `none` = a hard cut. Rendered by the
/// compositor as opacity/transform ramps (S3); here it's stored intent + the overlap duration the
/// pure timeline math needs.
enum StudioTransitionKind: String, Codable, Sendable, CaseIterable {
    case none, dissolve, slideLeft, slideRight, zoomIn, fadeThroughBlack
    var display: String { self == .none ? "Cut" : rawValue.capitalized }
}

/// A transition applied *after* a given clip (into the next). `durationSec` is the overlap the two
/// clips share on the output timeline.
struct StudioTransition: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var afterClipID: UUID
    var kindRaw: String
    var durationSec: Double

    init(id: UUID = UUID(), afterClipID: UUID, kind: StudioTransitionKind = .dissolve, durationSec: Double = 0.5) {
        self.id = id
        self.afterClipID = afterClipID
        self.kindRaw = kind.rawValue
        self.durationSec = max(0, durationSec)
    }
    var kind: StudioTransitionKind {
        get { StudioTransitionKind(rawValue: kindRaw) ?? .none }
        set { kindRaw = newValue.rawValue }
    }
}

// MARK: - Overlays

/// An overlay laid over the canvas: text or a sticker/emoji (image overlays + PiP video extend the
/// same shape later). Visible while `startSec ≤ playhead ≤ endSec` (output time); position/opacity
/// can be keyframed. Normalized position is the centre in 0…1 (top-left origin, SwiftUI-style).
struct OverlayItem: Codable, Hashable, Sendable, Identifiable {
    /// `text`/`sticker` are Core-Animation overlays (export-only render); `video` is a
    /// **picture-in-picture** clip composited as a second video track (renders in preview + export).
    enum Kind: String, Codable, Sendable { case text, sticker, video }

    var id: UUID
    var kindRaw: String
    /// Text string, or the sticker's system/asset name.
    var content: String
    var startSec: Double
    var endSec: Double
    var normalizedX: Double, normalizedY: Double
    var scale: Double
    var rotationDegrees: Double
    var opacity: Double
    var colorHex: String
    /// Optional animated position/opacity over output time (value = the relevant scalar).
    var opacityKeyframes: [StudioKeyframe]

    init(id: UUID = UUID(), kind: Kind, content: String, startSec: Double = 0, endSec: Double = 3,
         position: CGPoint = CGPoint(x: 0.5, y: 0.5), scale: Double = 1, rotationDegrees: Double = 0,
         opacity: Double = 1, colorHex: String = "#FFFFFF", opacityKeyframes: [StudioKeyframe] = []) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.content = content
        self.startSec = startSec
        self.endSec = endSec
        self.normalizedX = position.x; self.normalizedY = position.y
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = min(1, max(0, opacity))
        self.colorHex = colorHex
        self.opacityKeyframes = opacityKeyframes
    }
    var kind: Kind { Kind(rawValue: kindRaw) ?? .text }
    var position: CGPoint {
        get { CGPoint(x: normalizedX, y: normalizedY) }
        set { normalizedX = newValue.x; normalizedY = newValue.y }
    }
}

// MARK: - Heart-rate overlay

/// Config for the **heart-rate chart overlay** (the moving-playhead line): the whole session's HR is
/// drawn over the video, a dot tracks the video's progress. Stored optionally on `StudioProject`
/// (nil = off). Position is the chart's centre (0…1, top-left); `scale` is its width as a fraction of
/// the canvas. The HR samples themselves come from the session (not stored here).
struct HROverlayConfig: Codable, Hashable, Sendable {
    var normalizedX: Double
    var normalizedY: Double
    /// Chart width as a fraction of the canvas (height is derived at a fixed chart aspect).
    var scale: Double
    var colorHex: String
    /// Show the live BPM number (preview only — Core Animation can't keyframe text in export).
    var showBPM: Bool
    /// Colour the line/dot by HR zone instead of `colorHex`.
    var zoneColored: Bool

    var position: CGPoint {
        get { CGPoint(x: normalizedX, y: normalizedY) }
        set { normalizedX = newValue.x; normalizedY = newValue.y }
    }
    static let `default` = HROverlayConfig(normalizedX: 0.5, normalizedY: 0.80, scale: 0.86,
                                           colorHex: "#FF3B30", showBPM: true, zoneColored: false)
}

// MARK: - Audio

/// One audio track in the mix. `original` rides a main-track clip's own audio; `music`/`voiceover`
/// are placed on the output timeline at `startSec`. Volume 0…1 with linear fades.
struct AudioTrack: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case original, music, voiceover }

    var id: UUID
    var kindRaw: String
    /// Bundled music name / recorded voiceover file name / source clip id (for original).
    var sourceRef: String
    var startSec: Double
    var volume: Double
    var fadeInSec: Double
    var fadeOutSec: Double

    init(id: UUID = UUID(), kind: Kind, sourceRef: String, startSec: Double = 0,
         volume: Double = 1, fadeInSec: Double = 0, fadeOutSec: Double = 0) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.sourceRef = sourceRef
        self.startSec = max(0, startSec)
        self.volume = min(1, max(0, volume))
        self.fadeInSec = max(0, fadeInSec)
        self.fadeOutSec = max(0, fadeOutSec)
    }
    var kind: Kind { Kind(rawValue: kindRaw) ?? .music }
}

// MARK: - Background

/// The canvas fill behind the (possibly letterboxed) clip. Rendered by the compositor (S2).
enum StudioBackground: String, Codable, Sendable, CaseIterable {
    case black, white, blur
    var display: String { rawValue.capitalized }
}

// MARK: - The project (@Model)

/// The **edit document** for the full studio (S1): a non-destructive, resolution-independent
/// description of a multi-clip timeline — ordered `clips`, `transitions`, `overlays`, `audioTracks`,
/// plus the output canvas (`aspect` + `background`). Generalizes `ClipEdit`: a single trimmed clip
/// is just a one-clip project. Keyed to its `WorkoutSession` by `sessionID` (UUID FK — the suite
/// convention). Nested value types are stored as Codable composites (the `WorkoutSession.exercises`
/// / `ClipEdit.textOverlays` precedent), so adding the model is one `SnappetSchema.models` line.
///
/// The model + the pure `StudioGeometry` math are **platform-free** and unit-tested; turning a
/// project into a playable/exportable `AVComposition` is the device-only `StudioComposer`.
@Model
final class StudioProject {
    var id: UUID
    /// FK to `WorkoutSession.id` (NOT a relationship).
    var sessionID: UUID
    var title: String
    var aspectRaw: String
    var backgroundRaw: String
    var clips: [TimelineClip]
    var transitions: [StudioTransition]
    var overlays: [OverlayItem]
    var audioTracks: [AudioTrack]
    /// Heart-rate chart overlay config (nil = off). Optional → migration-safe additive @Model property.
    var hrOverlay: HROverlayConfig?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), sessionID: UUID, title: String = "Highlight",
         aspect: ClipEditGeometry.OutputAspect = .portrait9x16,
         background: StudioBackground = .black,
         clips: [TimelineClip] = [], transitions: [StudioTransition] = [],
         overlays: [OverlayItem] = [], audioTracks: [AudioTrack] = [],
         hrOverlay: HROverlayConfig? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.aspectRaw = aspect.rawValue
        self.backgroundRaw = background.rawValue
        self.clips = clips
        self.transitions = transitions
        self.overlays = overlays
        self.audioTracks = audioTracks
        self.hrOverlay = hrOverlay
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var aspect: ClipEditGeometry.OutputAspect {
        get { ClipEditGeometry.OutputAspect(rawValue: aspectRaw) ?? .portrait9x16 }
        set { aspectRaw = newValue.rawValue }
    }
    var background: StudioBackground {
        get { StudioBackground(rawValue: backgroundRaw) ?? .black }
        set { backgroundRaw = newValue.rawValue }
    }

    /// Clips in track order (by `order`, ties by `id` for determinism).
    var orderedClips: [TimelineClip] {
        clips.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id.uuidString < $1.id.uuidString }
    }
}
