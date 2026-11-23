import Foundation

/// The pure state machine for the B5 "export → share / save to Photos" flow, shared by the multi-clip
/// Studio export (`StudioEditorViewModel`; the B4 highlight sheet used it too before the
/// highlights convergence folded that flow into the shared `ReelViewModel`). Modelled
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
    /// An `AVAssetExportSession` is running. `progress` is the fraction done, 0…1 (prompt 298);
    /// it stays 0 while the composition is being built, before the session reports anything.
    case exporting(progress: Double)
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
    func beginningExport() -> ExportShareState { .exporting(progress: 0) }

    /// The running export reported `fraction` done. Only an export in flight takes it (a late report
    /// after a cancel, a failure or a finish changes nothing). The value is held to 0…1 and never
    /// moves backwards, so the bar cannot jump back.
    func exportProgressed(_ fraction: Double) -> ExportShareState {
        guard case .exporting(let current) = self, fraction.isFinite else { return self }
        return .exporting(progress: max(current, min(max(fraction, 0), 1)))
    }

    /// The user cancelled the running export: back to idle, with no message. Any other state is
    /// unchanged (a cancel that arrives after the export ended must not drop its result).
    func exportCancelled() -> ExportShareState {
        guard case .exporting = self else { return self }
        return .idle
    }

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

    /// The share sheet for the rendered file was closed: the file has been handed over, so the flow
    /// is over. A save in flight still needs the file and is left alone.
    func shareDismissed() -> ExportShareState {
        switch self {
        case .exported, .saved: return .idle
        case .idle, .exporting, .saving, .failed: return self
        }
    }

    /// The user closed the failure message.
    func failureAcknowledged() -> ExportShareState {
        guard case .failed = self else { return self }
        return .idle
    }

    // MARK: - Progress and temp-file ownership (pure, prompt 298)

    /// The fraction done while an export runs, else `nil`.
    var exportProgress: Double? {
        guard case .exporting(let progress) = self else { return nil }
        return progress
    }

    /// The whole percent shown next to the bar ("42%"), rounded down so 100 appears only when the
    /// session reports it is done.
    var exportPercentLabel: String? {
        exportProgress.map { "\(Int(($0 * 100).rounded(.down)))%" }
    }

    /// The rendered temp file this state holds and `next` no longer does: the caller deletes it on
    /// that transition. A new export, a closed share sheet, a failure and a closed Studio all drop
    /// the file; moving between exported / saving / saved keeps it.
    func fileToDelete(movingTo next: ExportShareState) -> URL? {
        guard let url = exportedURL, next.exportedURL != url else { return nil }
        return url
    }
}
