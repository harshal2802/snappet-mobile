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
    /// A backup to offer on a fresh install; presented once by the shell.
    var restoreOffer: CloudBackupManifest?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vaultFor: @Sendable (CloudBackupDestination) -> (any CloudVault)?
    @ObservationIgnored private let keys: any CloudBackupKeyStore
    @ObservationIgnored private let network: @Sendable () async -> CloudBackupNetwork
    @ObservationIgnored private var running = false
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
    }

    /// The vault backups are read from: the chosen destination, else iCloud (so a fresh install,
    /// where nothing is chosen yet, can still be offered an existing backup). Reading the person's
    /// own cloud folder sends nothing anywhere.
    private var readVault: (any CloudVault)? { vaultFor(readDestination) }
    var readDestination: CloudBackupDestination {
        settings.destination == .off ? .iCloud : settings.destination
    }

    // MARK: - Back up

    /// Upload a backup if the policy says so. Safe to call often (launch, foreground, background).
    func runIfNeeded(context: ModelContext, storeHealthy: Bool, manual: Bool = false) async {
        guard settings.destination != .off, !running, let vault = vaultFor(settings.destination) else { return }
        running = true
        defer { running = false }
        let background = UIApplication.shared.beginBackgroundTask(withName: "snappet.cloudbackup")
        defer { UIApplication.shared.endBackgroundTask(background) }

        do {
            let file = try SnappetBackup.snapshot(of: context)   // main context → on the main actor
            let includeHeartRate = settings.includeHeartRate
            let prepared = try await Task.detached(priority: .utility) {
                try CloudBackupPayload.prepare(file, includeHeartRate: includeHeartRate)
            }.value
            let decision = CloudBackupPolicy.decide(.init(
                settings: settings, storeHealthy: storeHealthy,
                accountAvailable: await vault.isAvailable(), network: await network(),
                recordCount: prepared.recordCount, contentHash: prepared.contentHash,
                lastUploadedHash: lastManifest?.contentHash, lastUploadAt: lastManifest?.createdAt,
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
            let sealed = try await Task.detached(priority: .utility) {
                try CloudBackupCrypto.seal(prepared.plaintext, key: key)
            }.value
            let manifest = CloudBackupManifest(
                fileName: name, createdAt: createdAt, deviceID: deviceID, deviceName: deviceName,
                contentHash: prepared.contentHash, byteCount: sealed.count,
                recordCount: prepared.recordCount, sessionCount: prepared.sessionCount,
                clipCount: prepared.clipCount, backupFormatVersion: SnappetBackup.formatVersion,
                includesHeartRate: prepared.includesHeartRate)
            // Payload first, manifest last: a manifest in the vault always has its payload.
            try await vault.write(sealed, name: name)
            try await vault.write(try Self.encoder.encode(manifest),
                                  name: CloudBackupNaming.manifestName(forPayload: name))
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
        } catch {
            cloudBackupLog.error("cloud backup failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - List + restore

    func refreshRemote() async {
        guard let vault = readVault, await vault.isAvailable() else { remote = []; return }
        remote = (try? await Self.manifests(in: vault)) ?? []
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
        var out: [CloudBackupManifest] = []
        for name in try await vault.names() where CloudBackupNaming.isManifest(name) {
            guard let data = try? await vault.read(name),
                  let manifest = try? JSONDecoder().decode(CloudBackupManifest.self, from: data),
                  manifest.scheme <= CloudBackupManifest.currentScheme else { continue }
            out.append(manifest)
        }
        return out.sorted(by: CloudBackupPolicy.newestFirst)
    }
}
