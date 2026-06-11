import Foundation
import Observation

/// Launch-time health of the shared SwiftData store (issue #68). `SnappetApp` records
/// here whether the persistent store opened, or whether the app silently fell back to an
/// empty **in-memory** container (the previously-invisible corrupt-store branch) —
/// `StoreHealthBanner` renders the non-`ok` states so a broken store is never a silent
/// blank app again.
@MainActor
@Observable
final class StoreHealth {
    enum Mode: Equatable {
        /// The persistent store opened normally (or a test arg requested a fresh
        /// in-memory store on purpose — that's healthy, not a fallback).
        case ok
        /// The on-disk store couldn't be opened; the app is running on an empty
        /// in-memory container. Nothing done in this state survives a relaunch.
        case fallbackInMemory
        /// The user reset the broken store from the banner: the files are gone, but the
        /// app is still on the in-memory container until they quit and reopen.
        case resetDone
    }

    var mode: Mode

    init(mode: Mode = .ok) {
        self.mode = mode
    }
}

/// The recovery action behind the banner's Reset: delete the unreadable on-disk store
/// files so the **next** launch creates a fresh, working store (the running app stays on
/// its in-memory container — a `ModelContainer` can't be swapped under live views without
/// stranding everything built on its contexts, see decisions.md 2026-06-10).
///
/// URL derivation is pure (unit-tested); only the actual deletion touches the disk.
enum StoreRecovery {
    /// SwiftData's default store + its SQLite sidecars, as created by
    /// `ModelContainer(for:)` with the default `ModelConfiguration`.
    static let storeFilenames = ["default.store", "default.store-shm", "default.store-wal"]

    static func storeURLs(in directory: URL) -> [URL] {
        storeFilenames.map { directory.appending(path: $0) }
    }

    /// Remove the store files (missing ones are skipped). Throws on a real deletion
    /// failure so the banner can tell the user instead of pretending it worked.
    static func resetPersistentStore(
        in directory: URL = .applicationSupportDirectory,
        fileManager: FileManager = .default
    ) throws {
        for url in storeURLs(in: directory) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
