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
/// resolution-independent (seconds / normalized 0…1). `order` sequences the track; **split** = two
/// clips with adjacent trims (same `order` neighbours).
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

/// Font preset for a text / climb-name overlay. Maps to a SwiftUI `Font.Design` (preview) and a
/// `UIFontDescriptor` design (export) so the same choice renders identically in both. Pure enum.
enum StudioFont: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
}

/// An overlay laid over the canvas: text or a sticker/emoji (image overlays + PiP video extend the
/// same shape later). Visible while `startSec ≤ playhead ≤ endSec` (output time); position/opacity
/// can be keyframed. Normalized position is the centre in 0…1 (top-left origin, SwiftUI-style).
struct OverlayItem: Codable, Hashable, Sendable, Identifiable {
    /// `text`/`sticker`/`climbName` are Core-Animation overlays (export-only render); `video` is a
    /// **picture-in-picture** clip composited as a second video track (renders in preview + export).
    /// `climbName` renders like text but as a styled lower-third chip, auto-filled from the clip's
    /// assigned climb (name · grade · angle, optionally the setter) — the text stays freely editable.
    enum Kind: String, Codable, Sendable { case text, sticker, video, climbName }

    var id: UUID
    var kindRaw: String
    /// Text string, or the sticker's system/asset name.
    var content: String
    var startSec: Double
    var endSec: Double
    var normalizedX: Double, normalizedY: Double
    var scale: Double
    /// PiP (`.video`) **per-axis** frame size as a fraction of the canvas (0…1). `nil` falls back to
    /// the uniform `scale` (the pre-grid behaviour), so old projects decode unchanged; grid layouts +
    /// corner-resize write these to make true split-screen cells possible.
    var normalizedWidth: Double? = nil
    var normalizedHeight: Double? = nil
    var rotationDegrees: Double
    var opacity: Double
    /// The **clip this overlay belongs to** (its `TimelineClip.id`). For a `.climbName` lower-third this
    /// makes the tag a true **per-clip property**: its on-screen window is RESOLVED at render time from
    /// the clip's current placed slot (so trim/reorder/split never desync), it's idempotent per clip
    /// (one tag per clip), and it's garbage-collected when its clip is deleted. `nil` = a whole-project
    /// overlay (text/sticker, or a climb tag added with no clip selected). Additive + optional →
    /// migration-safe (old projects decode `nil`), the same convention as `highlightHex`/`fontRaw` below.
    var clipID: UUID? = nil
    /// Whether this climb-name tag renders an **"Attempt N"** line (prompt 10/11) — the number is
    /// `attemptNumber`. Persisted (was a transient in-memory Set) so the toggle survives reopen/undo and
    /// the rendered string composes from `content` (the base caption) + these flags. Stored as an
    /// **optional raw** (`nil` → `false` via the `showsAttempt` accessor below) because Swift's
    /// synthesized `Decodable` throws `keyNotFound` for a missing NON-optional key — it does NOT fall back
    /// to a property default. Optional → old persisted overlays decode unchanged (the `boldRaw` precedent).
    var showsAttemptRaw: Bool? = nil
    /// The 1-based attempt number the "Attempt N" line shows (the owning clip's attempt). `nil` when no
    /// attempt resolves. Stored so the composed string is re-derivable without re-parsing `content`.
    var attemptNumber: Int? = nil
    /// Whether this climb-name tag appends the setter (` · by {setter}`). Persisted flag (was a transient
    /// Set) so the composed string is robust across reopen/undo and never wipes a manual caption edit.
    /// Optional raw (`nil` → `false`) for the same migration-safe reason as `showsAttemptRaw`. Only
    /// meaningful for a Kilter climb.
    var showsSetterRaw: Bool? = nil
    /// Text colour (hex). For text/sticker/climb-name overlays.
    var colorHex: String
    /// Optional **highlight / background** colour (hex) behind a text/climb-name overlay. `nil` = no
    /// background. Additive + optional → migration-safe (old projects decode `nil`). Climb-name seeds a
    /// dark default so its lower-third chip is unchanged.
    var highlightHex: String? = nil
    /// Rich-text style, stored as **optionals** so old persisted overlays (missing these keys) still
    /// decode — Swift's synthesized `Decodable` throws `keyNotFound` for a missing NON-optional key, it
    /// does NOT fall back to a property default. The non-optional `font`/`bold`/`italic` accessors below
    /// apply the defaults. `fontRaw` nil → `.system`; `boldRaw` nil → bold; `italicRaw` nil → not italic.
    var fontRaw: String? = nil
    var boldRaw: Bool? = nil
    var italicRaw: Bool? = nil
    /// Optional animated position/opacity over output time (value = the relevant scalar).
    var opacityKeyframes: [StudioKeyframe]

