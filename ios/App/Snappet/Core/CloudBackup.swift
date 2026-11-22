import CryptoKit
import Foundation

// MARK: - Automatic cloud backup (cloud-connect P2, prompt 267) — the PURE core
//
// The suite backup file (`SnappetBackup.File`) already exists and encodes to identical bytes for
// identical data. This phase uploads it, ENCRYPTED ON THE PHONE, to a cloud the person chooses —
// the first named, opt-in exception to Snappet's on-device-only rule (see `decisions.md`).
// Everything here is plain values + CryptoKit: when to upload, what to keep, what to offer on a
// fresh install, how the file is sealed. The transfer itself sits behind `CloudVault` in Services.
// Backup, not sync: one phone's safety net, restored deliberately, replace-everything.

/// Where automatic backups go. `off` is the default — nothing leaves the phone until chosen.
enum CloudBackupDestination: String, Codable, CaseIterable, Sendable {
    case off
    case iCloud
    /// The hidden per-app folder of the person's Google Drive (prompt 268). Needs a Google sign-in.
    case googleDrive

    /// How the destination is named in the UI.
    var label: String {
        switch self {
        case .off: "Off"
        case .iCloud: "iCloud"
        case .googleDrive: "Google Drive"
        }
    }
}

struct CloudBackupSettings: Codable, Equatable, Sendable {
    var destination: CloudBackupDestination = .off
    /// Default OFF: heart-rate samples stay out of the cloud file (App Review 5.1.3(ii) says apps
    /// may not store personal health information in iCloud). On = the person's explicit choice.
    var includeHeartRate = false
    var wifiOnly = true
}

/// The small plain-text description stored beside each encrypted backup, so a list / a restore
/// offer can be shown without downloading and decrypting the payload.
struct CloudBackupManifest: Codable, Equatable, Hashable, Sendable, Identifiable {
    static let currentScheme = 1

    var scheme: Int = CloudBackupManifest.currentScheme
    /// The encrypted payload's file name in the vault.
    var fileName: String
    var createdAt: Date
    var deviceID: String
    var deviceName: String
    /// SHA-256 (hex) of the plaintext with `exportedAt` pinned — same data ⇒ same hash.
    var contentHash: String
    var byteCount: Int
    var recordCount: Int
    var sessionCount: Int
    var clipCount: Int
    var backupFormatVersion: Int
    var includesHeartRate: Bool

    var id: String { fileName }
}

enum CloudBackupNaming {
    static let payloadExtension = "snpbak"
    static let manifestSuffix = ".manifest.json"

    /// `snappet-20261119T210400Z-1a2b3c4d.snpbak` — sortable by time, unique per device.
    static func payloadName(createdAt: Date, deviceID: String) -> String {
        var style = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)
        style = style.year().month().day().time(includingFractionalSeconds: false)
        let stamp = createdAt.formatted(style)
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        let device = deviceID.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
        let utc = stamp.hasSuffix("Z") ? stamp : stamp + "Z"
        return "snappet-\(utc)-\(device).\(payloadExtension)"
    }

    static func manifestName(forPayload name: String) -> String { name + manifestSuffix }
    static func isManifest(_ name: String) -> Bool { name.hasSuffix(manifestSuffix) }
}

enum CloudBackupNetwork: Equatable, Sendable {
    /// `lowData`: on unmetered Wi-Fi with iOS Low Data Mode on for that network (prompt 284).
    case wifi, cellular, offline, lowData

    /// What "Wi-Fi only" means (prompt 281): the connection runs over Wi-Fi or a cable AND is not
    /// metered. "Not expensive" alone is not Wi-Fi: iOS reports 5G as inexpensive on many plans
    /// ("Allow More Data on 5G"), which let copies start on mobile data. A personal hotspot is
    /// Wi-Fi and expensive, so it still counts as mobile data.
    /// Low Data Mode is the person telling iOS to hold back background transfers on this network,
    /// so automatic copies and backups wait there (prompt 284). On mobile data the Wi-Fi rule
    /// already decides, so it is only reported for Wi-Fi.
    static func classify(connected: Bool, overWiFiOrCable: Bool, isExpensive: Bool,
                         isConstrained: Bool = false) -> CloudBackupNetwork {
        guard connected else { return .offline }
        guard overWiFiOrCable && !isExpensive else { return .cellular }
        return isConstrained ? .lowData : .wifi
    }

    /// A failed transfer that means "the network went, or this network is not allowed" rather than
    /// "this one file is bad". The pass stops and waits instead of trying the next file.
    static func isNetworkLoss(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                .internationalRoamingOff, .callIsActive].contains(code)
    }
}

