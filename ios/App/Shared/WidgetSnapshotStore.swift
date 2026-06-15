import Foundation

/// The one place that knows where the Today snapshot lives: the App-Group id and file name, the
/// pure codec, and the thin file edge over the shared container (#81 Phase 1).
///
/// Split on purpose: `encode`/`decode` are **pure** and unit-tested (no device); `read`/`write`
/// touch the App-Group container, which only fully provisions on a real device — so they degrade
/// gracefully (`nil` / no-op) when the container is unavailable, and aren't unit-tested.
enum WidgetSnapshotStore {
    /// Must match `com.apple.security.application-groups` in BOTH the app's and the widget's
    /// entitlements (project.yml). Changing it requires re-registering the group under the signing
    /// team in the developer portal for device builds.
    static let appGroupID = "group.com.snappet.app"
    static let fileName = "today-widget-snapshot.json"

    // MARK: - Pure codec (unit-tested)

    static func encode(_ snapshot: SnappetWidgetSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot, or `nil` when the bytes are corrupt OR were written by a NEWER contract
    /// version than this binary understands (can't be trusted — the widget shows its placeholder).
    /// Older writers' missing fields are tolerated by `SnappetWidgetSnapshot`'s defaulting decoder.
    static func decode(_ data: Data) -> SnappetWidgetSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(SnappetWidgetSnapshot.self, from: data),
              snapshot.version <= SnappetWidgetSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    // MARK: - File edge (App-Group container — device-pending)

    /// The shared container, or `nil` if the App-Group entitlement isn't provisioned (e.g. a build
    /// without the group registered). Callers treat `nil` as "no snapshot available".
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var fileURL: URL? { containerURL?.appendingPathComponent(fileName) }

    /// Atomically write the snapshot. No-op (silently) if the container is unavailable — a missing
    /// snapshot just means the widget renders its placeholder, never a crash.
    static func write(_ snapshot: SnappetWidgetSnapshot) {
        guard let fileURL, let data = try? encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Read the current snapshot, or `nil` when none has been written / the container is unavailable
    /// / the bytes are corrupt or from a future version.
    static func read() -> SnappetWidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return decode(data)
    }
}
