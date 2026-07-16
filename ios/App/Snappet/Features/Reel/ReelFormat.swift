import Foundation
import HighlightEngine

// MARK: - Highlights convergence (workout-reels-v2 P1) — pure export-format + intensity logic
//
// The reel builder's format presets and the per-highlight intensity badge math. PURE — Foundation +
// engine value types only — so both unit-test in `SnappetTests` with no simulator
// (`ReelFormatTests`). The AVFoundation edge (`ReelExporter`) consumes only the resolved
// `aspect` value; the view consumes only the badge numbers.

/// The export canvas preset the reel builder offers (wireframes:
/// docs/ux-research/workout-reels-v2). `native` keeps today's behavior — the canvas is the first
/// segment's oriented size. The fixed presets force a canvas aspect (width / height) and letterbox
/// every segment into it via the exporter's existing aspect-fit transform, so a mixed-orientation
/// cut ships in a share-ready frame (9:16 story, 4:5 portrait, 1:1 square).
enum ReelFormat: String, CaseIterable, Identifiable, Sendable {
    case native, story, portrait, square

    var id: String { rawValue }

    /// Canvas aspect (width / height); `nil` = native (first segment decides).
    var aspect: Double? {
        switch self {
        case .native:   return nil
        case .story:    return 9.0 / 16.0
        case .portrait: return 4.0 / 5.0
        case .square:   return 1.0
        }
    }

    /// Chip label. "Native" names the default honestly instead of pretending it's an aspect.
    var label: String {
        switch self {
        case .native:   return "Native"
        case .story:    return "9:16"
        case .portrait: return "4:5"
        case .square:   return "1:1"
        }
    }
}

/// Per-highlight intensity for the builder's clip rows: the peak BPM inside the highlight's
/// clip window, and its %HRR fraction for the performance-ramp tint (`SnappetColor.performance`).
/// Makes the engine's invisible HR ranking *visible* in the edit list.
enum ReelIntensity {

    /// Fallbacks when the workout carries no profile values — the same defaults the HR zone
    /// system uses (`HeartRateZone.defaultMaxHR`) and the conventional resting baseline.
    static let defaultMaxBpm = 190.0
    static let defaultRestBpm = 60.0

    /// Highest BPM sampled inside `[start, end]` on the workout timeline; `nil` when no sample
    /// lands in the window (no HR captured there — the row falls back to the engine score).
    static func peakBpm(hr: [HRSample], start: Double, end: Double) -> Double? {
        guard start <= end else { return nil }
        return hr.lazy.filter { $0.t >= start && $0.t <= end }.map(\.bpm).max()
    }

    /// A peak's heart-rate-reserve fraction (Karvonen), clamped to 0…1 — the input
    /// `SnappetColor.performance(for:)` maps onto the fresh → moderate → hard ramp.
    static func fraction(peakBpm: Double, restBpm: Double?, maxBpm: Double?) -> Double {
        let rest = restBpm ?? defaultRestBpm
        let max_ = maxBpm ?? defaultMaxBpm
        guard max_ > rest else { return 0 }
        return min(1, max(0, (peakBpm - rest) / (max_ - rest)))
    }
}
