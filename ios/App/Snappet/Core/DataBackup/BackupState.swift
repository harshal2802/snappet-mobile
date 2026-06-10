import Foundation

/// Pure state machine for the backup / restore / per-module export flow.
/// Mirrors the `ExportShareState` discipline: value type, pure transitions,
/// unit-testable without any platform I/O.
enum BackupState: Equatable {
    /// Nothing in progress.
    case idle
    /// Fetching all model snapshots from the store in preparation for export.
    case preparingBundle
    /// Bundle is ready; the file exporter can be shown.
    case bundleReady(Data, String) // (json data, suggested filename)
    /// A file was imported and records are being written into the store.
    case restoring
    /// Restore succeeded; `count` is the total number of records written.
    case restored(Int)
    /// Preparing or restoring failed with a user-facing message.
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparingBundle, .restoring: return true
        case .idle, .bundleReady, .restored, .failed: return false
        }
    }

    var bundleData: Data? {
        if case .bundleReady(let data, _) = self { return data }
        return nil
    }

    var bundleFilename: String? {
        if case .bundleReady(_, let name) = self { return name }
        return nil
    }

    // MARK: - Pure transitions

    func beginningPreparation() -> BackupState { .preparingBundle }

    func bundleReady(data: Data, filename: String) -> BackupState {
        .bundleReady(data, filename)
    }

    func beginningRestore() -> BackupState { .restoring }

    func restoreSucceeded(recordCount: Int) -> BackupState { .restored(recordCount) }

    func failed(_ message: String) -> BackupState { .failed(message) }

    func reset() -> BackupState { .idle }
}