    init(id: UUID = UUID(), kind: Kind, content: String, startSec: Double = 0, endSec: Double = 3,
         position: CGPoint = CGPoint(x: 0.5, y: 0.5), scale: Double = 1,
         normalizedWidth: Double? = nil, normalizedHeight: Double? = nil, rotationDegrees: Double = 0,
         opacity: Double = 1, clipID: UUID? = nil,
         showsAttempt: Bool = false, attemptNumber: Int? = nil, showsSetter: Bool = false,
         colorHex: String = "#FFFFFF", highlightHex: String? = nil,
         font: StudioFont = .system, bold: Bool = true, italic: Bool = false,
         opacityKeyframes: [StudioKeyframe] = []) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.content = content
        self.startSec = startSec
        self.endSec = endSec
        self.normalizedX = position.x; self.normalizedY = position.y
        self.scale = scale
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.rotationDegrees = rotationDegrees
        self.opacity = min(1, max(0, opacity))
        self.clipID = clipID
        self.showsAttemptRaw = showsAttempt
        self.attemptNumber = attemptNumber
        self.showsSetterRaw = showsSetter
        self.colorHex = colorHex
        self.highlightHex = highlightHex
        self.fontRaw = font.rawValue
        self.boldRaw = bold
        self.italicRaw = italic
        self.opacityKeyframes = opacityKeyframes
    }
    var kind: Kind { Kind(rawValue: kindRaw) ?? .text }
    var font: StudioFont {
        get { StudioFont(rawValue: fontRaw ?? "") ?? .system }
        set { fontRaw = newValue.rawValue }
    }
    /// Bold defaults ON (matches the prior semibold look) for overlays saved before the style fields.
    var bold: Bool {
        get { boldRaw ?? true }
        set { boldRaw = newValue }
    }
    var italic: Bool {
        get { italicRaw ?? false }
        set { italicRaw = newValue }
    }
    /// `showsAttempt` / `showsSetter` default OFF (`nil` raw) — old overlays carry the legacy behaviour
    /// (no system "Attempt N" / setter line) and decode without `keyNotFound`.
    var showsAttempt: Bool {
        get { showsAttemptRaw ?? false }
        set { showsAttemptRaw = newValue }
    }
    var showsSetter: Bool {
        get { showsSetterRaw ?? false }
        set { showsSetterRaw = newValue }
    }
    var position: CGPoint {
        get { CGPoint(x: normalizedX, y: normalizedY) }
        set { normalizedX = newValue.x; normalizedY = newValue.y }
    }
    /// The PiP frame size (width, height) as fractions of the canvas — per-axis when set, else the
    /// uniform `scale` on both axes (back-compatible default).
    var pipSize: CGSize {
        get { CGSize(width: normalizedWidth ?? scale, height: normalizedHeight ?? scale) }
        set { normalizedWidth = newValue.width; normalizedHeight = newValue.height }
    }
}

// MARK: - Base-video frame (collage)

/// A normalized **centre + size** frame (fractions of the canvas, 0…1) used to place the **main
/// video track** into a sub-rect of the canvas — so the original footage can become one cell of a
/// collage alongside picture-in-picture clips, instead of always filling the whole frame. `nil` on a
/// project means the legacy full-frame behaviour. Same convention as a PiP frame (`pipRect`), so the
/// composer reuses `ClipEditGeometry.fillTransform` for both. The canvas `background` shows behind it.
struct StudioFrameRect: Codable, Hashable, Sendable {
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double

