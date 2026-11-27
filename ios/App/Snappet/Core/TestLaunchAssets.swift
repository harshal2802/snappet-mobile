import Foundation

/// The person's Photos library on a test launch (prompt 320): a test may change or delete only the assets it made.
///
/// The in-memory test store keeps the person's DATA out of a test, but their Photos library is the same library.
/// So on a test launch every Photos edge that changes or deletes an asset (bake in place or replace, overwrite,
/// delete, free up space, set a date) asks `mayChange` first, and every asset the app creates (a recording, a
/// photo, a saved video, a bake, a restored copy) is added to the owned list with `noteCreated`. A seed that
/// brings its own Photos assets lists them with `noteCreated` too. The list is in memory, so it starts empty
/// on every launch: anything not made in THIS launch is refused. Media discovery by date (which would attach the
/// person's own footage to a seeded session) keeps only owned assets (`discoverable`). A normal launch is
/// never limited.
enum TestLaunchAssets {
    /// Thrown (or logged) when a test launch tries to change an asset it did not make.
    struct Refused: Error, LocalizedError {
        let localIdentifiers: [String]
        var errorDescription: String? { "A test launch does not change Photos it did not make" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var ownedIDs: Set<String> = []

    /// Every asset this test launch made, so far.
    static var owned: Set<String> { lock.withLock { ownedIDs } }

    static func noteCreated(_ localIdentifier: String?) {
        guard let localIdentifier, UITestStore.onTestLaunch else { return }
        lock.withLock { _ = ownedIDs.insert(localIdentifier) }
    }

    /// Pure: may these assets be changed or deleted? Always on a normal launch; on a test launch only when every
    /// one was made by it. An empty list changes nothing, so it is allowed.
    static func mayChange(_ localIdentifiers: [String], isTestLaunch: Bool, owned: Set<String>) -> Bool {
        !isTestLaunch || localIdentifiers.allSatisfy(owned.contains)
    }

    /// `mayChange` for this launch.
    static func mayChange(_ localIdentifiers: [String]) -> Bool {
        mayChange(localIdentifiers, isTestLaunch: UITestStore.onTestLaunch, owned: owned)
    }

    /// Throws `Refused` unless `mayChange`.
    static func requireMayChange(_ localIdentifiers: [String]) throws {
        guard mayChange(localIdentifiers) else { throw Refused(localIdentifiers: localIdentifiers) }
    }

    /// Pure: which discovered assets may be attached to a session. On a test launch only owned ones.
    static func discoverable(_ localIdentifiers: [String], isTestLaunch: Bool, owned: Set<String>) -> [String] {
        isTestLaunch ? localIdentifiers.filter(owned.contains) : localIdentifiers
    }

    /// `discoverable` for this launch.
    static func discoverable(_ localIdentifiers: [String]) -> [String] {
        discoverable(localIdentifiers, isTestLaunch: UITestStore.onTestLaunch, owned: owned)
    }

    /// One identifier: `discoverable` for this launch.
    static func isDiscoverable(_ localIdentifier: String) -> Bool {
        !UITestStore.onTestLaunch || owned.contains(localIdentifier)
    }
}