enum CloudBackupPolicy {
    /// Automatic uploads are spaced at least this far apart.
    static let minimumInterval: TimeInterval = 15 * 60
    /// Generations kept per device.
    static let generationsKept = 3

    enum SkipReason: Equatable, Sendable {
        case off, storeUnhealthy, noAccount, nothingToBackUp, unchanged, offline, waitingForWiFi, lowDataMode, tooSoon, sessionRunning
    }
    enum Decision: Equatable, Sendable { case upload, skip(SkipReason) }

    struct Input: Equatable, Sendable {
        var settings: CloudBackupSettings
        /// The store is the real on-disk one (not the in-memory fallback, whose snapshot is empty).
        var storeHealthy = true
        var accountAvailable: Bool
        var network: CloudBackupNetwork
        var recordCount: Int
        var contentHash: String
        var lastUploadedHash: String?
        var lastUploadAt: Date?
        var now: Date
        /// "Back up now" — skips the spacing rule, nothing else.
        var manual = false
    }

    /// What can be ruled out WITHOUT reading the store (prompt 279). Taking the snapshot reads every
    /// record on the main thread, so an automatic run asks this first and stops here when it can.
    /// "Back up now" skips the session rule (and the spacing rule, `isTooSoon`), nothing else.
    static func precheck(settings: CloudBackupSettings, storeHealthy: Bool, sessionRunning: Bool,
                         network: CloudBackupNetwork, manual: Bool) -> SkipReason? {
        guard settings.destination != .off else { return .off }
        guard storeHealthy else { return .storeUnhealthy }
        if sessionRunning, !manual { return .sessionRunning }
        switch network {
        case .offline: return .offline
        case .cellular where settings.wifiOnly: return .waitingForWiFi
        case .lowData where !manual: return .lowDataMode   // "Back up now" is the person asking
        default: return nil
        }
    }

    /// The spacing rule on its own, so it too can be asked before the store is read. `lastUploadAt`
    /// is nil when the last backup is no longer in the cloud — that one is replaced at once.
    static func isTooSoon(lastUploadAt: Date?, now: Date, manual: Bool) -> Bool {
        guard !manual, let last = lastUploadAt else { return false }
        return now.timeIntervalSince(last) < minimumInterval && now >= last
    }

    static func decide(_ input: Input) -> Decision {
        guard input.settings.destination != .off else { return .skip(.off) }
        guard input.storeHealthy else { return .skip(.storeUnhealthy) }
        guard input.accountAvailable else { return .skip(.noAccount) }
        // Never cover a real backup with an empty one (fresh install, wiped store).
        guard input.recordCount > 0 else { return .skip(.nothingToBackUp) }
        guard input.contentHash != input.lastUploadedHash else { return .skip(.unchanged) }
        switch input.network {
        case .offline: return .skip(.offline)
        case .cellular where input.settings.wifiOnly: return .skip(.waitingForWiFi)
        case .lowData where !input.manual: return .skip(.lowDataMode)
        default: break
        }
        if isTooSoon(lastUploadAt: input.lastUploadAt, now: input.now, manual: input.manual) {
            return .skip(.tooSoon)
        }
        return .upload
    }

    /// Older generations to delete after an upload: keep the newest `keep` PER DEVICE, and never
    /// touch another device's backups.
    static func toDelete(_ manifests: [CloudBackupManifest], deviceID: String,
                         keep: Int = generationsKept) -> [CloudBackupManifest] {
        let mine = manifests.filter { $0.deviceID == deviceID }.sorted(by: newestFirst)
        return Array(mine.dropFirst(max(0, keep)))
    }

    /// Is this backup really in the vault — both its payload and its manifest?
    static func isStored(_ manifest: CloudBackupManifest, in names: [String]) -> Bool {
        names.contains(manifest.fileName)
            && names.contains(CloudBackupNaming.manifestName(forPayload: manifest.fileName))
    }

    /// The backup to offer on launch: only when this install holds no user records yet (a fresh
    /// install / new phone), and only one the person has not already declined.
    static func restoreOffer(_ manifests: [CloudBackupManifest], localUserRecordCount: Int,
                             declinedHashes: Set<String>) -> CloudBackupManifest? {
        guard localUserRecordCount == 0 else { return nil }
        return manifests.sorted(by: newestFirst)
            .first { $0.recordCount > 0 && !declinedHashes.contains($0.contentHash) }
    }