    init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.centerX = min(1, max(0, centerX))
        self.centerY = min(1, max(0, centerY))
        self.width = min(1, max(0.1, width))
        self.height = min(1, max(0.1, height))
    }

    var center: CGPoint {
        get { CGPoint(x: centerX, y: centerY) }
        set { centerX = min(1, max(0, newValue.x)); centerY = min(1, max(0, newValue.y)) }
    }
    var size: CGSize {
        get { CGSize(width: width, height: height) }
        set { width = min(1, max(0.1, newValue.width)); height = min(1, max(0.1, newValue.height)) }
    }
    /// True when the frame is (effectively) the whole canvas — treated as "no framing".
    var isFull: Bool { width >= 0.999 && height >= 0.999 }

    /// The default a user gets when first enabling base framing: a centred half-height cell (so a PiP
    /// can share the other half).
    static let half = StudioFrameRect(centerX: 0.5, centerY: 0.27, width: 1, height: 0.5)
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
    /// Draw the moving-playhead chart line itself. `false` keeps the overlay active for the
    /// `elements` (numbers/badges) while hiding the chart — so the user can pick numbers without it
    /// (prompt 28). Defaults `true` (the pre-feature behaviour: an active overlay == a chart).
    var showChart: Bool
    /// Extra HR/fitness **overlay elements** the user picked beyond the chart (numbers + badges) —
    /// the configurable overlay builder (prompt 28). **Legacy** once `tile` is set: kept read-only so
    /// old persisted projects still decode and `HRTileMigration` can fold them into the tile (zero
    /// data loss); never written once a tile exists.
    var elements: [HROverlayElement]
    /// The unified, resizable HR stat **tile** (the redesign). `nil` = legacy free-floating
    /// `elements` / chart-only / off. When set, the tile owns layout and the standalone chart renders
    /// only if `tile.showChart`. Optional → migration-safe additive field (old blobs decode `nil`).
    var tile: HRTile?

    init(normalizedX: Double, normalizedY: Double, scale: Double, colorHex: String,
         showBPM: Bool, zoneColored: Bool, showChart: Bool = true,
         elements: [HROverlayElement] = [], tile: HRTile? = nil) {
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.scale = scale
        self.colorHex = colorHex
        self.showBPM = showBPM
        self.zoneColored = zoneColored
        self.showChart = showChart
        self.elements = elements
        self.tile = tile
    }

    private enum CodingKeys: String, CodingKey {
        case normalizedX, normalizedY, scale, colorHex, showBPM, zoneColored, showChart, elements, tile
    }

    /// Custom decode so blobs persisted **before** `showChart`/`elements`/`tile` existed still load —
    /// synthesized `Codable` would throw on the missing keys (they're non-optional). Missing →
    /// `showChart = true` (the old "active overlay = chart" behaviour), no extra `elements`, no `tile`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        normalizedX = try c.decode(Double.self, forKey: .normalizedX)
        normalizedY = try c.decode(Double.self, forKey: .normalizedY)
        scale = try c.decode(Double.self, forKey: .scale)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        showBPM = try c.decode(Bool.self, forKey: .showBPM)
        zoneColored = try c.decode(Bool.self, forKey: .zoneColored)
        showChart = try c.decodeIfPresent(Bool.self, forKey: .showChart) ?? true
        elements = try c.decodeIfPresent([HROverlayElement].self, forKey: .elements) ?? []
        // SwiftData's composite coder materializes a `nil` nested-optional Codable struct as an empty
        // value rather than absent (so `decodeIfPresent` returns a content-empty `HRTile` with a fresh
        // `UUID()` id — nondeterministic, and it would wrongly block legacy migration). A real tile
        // ALWAYS carries all metric entries, so an entries-empty tile is that phantom → normalize to nil.
        let decodedTile = try c.decodeIfPresent(HRTile.self, forKey: .tile)
        tile = (decodedTile?.entries.isEmpty ?? true) ? nil : decodedTile
    }

    var position: CGPoint {
        get { CGPoint(x: normalizedX, y: normalizedY) }
        set { normalizedX = newValue.x; normalizedY = newValue.y }
    }
    static let `default` = HROverlayConfig(normalizedX: 0.5, normalizedY: 0.80, scale: 0.86,
                                           colorHex: "#FF3B30", showBPM: true, zoneColored: false)
}

/// A heart-rate / fitness metric the user can place on a clip as an overlay element (prompt 28).
/// `supportsLive` = the value changes over the clip (so it can track the playhead); `supportsAnimation`
/// = it can be animated in the **export** (the chart's dot, or a live number via opacity keyframes —
/// a static aggregate has nothing to animate). Aggregates (avg/max/redline/strain/HRV/calories) are
/// single clip-window values → static only.
enum HROverlayMetric: String, Codable, CaseIterable, Sendable, Identifiable {
    case bpm            // live heart rate (♥ 168)
    case zone           // training-zone pill (Z3 · Aerobic)
    case hrr            // % heart-rate reserve
    case avgHR          // clip average HR
    case maxHR          // clip peak HR
    case redline        // Z4+Z5 time as a % of the clip
    case strain         // Edwards zone-weighted training load (TRIMP)
    case hrv            // RMSSD (ms) over the clip window (chest-strap RR only)
    case calories       // HR-based energy estimate (kcal) — needs a profile
    case recovery       // recovery-ready state (rested for the next effort)

    var id: String { rawValue }

    /// Short human label for the builder list.
    var label: String {
        switch self {
        case .bpm: return "Heart rate"
        case .zone: return "Zone"
        case .hrr: return "% effort (HRR)"
        case .avgHR: return "Average HR"
        case .maxHR: return "Peak HR"
        case .redline: return "Redline"
        case .strain: return "Strain"
        case .hrv: return "HRV"
        case .calories: return "Calories"
        case .recovery: return "Recovery"
        }
    }

