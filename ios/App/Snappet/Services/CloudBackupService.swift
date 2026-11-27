import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftData
import UIKit

private let cloudBackupLog = Logger(subsystem: "com.snappet.app", category: "CloudBackup")

/// The edge of automatic cloud backup (cloud-connect P2, prompt 267): snapshot the store, seal it
/// on the phone, hand it to the chosen `CloudVault`, keep a few generations, and fetch one back for
/// a deliberate restore. Decisions (when, what to keep, what to offer) are the pure
/// `CloudBackupPolicy`; this type only gathers inputs and performs I/O.
///
/// OFF by default. Nothing here runs an upload until the person picks a destination.
@MainActor
@Observable
final class CloudBackupService {
    enum Phase: Equatable { case idle, working, failed(String) }

    private(set) var settings: CloudBackupSettings
    private(set) var phase: Phase = .idle
    /// Why the last run did nothing, when that is worth saying ("Waiting for Wi-Fi.").
    private(set) var note: String?
    /// This device's most recent upload.
    private(set) var lastManifest: CloudBackupManifest?
    /// Backups found in the vault (any device), newest first.
    private(set) var remote: [CloudBackupManifest] = []
    /// Why `remote` is empty when the cloud could not be read (nil = it really is empty).
    private(set) var remoteProblem: String?
    /// A backup to offer on a fresh install; presented once by the shell.
    var restoreOffer: CloudBackupManifest?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vaultFor: @Sendable (CloudBackupDestination) -> (any CloudVault)?
    @ObservationIgnored private let keys: any CloudBackupKeyStore
    @ObservationIgnored private let network: @Sendable () async -> CloudBackupNetwork
    @ObservationIgnored private var running = false
    /// The run in progress and the rules it runs under, so a rule that stops applying can stop the
    /// payload being sent (prompt 293): the records backup is hundreds of MB on a real store.
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var passRules: (storeHealthy: Bool, manual: Bool, inSession: @MainActor () -> Bool)?
    @ObservationIgnored private var sendingPayload = false
    @ObservationIgnored private var stopReason: CloudBackupPolicy.SkipReason?
    @ObservationIgnored var ruleCheckEvery: Duration = .seconds(5)
    let deviceID: String
    let deviceName: String

    private enum Key {
        static let settings = "cloudBackup.settings"
        static let lastManifest = "cloudBackup.lastManifest"
        static let deviceID = "cloudBackup.deviceID"
        static let declined = "cloudBackup.declinedHashes"
    }

