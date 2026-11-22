import CryptoKit
import Foundation
import Network
import os
import Security

// MARK: - CloudVault: where backup files go (cloud-connect P2, prompt 267)
//
// One small protocol, several destinations: `ICloudVault` (this phase), a Google Drive one (P3).
// A vault only stores and returns opaque named blobs — it never sees plaintext; sealing is the
// service's job. `FolderVault` is the same contract on a local directory, for tests.

protocol CloudVault: Sendable {
    /// Is the account reachable right now (signed in, container available)?
    func isAvailable() async -> Bool
    func names() async throws -> [String]
    func read(_ name: String) async throws -> Data
    func write(_ data: Data, name: String) async throws
    func remove(_ name: String) async throws
}

enum CloudVaultError: LocalizedError, Equatable {
    case unavailable
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The cloud account isn’t available. Check that you’re signed in."
        case .notFound: "That backup is no longer in the cloud."
        }
    }
}

/// A directory as a vault. Used by tests and UI tests (`-uiTestCloudVault`), and as the body of
/// `ICloudVault` once the ubiquity container's folder is resolved.
struct FolderVault: CloudVault {
    let directory: URL

    func isAvailable() async -> Bool { true }

    func names() async throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .map(Self.visibleName).sorted()
    }

    func read(_ name: String) async throws -> Data {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: Self.placeholder(for: url).path) else {
            throw CloudVaultError.notFound(name)
        }
        return try Self.coordinatedRead(url)
    }

    func write(_ data: Data, name: String) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.coordinatedWrite(data, to: directory.appendingPathComponent(name))
    }

    func remove(_ name: String) async throws {
        let url = directory.appendingPathComponent(name)
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { removeError = error }
        }
        if let error = coordinationError ?? removeError as NSError?,
           !(error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) {
            throw error
        }
    }

    /// An iCloud item that is not downloaded yet can appear as `.name.icloud`.
    static func visibleName(_ raw: String) -> String {
        guard raw.hasPrefix("."), raw.hasSuffix(".icloud") else { return raw }
        return String(raw.dropFirst().dropLast(".icloud".count))
    }

    private static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// A coordinated read makes the system download an evicted iCloud item first, then hands it over.
    private static func coordinatedRead(_ url: URL) throws -> Data {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)   // no-op off iCloud
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result { try Data(contentsOf: source) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CloudVaultError.unavailable }
        return try result.get()
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }
}

/// The person's iCloud Drive app container (`iCloud.com.snappet.app`), folder `Backups`. No
/// sign-in screen: it uses the iCloud account already on the phone. Unavailable when signed out,
/// when iCloud Drive is off for Snappet, or when the build lacks the iCloud entitlement.
struct ICloudVault: CloudVault {
    static let containerIdentifier = "iCloud.com.snappet.app"

    /// `url(forUbiquityContainerIdentifier:)` can block on first use — always called off-main.
    private func folder() async -> FolderVault? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let root = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier)
            else { return nil }
            return FolderVault(directory: root.appendingPathComponent("Backups", isDirectory: true))
        }.value
    }

    func isAvailable() async -> Bool { await folder() != nil }

    func names() async throws -> [String] {
        guard let folder = await folder() else { throw CloudVaultError.unavailable }
        return try await folder.names()
    }
    func read(_ name: String) async throws -> Data {
        guard let folder = await folder() else { throw CloudVaultError.unavailable }
        return try await folder.read(name)
    }
    func write(_ data: Data, name: String) async throws {
        guard let folder = await folder() else { throw CloudVaultError.unavailable }
        try await folder.write(data, name: name)
    }
    func remove(_ name: String) async throws {
        guard let folder = await folder() else { throw CloudVaultError.unavailable }
        try await folder.remove(name)
    }
}

// MARK: - The backup key

/// The 256-bit key backups are sealed with. Stored in the keychain as a SYNCHRONIZABLE item, so
/// iCloud Keychain carries it to the person's next iPhone; it is never written anywhere else.
/// Without iCloud Keychain a backup can only be opened on the phone that made it.
protocol CloudBackupKeyStore: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
    func existingKey() -> SymmetricKey?
}

struct KeychainBackupKeyStore: CloudBackupKeyStore {
    var service = "com.snappet.cloudbackup"
    var account = "key-v1"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanTrue as Any]
    }

    func existingKey() -> SymmetricKey? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        if let key = existingKey() { return key }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = existingKey() { return existing }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t save the backup key to the keychain (\(status))."])
        }
        return key
    }
}

/// A fixed key in memory — tests and UI tests only.
struct FixedBackupKeyStore: CloudBackupKeyStore {
    let key: SymmetricKey
    func loadOrCreateKey() throws -> SymmetricKey { key }
    func existingKey() -> SymmetricKey? { key }
}

// MARK: - Network kind

/// One-shot read of the current path: Wi-Fi-like, metered, or offline.
enum CloudBackupNetworkProbe {
    static func current() async -> CloudBackupNetwork {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                // The handler can fire again before `cancel()` lands — resume exactly once.
                guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
                monitor.cancel()
                continuation.resume(returning: .classify(
                    connected: path.status == .satisfied,
                    overWiFiOrCable: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                    isExpensive: path.isExpensive, isConstrained: path.isConstrained))
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}
