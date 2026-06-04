import Foundation

/// Output quality for a studio export → an `AVAssetExportSession` preset name. Pure (no AVFoundation
/// import — the preset is a String constant equal to the `AVAssetExportPreset*` raw value); the
/// composer resolves `presetName` to the session. Shown in the editor's top bar (the "4K" affordance).
enum StudioExportQuality: String, CaseIterable, Identifiable, Sendable {
    case hd720, hd1080, uhd4k, highest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K"
        case .highest: return "Max"
        }
    }

    /// Matches the `AVAssetExportPreset*` constant raw values (kept as strings so this stays pure).
    var presetName: String {
        switch self {
        case .hd720: return "AVAssetExportPreset1280x720"
        case .hd1080: return "AVAssetExportPreset1920x1080"
        case .uhd4k: return "AVAssetExportPreset3840x2160"
        case .highest: return "AVAssetExportPresetHighestQuality"
        }
    }
}
