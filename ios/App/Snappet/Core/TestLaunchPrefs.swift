import Foundation

/// The person's settings survive a UI-test launch on their phone (prompt 320).
///
/// A test launch swaps SwiftData for an in-memory store, but settings live in `UserDefaults`, which it does
/// not isolate: `SnappetApp.init` clears ~20 keys so each test starts the same, tests flip switches, and
/// on 2026-11-26 a device run lost the person's Clips grid size, feed level, recent grades and gyms.
///
/// So, on a phone: the FIRST test launch saves the app's settings and the App Group's settings to a snapshot
/// file in Library before anything touches them; later test launches keep that first snapshot and change
/// settings freely; the next NORMAL launch puts both back exactly and deletes the snapshot, before any other
/// code reads a setting. A snapshot of any age restores. On the simulator this is off (`atLaunch`), so
/// simulator runs and the shared unit-test host keep today's behaviour.
///
/// The decision (`step`) and the save/restore (`run`) are pure over injected domains and a file URL, and
/// unit-tested without a device.
enum TestLaunchPrefs {
    /// What this launch does with the snapshot.
    enum Step: Equatable {
        case snapshot        // test launch, no snapshot yet: save the real settings first
        case keepSnapshot    // test launch, a snapshot exists: it holds the real settings, keep it
        case restore         // normal launch, a snapshot exists: put the real settings back
        case none            // normal launch, nothing saved
    }

    /// What happened, for the test-launch read-out (`TestLaunchIsolation.readOut`).
    enum Outcome: String, Equatable {
        case saved, kept, restored, notNeeded
        case offOnSimulator = "off (simulator)"
        case failed
    }

    static func step(isTestLaunch: Bool, snapshotExists: Bool) -> Step {
        switch (isTestLaunch, snapshotExists) {
        case (true, false): return .snapshot
        case (true, true): return .keepSnapshot
        case (false, true): return .restore
        case (false, false): return .none
        }
    }

    /// One settings domain the snapshot covers: read its whole persistent domain, or replace it (`nil` removes it).
    struct Domain {
        let name: String
        let read: () -> [String: Any]?
        let write: ([String: Any]?) -> Void

        /// A `UserDefaults` persistent domain by name (the app's bundle id, or an App Group suite).
        static func defaults(_ defaults: UserDefaults, name: String) -> Domain {
            Domain(name: name,
                   read: { defaults.persistentDomain(forName: name) },
                   write: { value in
                       if let value, !value.isEmpty { defaults.setPersistentDomain(value, forName: name) }
                       else { defaults.removePersistentDomain(forName: name) }
                   })
        }
    }

    static let formatVersion = 1

    /// Saves, keeps or restores the snapshot at `file` for `domains`. Returns what it did.
    @discardableResult
    static func run(isTestLaunch: Bool, domains: [Domain], file: URL, now: Date = .now,
                    fileManager: FileManager = .default) -> Outcome {
        switch step(isTestLaunch: isTestLaunch, snapshotExists: fileManager.fileExists(atPath: file.path)) {
        case .none:
            return .notNeeded
        case .keepSnapshot:
            return .kept
        case .snapshot:
            var saved: [String: Any] = [:]
            for domain in domains { saved[domain.name] = domain.read() ?? [:] }
            let plist: [String: Any] = ["version": formatVersion, "savedAt": now, "domains": saved]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return .saved
            } catch {
                return .failed
            }
        case .restore:
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let saved = plist["domains"] as? [String: Any] else {
                try? fileManager.removeItem(at: file)   // unreadable: nothing to put back, and never retry it
                return .failed
            }
            for domain in domains {
                // A domain the snapshot does not name is left alone (a newer build may cover more).
                guard let value = saved[domain.name] as? [String: Any] else { continue }
                domain.write(value)
            }
            // Only after every domain is back: a crash in between restores again on the next launch.
            try? fileManager.removeItem(at: file)
            return .restored
        }
    }

    /// Library/SnappetTestLaunch/settings-snapshot.plist — not tmp (iOS may purge it), not Preferences.
    static var snapshotURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnappetTestLaunch", isDirectory: true)
            .appendingPathComponent("settings-snapshot.plist")
    }

    /// The app's own settings and the App Group's (widgets, accent, household).
    static var realDomains: [Domain] {
        var domains: [Domain] = []
        if let id = Bundle.main.bundleIdentifier { domains.append(.defaults(.standard, name: id)) }
        if let group = UserDefaults(suiteName: WidgetSnapshotStore.appGroupID) {
            domains.append(.defaults(group, name: WidgetSnapshotStore.appGroupID))
        }
        return domains
    }

    /// What this launch did; set once, first thing in `SnappetApp.init`.
    nonisolated(unsafe) private(set) static var launchOutcome: Outcome = .notNeeded

    /// The launch hook. Must run before any other code reads a setting. Off on the simulator.
    static func atLaunch(arguments: [String]) {
        #if targetEnvironment(simulator)
        launchOutcome = UITestStore.isTestLaunch(arguments) ? .offOnSimulator : .notNeeded
        #else
        launchOutcome = run(isTestLaunch: UITestStore.isTestLaunch(arguments), domains: realDomains, file: snapshotURL)
        #endif
    }
}

/// What a test launch keeps away from, as one line the UI tests can read before their first tap (prompt 320).
/// It is the test-store marker's accessibility value; `TestStoreGuard` checks it on a real device.
enum TestLaunchIsolation {
    /// The local test vault (`AppModel.cloudBackup`): the only cloud a test launch may back up to.
    static let cloudVaultArgument = "-uiTestCloudVault"

    /// The cloud backup and its "Welcome back" restore offer: never on a test launch, except to the local test vault.
    static func cloudBackupRuns(_ arguments: [String]) -> Bool {
        !UITestStore.isTestLaunch(arguments) || arguments.contains(cloudVaultArgument)
    }

    /// Clip copies to Google Drive and the network watch that restarts them: never on a test launch.
    static func cloudCopiesRun(_ arguments: [String]) -> Bool {
        !UITestStore.isTestLaunch(arguments)
    }

    /// e.g. "cloud backup off; restore offer off; copies off; network watch off; prefs saved".
    static func readOut(arguments: [String], prefs: TestLaunchPrefs.Outcome) -> String {
        let backup = cloudBackupRuns(arguments) ? (arguments.contains(cloudVaultArgument) ? "test vault" : "on") : "off"
        let copies = cloudCopiesRun(arguments) ? "on" : "off"
        return "cloud backup \(backup); restore offer \(backup); copies \(copies); network watch \(copies); "
            + "prefs \(prefs.rawValue)"
    }
}
