import Foundation

/// Where a test launch keeps the files it would otherwise write into the person's Application Support (prompt 320).
///
/// The in-memory store keeps a test out of the person's data, but some data is plain files: the highlight
/// feedback log (`highlight-feedback.jsonl`, read back to tune the reel builder), reel exports (swept by age),
/// the exercise guide photo pack. On a test launch each lives under `tmp/uitest-files/<name>` instead, so a
/// test neither reads nor changes the person's copy. A normal launch gets Application Support, as before.
enum TestLaunchFiles {
    /// The scratch root for this simulator / phone's test launches.
    static var scratchRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("uitest-files", isDirectory: true)
    }

    /// Pure: the directory for `name` — scratch on a test launch, else `name` under `support`.
    static func directory(_ name: String, isTestLaunch: Bool, support: URL?) -> URL {
        if isTestLaunch { return scratchRoot.appendingPathComponent(name, isDirectory: true) }
        return (support ?? FileManager.default.temporaryDirectory).appendingPathComponent(name, isDirectory: true)
    }

    /// Application Support (created if needed), or this launch's scratch root on a test launch.
    static func supportDirectory(isTestLaunch: Bool = UITestStore.onTestLaunch) -> URL {
        if isTestLaunch {
            try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
            return scratchRoot
        }
        return (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }
}