    init(defaults: UserDefaults = .standard,
         vaultFor: @escaping @Sendable (CloudBackupDestination) -> (any CloudVault)? = CloudBackupService.productionVault,
         keys: any CloudBackupKeyStore = KeychainBackupKeyStore(),
         network: @escaping @Sendable () async -> CloudBackupNetwork = { await CloudBackupNetworkProbe.current() },
         deviceName: String = UIDevice.current.name) {
        self.defaults = defaults
        self.vaultFor = vaultFor
        self.keys = keys
        self.network = network
        self.deviceName = deviceName
        settings = defaults.data(forKey: Key.settings)
            .flatMap { try? JSONDecoder().decode(CloudBackupSettings.self, from: $0) } ?? CloudBackupSettings()
        lastManifest = defaults.data(forKey: Key.lastManifest)
            .flatMap { try? JSONDecoder().decode(CloudBackupManifest.self, from: $0) }
        if let stored = defaults.string(forKey: Key.deviceID) {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Key.deviceID)
        }
    }

    /// iCloud, or the signed-in Google account's Drive (prompt 268).
    static let productionVault: @Sendable (CloudBackupDestination) -> (any CloudVault)? = { destination in
        switch destination {
        case .off: nil
        case .iCloud: ICloudVault()
        case .googleDrive: GoogleDriveVault.forSharedAccount()
        }
    }

    // MARK: - Settings

    func update(_ change: (inout CloudBackupSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        defaults.set(try? JSONEncoder().encode(next), forKey: Key.settings)
        note = nil
        if case .failed = phase { phase = .idle }
        if passTask != nil { Task { await stopIfNoLongerAllowed() } }
    }

    /// A backup is being sent and the rules may have changed under it — "Wi-Fi only" turned on, the
    /// network, Low Data Mode, a session starting, the destination switched off (prompt 293). If it
    /// could not start now, stop sending. Only while the payload travels: once it is in the cloud its
    /// small manifest always follows, so no payload is left without one.
    func stopIfNoLongerAllowed() async {
        guard let passTask, let rules = passRules, sendingPayload, stopReason == nil else { return }
        let reason = CloudBackupPolicy.precheck(settings: settings, storeHealthy: rules.storeHealthy,
                                                sessionRunning: rules.inSession(), network: await network(),
                                                manual: rules.manual)
        guard let reason, sendingPayload, self.passTask != nil else { return }
        stopReason = reason
        passTask.cancel()
        phase = .idle   // say so now, as the clip copies do
        note = CloudBackupStatusText.skipped(reason, destination: settings.destination)
        await passTask.value   // sending stops at once; the caller may start a new run next
    }

    /// The vault backups are read from: the chosen destination, else iCloud (so a fresh install,
    /// where nothing is chosen yet, can still be offered an existing backup). Reading the person's
    /// own cloud folder sends nothing anywhere.
    private var readVault: (any CloudVault)? { vaultFor(readDestination) }
    /// Whether a destination reaches any vault (a test launch's backup reaches none, prompt 320).
    func hasVault(for destination: CloudBackupDestination) -> Bool { vaultFor(destination) != nil }
    var readDestination: CloudBackupDestination {
        settings.destination == .off ? .iCloud : settings.destination
    }

    // MARK: - Back up

    /// Upload a backup if the policy says so. Safe to call often (launch, foreground, background).
    /// `stillInSession` is asked again while the payload is being sent (prompt 293).
    func runIfNeeded(context: ModelContext, storeHealthy: Bool, manual: Bool = false,
                     sessionRunning: Bool = false,
                     stillInSession: @escaping @MainActor () -> Bool = { false }) async {
        guard passTask == nil else { return }   // one run at a time, decided before anything is awaited
        stopReason = nil
        passRules = (storeHealthy, manual, stillInSession)
        let pass = Task {
            await self.pass(context: context, storeHealthy: storeHealthy, manual: manual, sessionRunning: sessionRunning)
            self.passTask = nil   // cleared by the run itself, so whoever waits on it finds it gone
            self.passRules = nil
            self.sendingPayload = false
        }
        passTask = pass
        let every = ruleCheckEvery
        let rules = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                if Task.isCancelled { return }
                await self?.stopIfNoLongerAllowed()
            }
        }
        await pass.value
        rules.cancel()
    }

    private func pass(context: ModelContext, storeHealthy: Bool, manual: Bool, sessionRunning: Bool) async {
        guard settings.destination != .off, !running, let vault = vaultFor(settings.destination) else { return }
        running = true
        defer { running = false }
        // Everything that can be ruled out without reading the store, first (prompt 279): the snapshot
        // below reads every record on the main thread.
        if let reason = CloudBackupPolicy.precheck(settings: settings, storeHealthy: storeHealthy,
                                                   sessionRunning: sessionRunning, network: await network(),
                                                   manual: manual) {
            note = CloudBackupStatusText.skipped(reason, destination: settings.destination)
            return
        }
        // "Unchanged since the last backup" and "too soon" only hold while that backup is still in
        // the cloud: if it is gone (removed there, or it never arrived), this run must upload again.
        let accountAvailable = await vault.isAvailable()
        var last = lastManifest
        if let known = last, accountAvailable, let names = try? await vault.names(),
           !CloudBackupPolicy.isStored(known, in: names) {
            cloudBackupLog.error("cloud backup: the last backup is no longer in the cloud — backing up again")
            last = nil
        }
        guard !CloudBackupPolicy.isTooSoon(lastUploadAt: last?.createdAt, now: .now, manual: manual) else { return }
        // Finish an upload the person walks away from; when iOS calls time, give the time back
        // rather than be closed for overstaying.
        let hold = BackgroundTaskHold("snappet.cloudbackup")
        defer { hold.end() }

        do {
            // Read on a context of its own, off the main thread (prompt 279): on a real store the
            // snapshot takes seconds, and on the main context it froze the app each time it came
            // forward. Saved first, so the other context sees what this one holds.
            try? context.save()
            let container = context.container
            let includeHeartRate = settings.includeHeartRate
            var prepared = try await Task.detached(priority: .utility) {
                let file = try SnappetBackup.snapshot(of: ModelContext(container))
                return try CloudBackupPayload.prepare(file, includeHeartRate: includeHeartRate)
            }.value
            let decision = CloudBackupPolicy.decide(.init(
                settings: settings, storeHealthy: storeHealthy,
                accountAvailable: accountAvailable, network: await network(),
                recordCount: prepared.recordCount, contentHash: prepared.contentHash,
                lastUploadedHash: last?.contentHash, lastUploadAt: last?.createdAt,
                now: .now, manual: manual))
            guard decision == .upload else {
                if case let .skip(reason) = decision {
                    note = CloudBackupStatusText.skipped(reason, destination: settings.destination)
                }
                if case .failed = phase, decision == .skip(.unchanged) { phase = .idle }
                return
            }

            phase = .working
            note = nil
            let key = try keys.loadOrCreateKey()
            let createdAt = Date.now
            let name = CloudBackupNaming.payloadName(createdAt: createdAt, deviceID: deviceID)
            let sealed = try await CloudBackupPayload.seal(&prepared, key: key)
            let manifest = CloudBackupManifest(
                fileName: name, createdAt: createdAt, deviceID: deviceID, deviceName: deviceName,
                contentHash: prepared.contentHash, byteCount: sealed.count,
                recordCount: prepared.recordCount, sessionCount: prepared.sessionCount,
                clipCount: prepared.clipCount, backupFormatVersion: SnappetBackup.formatVersion,
                includesHeartRate: prepared.includesHeartRate)
            // Payload first, manifest last: a manifest in the vault always has its payload.
            sendingPayload = true
            do {
                try await vault.write(sealed, name: name, wifiOnly: settings.wifiOnly)
                sendingPayload = false
            } catch {
                sendingPayload = false
                throw error
            }
            // Not stoppable: with the payload in the cloud, its manifest must follow.
            let manifestData = try Self.encoder.encode(manifest)
            try await Task {
                try await vault.write(manifestData, name: CloudBackupNaming.manifestName(forPayload: name))
            }.value
            lastManifest = manifest
            defaults.set(try? JSONEncoder().encode(manifest), forKey: Key.lastManifest)
            cloudBackupLog.info("cloud backup uploaded: \(prepared.recordCount) records, \(sealed.count) bytes")

            // Trim older generations of THIS device; failures here never fail the backup.
            let all = (try? await Self.manifests(in: vault)) ?? [manifest]
            for old in CloudBackupPolicy.toDelete(all, deviceID: deviceID) {
                try? await vault.remove(CloudBackupNaming.manifestName(forPayload: old.fileName))
                try? await vault.remove(old.fileName)
            }
            remote = ((try? await Self.manifests(in: vault)) ?? [manifest])
            phase = .idle
        } catch where stopReason != nil && Task.isCancelled {
            phase = .idle   // a rule stopped it mid-send (prompt 293): waiting, not failed
            note = stopReason.flatMap { CloudBackupStatusText.skipped($0, destination: settings.destination) }
        } catch {
            cloudBackupLog.error("cloud backup failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - List + restore

    func refreshRemote() async {
        guard let vault = readVault else { remote = []; remoteProblem = nil; return }
        guard await vault.isAvailable() else {
            remote = []
            remoteProblem = CloudVaultError.unavailable.localizedDescription
            return
        }
        do {
            let scan = try await Self.scan(vault)
            remote = scan.manifests
            // Backups that are there but can't be read are a problem to name, not "no backups".
            remoteProblem = scan.manifests.isEmpty ? scan.problems.first : nil
            for problem in scan.problems { cloudBackupLog.error("cloud backup list: \(problem, privacy: .public)") }
        } catch {
            remote = []
            remoteProblem = error.localizedDescription
            cloudBackupLog.error("cloud backup list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Download + open one backup. The caller applies it (replace-everything, after confirming).
    func download(_ manifest: CloudBackupManifest) async throws -> SnappetBackup.File {
        guard let vault = readVault else { throw CloudVaultError.unavailable }
        guard let key = keys.existingKey() else { throw CloudBackupCryptoError.wrongKeyOrDamaged }
        let sealed = try await vault.read(manifest.fileName)
        return try await Task.detached(priority: .userInitiated) {
            try SnappetBackup.decode(try CloudBackupCrypto.open(sealed, key: key))
        }.value
    }

    /// After a restore the store matches that backup — don't immediately re-upload the same data.
    func noteRestored(_ manifest: CloudBackupManifest) {
        guard manifest.includesHeartRate == settings.includeHeartRate else { return }
        var mine = manifest
        mine.deviceID = deviceID
        lastManifest = mine
        defaults.set(try? JSONEncoder().encode(mine), forKey: Key.lastManifest)
    }

    // MARK: - Fresh-install offer

    func checkRestoreOffer(localUserRecordCount: Int) async {
        guard localUserRecordCount == 0, restoreOffer == nil else { return }
        await refreshRemote()
        let declined = Set(defaults.stringArray(forKey: Key.declined) ?? [])
        // Only offer what this phone can actually open.
        guard keys.existingKey() != nil else { return }
        restoreOffer = CloudBackupPolicy.restoreOffer(remote, localUserRecordCount: localUserRecordCount,
                                                      declinedHashes: declined)
    }

    func declineOffer() {
        guard let offer = restoreOffer else { return }
        var declined = Set(defaults.stringArray(forKey: Key.declined) ?? [])
        declined.insert(offer.contentHash)
        defaults.set(Array(declined), forKey: Key.declined)
        restoreOffer = nil
    }

    // MARK: - Plumbing

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static func manifests(in vault: any CloudVault) async throws -> [CloudBackupManifest] {
        try await scan(vault).manifests
    }

    /// Every readable manifest, newest first, plus one line per backup that is there but could not
    /// be read — so the list can say why it is empty instead of claiming nothing was backed up.
    private static func scan(_ vault: any CloudVault) async throws
        -> (manifests: [CloudBackupManifest], problems: [String]) {
        var out: [CloudBackupManifest] = []
        var problems: [String] = []
        let names = try await vault.names()
        for name in names where CloudBackupNaming.isManifest(name) {
            do {
                let manifest = try JSONDecoder().decode(CloudBackupManifest.self, from: try await vault.read(name))
                if manifest.scheme <= CloudBackupManifest.currentScheme { out.append(manifest) }
                else { problems.append("A backup here was made by a newer version of Snappet.") }
            } catch {
                problems.append("Couldn’t read a backup (\(error.localizedDescription))")
            }
        }
        if out.isEmpty, problems.isEmpty, !names.isEmpty {
            problems.append("The cloud folder has \(names.count) file(s) but no backup list.")
        }
        return (out.sorted(by: CloudBackupPolicy.newestFirst), problems)
    }
}

/// A background-task assertion that ends itself when iOS says time is up (prompt 279). One that is
/// never ended gets the app closed, and with it whatever screen the person was on.
@MainActor
final class BackgroundTaskHold {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
