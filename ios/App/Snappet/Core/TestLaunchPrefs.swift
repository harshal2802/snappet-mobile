import Foundation
import os

/// The person's settings survive a UI-test launch on their phone (prompt 320).
///
/// A test launch swaps SwiftData for an in-memory store, but settings live in `UserDefaults`, which it does
/// not isolate: `SnappetApp.init` clears ~20 keys so each test starts the same, tests flip switches, and
/// on 2026-11-26 a device run lost the person's Clips grid size, feed level, recent grades and gyms.
///
/// On a phone:
/// - the FIRST test launch saves the app's settings and the App Group's to a snapshot file in Library before
///   anything touches them; if that fails, the launch touches no setting at all and its read-out says
///   `prefs failed`, so the device test stops before its first tap;
/// - later test launches keep that first snapshot and only stamp the time of the latest test launch — unless it
///   is not this run's (too old, or the settings changed after its last test launch): then it is set aside and
///   the CURRENT settings are saved. The end-of-run restore applies the same check;
/// - at the END of a device run the UI-test helper relaunches the app with `-uiTestRestorePrefs`, which puts
///   both domains back exactly, deletes the snapshot and shows nothing else (`restoreOnly`);
/// - the next normal launch is only a FALLBACK (the run was cut short): it restores only when that is
///   certainly safe — the latest test launch was a few hours ago at most, and the settings files were not
///   changed after the run by some other launch (an older build that knows nothing of snapshots). Otherwise
///   the snapshot is set aside, kept and logged, never restored over newer settings.
/// A restore first renames the snapshot, so a failed delete is reported and can never restore again.
/// On the simulator all of this is off (`atLaunch`), so simulator runs and the unit-test host keep today's
/// behaviour.
///
/// The decisions (`step`, `fallback`, `mayTouchSettings`) are pure, and `run` works over injected domains,
/// a file URL and a clock, so all of it is unit-tested without a device.
enum TestLaunchPrefs {
    /// The UI-test helper's last launch of a device run: restore, then show only "Settings restored".
    static let restoreArgument = "-uiTestRestorePrefs"

    /// What this launch does with the snapshot.
    enum Step: Equatable {
        case snapshot        // test launch, no snapshot yet: save the real settings first
        case keepSnapshot    // test launch, a snapshot exists: it holds the real settings, keep it
        case restore         // normal launch, a snapshot exists: put the real settings back if it is safe
        case none            // normal launch, nothing saved
    }

    /// What happened, for the test-launch read-out (`TestLaunchIsolation.readOut`).
    enum Outcome: String, Equatable {
        case saved, kept, restored, notNeeded
        /// Restored, but the used snapshot could not be deleted (it was already renamed, so it never restores again).
        case restoredNotDeleted = "restored (snapshot not deleted)"
        /// A fallback restore was not safe: the snapshot was set aside, not used.
        case setAside = "set aside"
        case offOnSimulator = "off (simulator)"
        case failed
    }

    /// Why a fallback restore is refused.
    enum Fallback: Equatable {
        case restore
        case tooOld               // the latest test launch is older than `maxAge`
        case changedSince         // a settings file changed after the run, by some other launch
    }

    static func step(isTestLaunch: Bool, snapshotExists: Bool) -> Step {
        switch (isTestLaunch, snapshotExists) {
        case (true, false): return .snapshot
        case (true, true): return .keepSnapshot
        case (false, true): return .restore
        case (false, false): return .none
        }
    }

    /// A fallback restore (a normal launch finds a snapshot) is safe only soon after the run.
    static let maxAge: TimeInterval = 6 * 3600
    /// Settings keep changing while the last test runs after its launch; a change later than this after the latest
    /// test launch was made by something else.
    static let runGrace: TimeInterval = 30 * 60

    /// Pure: may a normal launch restore a snapshot whose latest test launch was at `lastTestLaunchAt`?
    static func fallback(now: Date, lastTestLaunchAt: Date, settingsModifiedAt: Date?,
                         maxAge: TimeInterval = maxAge, runGrace: TimeInterval = runGrace) -> Fallback {
        if now.timeIntervalSince(lastTestLaunchAt) > maxAge { return .tooOld }
        if let modified = settingsModifiedAt, modified.timeIntervalSince(lastTestLaunchAt) > runGrace { return .changedSince }
        return .restore
    }