    static func newestFirst(_ a: CloudBackupManifest, _ b: CloudBackupManifest) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.fileName > b.fileName
    }
}

enum CloudBackupCryptoError: LocalizedError, Equatable {
    case notASnappetBackup
    case wrongKeyOrDamaged

    var errorDescription: String? {
        switch self {
        case .notASnappetBackup: "That file isn’t a Snappet cloud backup."
        case .wrongKeyOrDamaged:
            "This backup can’t be opened on this iPhone. Its encryption key isn’t here, or the file is damaged."
        }
    }
}

/// Seal / open the backup payload. ChaCha20-Poly1305 with a 256-bit key that never leaves the
/// keychain; the cloud only ever holds `magic + nonce + ciphertext + tag`.
enum CloudBackupCrypto {
    static let magic = Data("SNPBAK1\n".utf8)

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        magic + (try ChaChaPoly.seal(plaintext, using: key).combined)
    }

    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        guard sealed.count > magic.count, sealed.prefix(magic.count) == magic else {
            throw CloudBackupCryptoError.notASnappetBackup
        }
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed.dropFirst(magic.count)), using: key)
        } catch {
            throw CloudBackupCryptoError.wrongKeyOrDamaged
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Turn a store snapshot into what goes to the cloud (still plaintext here; the service seals it).
enum CloudBackupPayload {
    struct Prepared: Equatable, Sendable {
        var plaintext: Data
        var contentHash: String
        var recordCount: Int
        var sessionCount: Int
        var clipCount: Int
        var includesHeartRate: Bool
    }

    static func prepare(_ file: SnappetBackup.File, includeHeartRate: Bool) throws -> Prepared {
        let content = includeHeartRate ? file : file.strippingHeartRateSamples()
        // Hash with the export stamp pinned, so an unchanged store hashes the same every time.
        var pinned = content
        pinned.exportedAt = Date(timeIntervalSinceReferenceDate: 0)
        return Prepared(plaintext: try SnappetBackup.encode(content),
                        contentHash: CloudBackupCrypto.sha256Hex(try SnappetBackup.encode(pinned)),
                        recordCount: content.recordCount,
                        sessionCount: content.workoutSessions.count + content.kilterSessions.count,
                        clipCount: content.sessionMedia.count,
                        includesHeartRate: includeHeartRate)
    }
}

extension SnappetBackup.File {
    /// The same backup without heart-rate SAMPLES (the per-second series, incl. RR intervals) on
    /// gym and Kilter sessions. Session summaries (max / resting HR, energy) and everything else
    /// stay. Used for the cloud file while "Include heart-rate samples" is off.
    func strippingHeartRateSamples() -> SnappetBackup.File {
        var copy = self
        for index in copy.workoutSessions.indices { copy.workoutSessions[index].hrSeries = [] }
        for index in copy.kilterSessions.indices { copy.kilterSessions[index].hrSeries = [] }
        return copy
    }

    /// Rows a person made (not seeds / usage logs) — "is this install still empty?".
    var userRecordCount: Int {
        workoutSessions.count + kilterSessions.count + sessionMedia.count + journalEntries.count
            + habits.count + expenseRecords.count + budgetTransactions.count + kilterLogEntries.count
    }
}

/// Wording for the backup status line (pure, so it is tested without a device).
enum CloudBackupStatusText {
    static func skipped(_ reason: CloudBackupPolicy.SkipReason,
                        destination: CloudBackupDestination = .iCloud) -> String? {
        switch reason {
        case .off, .unchanged, .tooSoon: nil
        case .storeUnhealthy: "Storage is in a temporary state — nothing to back up."
        case .noAccount:
            destination == .googleDrive ? "Sign in to Google to back up."
                                        : "Sign in to iCloud in Settings to back up."
        case .nothingToBackUp: "Nothing to back up yet."
        case .offline: "Waiting for a connection."
        case .waitingForWiFi: "Waiting for Wi-Fi."
        case .lowDataMode: "Paused in Low Data Mode."
        case .sessionRunning: "Paused while a session is running."
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func contents(_ manifest: CloudBackupManifest) -> String {
        var parts = ["\(manifest.sessionCount.formatted()) \(manifest.sessionCount == 1 ? "session" : "sessions")",
                     "\(manifest.clipCount.formatted()) \(manifest.clipCount == 1 ? "clip" : "clips")"]
        parts.append(manifest.includesHeartRate ? "heart rate included" : "no heart-rate samples")
        return parts.joined(separator: " · ")
    }
}
