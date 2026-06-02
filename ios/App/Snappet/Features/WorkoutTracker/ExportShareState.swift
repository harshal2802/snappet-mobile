import Foundation

/// The pure state machine for the B5 "export → share / save to Photos" flow, shared by the B3 clip
/// editor (`ClipEditorViewModel`) and the B4 highlight reel (`SessionHighlightViewModel`). Modelled
/// as a value type with a reducer so the transitions are **unit-testable with no AVFoundation /
/// PhotoKit / UIKit** (the device-only export/save/share themselves are not — but the state logic
/// that drives the UI is). Mirrors the suite's "isolate the pure logic" discipline (`ClipEditGeometry`,
/// `WorkoutHRStats`).
///
/// The exported file `URL` is carried through `.exported` so the share sheet and the save action both
/// reuse the one render — exporting once, then sharing and/or saving that same file.
enum ExportShareState: Equatable {
    /// Nothing exported yet.
    case idle
    /// An `AVAssetExportSession` is running.
    case exporting
    /// The video rendered to `url`; share + "Save to Photos" act on it.
    case exported(URL)
    /// A save to Photos is in flight for `url` (export already succeeded).
    case saving(URL)
    /// The video was saved to the Photos library.
    case saved(URL)
    /// Export or save failed with a user-facing message.
    case failed(String)

    /// The rendered file, if one exists (so a save/share can reuse the single export).
    var exportedURL: URL? {
        switch self {
        case .exported(let url), .saving(let url), .saved(let url): return url
        case .idle, .exporting, .failed: return nil
        }
    }

    /// Whether work (export or save) is currently in flight — the UI disables actions while true.
    var isBusy: Bool {
        switch self {
        case .exporting, .saving: return true
        case .idle, .exported, .saved, .failed: return false
        }
    }

    // MARK: - Transitions (pure)

    /// Begin an export. Always valid (re-exporting from any state is allowed).
    func beginningExport() -> ExportShareState { .exporting }

    /// Export finished with a rendered file.
    func exportSucceeded(_ url: URL) -> ExportShareState { .exported(url) }

    /// Begin saving the already-exported file. Only valid when a file exists; otherwise unchanged.
    func beginningSave() -> ExportShareState {
        guard let url = exportedURL else { return self }
        return .saving(url)
    }

    /// The save to Photos finished.
    func saveSucceeded() -> ExportShareState {
        guard let url = exportedURL else { return self }
        return .saved(url)
    }

    /// Export or save failed.
    func failed(_ message: String) -> ExportShareState { .failed(message) }
}