    /// Pure: may this launch clear or seed settings? A normal launch always; a test launch only once the real ones
    /// are safely saved (or on the simulator, where nothing is saved and nothing is real).
    static func mayTouchSettings(isTestLaunch: Bool, outcome: Outcome) -> Bool {
        guard isTestLaunch else { return true }
        return [.saved, .kept, .offOnSimulator].contains(outcome)
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

    static let formatVersion = 2
    private static let log = Logger(subsystem: "com.snappet.app", category: "TestLaunchPrefs")

    /// The file a restore renames the snapshot to before using it.
    static func claimedURL(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("restoring.plist")
    }

    /// Where a refused snapshot is kept.
    static func setAsideURL(for file: URL, now: Date) -> URL {
        file.deletingPathExtension().appendingPathExtension("set-aside-\(Int(now.timeIntervalSince1970)).plist")
    }

    /// Saves, keeps or restores the snapshot at `file` for `domains`. `restoreOnly` is the helper's end-of-run
    /// launch. `settingsModifiedAt` is when the settings files last changed on disk. Returns what it did.
    ///
    /// Every use of an existing snapshot — keeping it on a test launch, the end-of-run restore, the fallback
    /// restore — first asks `fallback` whether it still belongs to the current run. A snapshot left by a run cut
    /// short, followed by days of another build, is set aside and never applied: a test launch then saves the
    /// CURRENT settings instead, and a restore leaves the settings as they are.
    @discardableResult
    static func run(isTestLaunch: Bool, restoreOnly: Bool = false, domains: [Domain], file: URL, now: Date = .now,
                    settingsModifiedAt: () -> Date? = { nil }, fileManager: FileManager = .default) -> Outcome {
        let exists = fileManager.fileExists(atPath: file.path)
        func fresh() -> (plist: [String: Any]?, check: Fallback?) {
            guard let plist = read(file), let last = plist["lastTestLaunchAt"] as? Date else { return (nil, nil) }
            return (plist, fallback(now: now, lastTestLaunchAt: last, settingsModifiedAt: settingsModifiedAt()))
        }
        func setAsideStale(_ check: Fallback?) -> Outcome {
            let reason = switch check {
            case nil: "unreadable"
            case .tooOld?: "older than \(Int(maxAge / 3600)) h"
            default: "settings changed after the run"
            }
            return setAside(file, now: now, reason: reason, fileManager: fileManager)
        }
        func snapshot() -> Outcome {
            var saved: [String: Any] = [:]
            for domain in domains { saved[domain.name] = domain.read() ?? [:] }
            return write(["version": formatVersion, "savedAt": now, "lastTestLaunchAt": now, "domains": saved],
                         to: file, fileManager: fileManager) ? .saved : .failed
        }
        if restoreOnly {
            guard exists else { return .notNeeded }
            let (_, check) = fresh()
            return check == .restore ? restore(domains: domains, file: file, fileManager: fileManager) : setAsideStale(check)
        }
        switch step(isTestLaunch: isTestLaunch, snapshotExists: exists) {
        case .none:
            return .notNeeded
        case .snapshot:
            return snapshot()
        case .keepSnapshot:
            let (plist, check) = fresh()
            guard check == .restore, var current = plist else {
                // Not this run's: put it aside and save what the settings are NOW.
                return setAsideStale(check) == .setAside ? snapshot() : .failed
            }
            current["lastTestLaunchAt"] = now
            return write(current, to: file, fileManager: fileManager) ? .kept : .failed
        case .restore:
            let (_, check) = fresh()
            return check == .restore ? restore(domains: domains, file: file, fileManager: fileManager) : setAsideStale(check)
        }
    }

    private static func restore(domains: [Domain], file: URL, fileManager: FileManager) -> Outcome {
        // Claim it first: once renamed it can never be restored a second time, whatever fails next.
        let claimed = claimedURL(for: file)
        try? fileManager.removeItem(at: claimed)
        do { try fileManager.moveItem(at: file, to: claimed) } catch {
            log.error("snapshot could not be claimed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        guard let plist = read(claimed), let saved = plist["domains"] as? [String: Any] else {
            log.error("claimed snapshot is unreadable; left at \(claimed.path, privacy: .public)")
            return .failed
        }
        for domain in domains {
            // A domain the snapshot does not name is left alone (a newer build may cover more).
            guard let value = saved[domain.name] as? [String: Any] else { continue }
            domain.write(value)
        }
        do { try fileManager.removeItem(at: claimed) } catch {
            log.error("restored, but the used snapshot was not deleted: \(error.localizedDescription, privacy: .public)")
            return .restoredNotDeleted
        }
        return .restored
    }

    private static func setAside(_ file: URL, now: Date, reason: String, fileManager: FileManager) -> Outcome {
        let target = setAsideURL(for: file, now: now)
        do { try fileManager.moveItem(at: file, to: target) } catch {
            log.error("snapshot (\(reason, privacy: .public)) could not be set aside: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        log.notice("snapshot not restored (\(reason, privacy: .public)); kept at \(target.path, privacy: .public)")
        return .setAside
    }

    private static func read(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func write(_ plist: [String: Any], to file: URL, fileManager: FileManager) -> Bool {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            log.error("snapshot not written: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - The app's own files

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

    /// When the settings files on disk last changed (the app's and the App Group's), for the fallback's check.
    static func realSettingsModifiedAt() -> Date? {
        var files: [URL] = []
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        if let id = Bundle.main.bundleIdentifier {
            files.append(library.appendingPathComponent("Preferences/\(id).plist"))
        }
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupID) {
            files.append(group.appendingPathComponent("Library/Preferences/\(WidgetSnapshotStore.appGroupID).plist"))
        }
        return files.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }.max()
    }

    /// What this launch did; set once, first thing in `SnappetApp.init`.
    nonisolated(unsafe) private(set) static var launchOutcome: Outcome = .notNeeded

    /// Whether this launch may clear or seed settings (`mayTouchSettings` for this launch).
    static var mayTouchSettingsNow: Bool {
        mayTouchSettings(isTestLaunch: UITestStore.onTestLaunch, outcome: launchOutcome)
    }

    static func isRestoreOnly(_ arguments: [String]) -> Bool { arguments.contains(restoreArgument) }

    /// The launch hook. Must run before any other code reads a setting. Off on the simulator.
    static func atLaunch(arguments: [String]) {
        #if targetEnvironment(simulator)
        launchOutcome = UITestStore.isTestLaunch(arguments) ? .offOnSimulator : .notNeeded
        #else
        launchOutcome = run(isTestLaunch: UITestStore.isTestLaunch(arguments), restoreOnly: isRestoreOnly(arguments),
                            domains: realDomains, file: snapshotURL, settingsModifiedAt: realSettingsModifiedAt)
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