    /// SF Symbol for the builder row.
    var systemImage: String {
        switch self {
        case .bpm, .avgHR, .maxHR: return "heart.fill"
        case .zone, .hrr: return "speedometer"
        case .redline, .strain: return "flame.fill"
        case .hrv: return "waveform.path.ecg"
        case .calories: return "bolt.fill"
        case .recovery: return "checkmark.circle.fill"
        }
    }

    /// A one-line plain-English explanation of what the metric is — shown under each toggle in the
    /// builder so the user knows what they're putting on the video and what it means.
    var explanation: String {
        switch self {
        case .bpm:      return "Your live heart rate, in beats per minute."
        case .zone:     return "Training zone Z1–Z5, by how hard you're working (% of max HR)."
        case .hrr:      return "Effort as a % of your heart-rate reserve (resting → max)."
        case .avgHR:    return "Average heart rate over this clip."
        case .maxHR:    return "Peak heart rate reached in this clip."
        case .redline:  return "Share of the clip spent in the hardest zones (Z4–Z5)."
        case .strain:   return "Training load — time weighted by how hard each zone is."
        case .hrv:      return "Heart-rate variability (RMSSD) — a recovery/stress signal (chest strap only)."
        case .calories: return "Estimated energy burned this clip, in kcal (needs your profile)."
        case .recovery: return "Whether your heart rate has settled enough for the next hard effort."
        }
    }

    /// Whether the metric varies over the clip (can track the playhead / be "live").
    var supportsLive: Bool {
        switch self {
        case .bpm, .zone, .hrr, .recovery: return true
        case .avgHR, .maxHR, .redline, .strain, .hrv, .calories: return false
        }
    }

    /// Whether the metric can be **animated in the export** — only live (time-varying) metrics can
    /// (via per-value opacity keyframes); aggregates are fixed text.
    var supportsAnimation: Bool { supportsLive }
}

/// One placed HR/fitness overlay element (prompt 28): which metric, whether it tracks the playhead
/// (`live`) and whether it animates in the export (`animated`, only meaningful for live metrics),
/// plus its position/scale/colour. `Codable` composite stored in `HROverlayConfig.elements`.
struct HROverlayElement: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var metricRaw: String
    /// Track the playhead (a live, changing reading) vs. a single clip-window value. Forced `false`
    /// for metrics that don't support live.
    var live: Bool = false
    /// Animate the live reading in the exported file (opacity-keyframed per value). Ignored unless the
    /// metric is live + supports animation; the preview always animates a live element.
    var animated: Bool = false
    var normalizedX: Double = 0.5
    var normalizedY: Double = 0.5
    /// Text size as a fraction of the canvas height.
    var scale: Double = 1.0
    var colorHex: String = "#FFFFFF"

    var metric: HROverlayMetric { HROverlayMetric(rawValue: metricRaw) ?? .bpm }
    /// `live` only where the metric supports it; `animated` only where live + animatable.
    var isLive: Bool { metric.supportsLive && live }
    var isAnimated: Bool { isLive && metric.supportsAnimation && animated }

    var position: CGPoint {
        get { CGPoint(x: normalizedX, y: normalizedY) }
        set { normalizedX = newValue.x; normalizedY = newValue.y }
    }

    init(metric: HROverlayMetric, normalizedX: Double = 0.5, normalizedY: Double = 0.5,
         scale: Double = 1.0, colorHex: String = "#FFFFFF") {
        self.metricRaw = metric.rawValue
        self.live = metric.supportsLive          // default a time-varying metric to live
        self.animated = metric.supportsAnimation // …and animated, since that reads best
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.scale = scale
        self.colorHex = colorHex
    }
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
/// plus the output canvas (`aspect` + `background`); a single trimmed clip is just a one-clip
/// project. Keyed to its `WorkoutSession` by `sessionID` (UUID FK — the suite convention). Nested
/// value types are stored as Codable composites (the `WorkoutSession.exercises` precedent).
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
    /// Frame the **main video** into a sub-rect of the canvas (collage). `nil` = fill the whole frame
    /// (legacy). Optional → migration-safe additive @Model property.
    var baseFrame: StudioFrameRect?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), sessionID: UUID, title: String = "Highlight",
         aspect: ClipEditGeometry.OutputAspect = .portrait9x16,
         background: StudioBackground = .black,
         clips: [TimelineClip] = [], transitions: [StudioTransition] = [],
         overlays: [OverlayItem] = [], audioTracks: [AudioTrack] = [],
         hrOverlay: HROverlayConfig? = nil, baseFrame: StudioFrameRect? = nil,
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
        self.baseFrame = baseFrame
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
