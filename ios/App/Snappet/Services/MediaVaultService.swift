import AVFoundation
import CryptoKit
import Foundation
import Observation
import OSLog
import Photos
import SwiftData
import SwiftUI
import UIKit

private let mediaVaultLog = Logger(subsystem: "com.snappet.app", category: "MediaVault")

// MARK: - The clip vault, the edge (cloud-connect P4, prompt 269)

/// The "Snappet Clips" folder in the person's Google Drive (`drive.file`: Snappet sees only what it
/// created). Files are ordinary, visible, unencrypted clips, arranged in folders the person chose
/// (prompt 270); each carries its `SessionMedia.id` in a private property.
struct GoogleDriveMediaStore: Sendable {
    let google: GoogleAuthorizedHTTP

    func folderID() async throws -> String {
        let found = try GoogleDriveAPI.sizedPage(
            from: try await google.send(GoogleDriveAPI.findFolder(named: MediaVaultNaming.folderName)).0)
        if let existing = found.files.map(\.id).sorted().first { return existing }
        let created = try await google.send(GoogleDriveAPI.createFolder(named: MediaVaultNaming.folderName)).0
        guard let file = try? JSONDecoder().decode(GoogleDriveFile.self, from: created) else { throw GoogleAuthError.badResponse }
        return file.id
    }

    private func pages(_ request: (String?) -> URLRequest) async throws -> [GoogleDriveAPI.SizedFile] {
        var all: [GoogleDriveAPI.SizedFile] = []
        var token: String?
        repeat {
            let page = try GoogleDriveAPI.sizedPage(from: try await google.send(request(token)).0)
            all += page.files
            token = page.nextPageToken
        } while token != nil
        return all
    }

    /// Every clip copy: the ones carrying Snappet's private marker, wherever they sit, plus what lies
    /// directly in the root folder (copies made before prompt 270, known by their name).
    func listClipFiles(rootID: String) async throws -> [MediaVaultFile] {
        let tagged = try await pages { GoogleDriveAPI.clipFiles(pageToken: $0) }
        let inRoot = try await pages { GoogleDriveAPI.children(ofFolder: rootID, pageToken: $0) }
        var seen = Set<String>()
        return (tagged + inRoot).filter { seen.insert($0.id).inserted }.map(\.vaultFile)
    }

    func listFolders() async throws -> [MediaVaultFolder] {
        try await pages { GoogleDriveAPI.folders(pageToken: $0) }
            .map { MediaVaultFolder(id: $0.id, name: $0.name, parentID: $0.parents?.first) }
    }

    func createFolder(named name: String, parent: String) async throws -> String {
        let created = try await google.send(GoogleDriveAPI.createFolder(named: name, parent: parent)).0
        guard let file = try? JSONDecoder().decode(GoogleDriveFile.self, from: created) else { throw GoogleAuthError.badResponse }
        return file.id
    }

    /// Rename / re-tag a copy and move it between folders. No bytes travel.
    func relocate(fileID: String, name: String, properties: [String: String], to folderID: String, from oldParent: String?) async throws {
        _ = try await google.send(GoogleDriveAPI.relocate(id: fileID, name: name, appProperties: properties,
                                                          addParent: folderID, removeParent: oldParent))
    }

    func trash(folderID: String) async throws {
        _ = try await google.send(GoogleDriveAPI.trash(id: folderID))
    }

    func trash(fileID: String) async throws {
        _ = try await google.send(GoogleDriveAPI.trash(id: fileID))
    }

    /// Upload a file (streamed from disk); returns the new Drive file id.
    /// `wifiOnly`: the bytes may not travel over cellular or a hotspot, so an upload that began on
    /// Wi-Fi stops when the Wi-Fi goes instead of finishing on mobile data (prompt 279).
    func upload(_ file: URL, name: String, folderID: String, properties: [String: String],
                wifiOnly: Bool = false) async throws -> String {
        let byteCount = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        let (_, start) = try await google.send(GoogleDriveAPI.startUpload(name: name, byteCount: byteCount, parent: folderID,
                                                                          appProperties: properties))
        guard let location = start.value(forHTTPHeaderField: "Location"), let session = URL(string: location) else {
            throw GoogleAuthError.badResponse
        }
        var put = GoogleDriveAPI.finishUpload(session: session, data: Data())
        put.httpBody = nil
        if wifiOnly {
            put.allowsExpensiveNetworkAccess = false
            put.allowsCellularAccess = false
        }
        let (data, _) = try await google.upload(put, fromFile: file)
        guard let created = try? JSONDecoder().decode(GoogleDriveFile.self, from: data) else { throw GoogleAuthError.badResponse }
        return created.id
    }

    func download(fileID: String, to destination: URL) async throws {
        try await google.download(GoogleDriveAPI.download(id: fileID), to: destination)
    }
}

/// Reads originals out of the phone's Photos library. A seam, so the service is tested without one.
protocol MediaVaultExporter: Sendable {
    /// Which of these identifiers still resolve on this phone.
    func present(_ localIdentifiers: [String]) async -> Set<String>
    /// Write the asset's original to a temporary file.
    func export(localIdentifier: String) async throws -> (url: URL, fileExtension: String)
    /// Remove these assets from the phone's library (prompt 274). iOS asks the person itself, and
    /// keeps them in Recently Deleted for 30 days. Throws when they say no.
    func delete(localIdentifiers: [String]) async throws
    /// Put a file back into the library; returns the new asset's identifier.
    func save(file: URL, isVideo: Bool) async throws -> String
    /// Whether every asset can be seen. With limited or no access an identifier that does not
    /// resolve says nothing about whether the clip is on the phone (prompt 276).
    func canSeeWholeLibrary() async -> Bool
    /// A still of the asset as JPEG, kept so a clip that leaves the phone keeps its thumbnail.
    func poster(localIdentifier: String) async -> Data?
    /// The date Photos files the asset under; nil when it has none or cannot be seen.
    func creationDate(of localIdentifier: String) async -> Date?
    /// Change the date Photos files the asset under (prompt 277).
    func setCreationDate(_ date: Date, of localIdentifier: String) async throws
}

/// The MD5 of a file, read in pieces (clips can be hundreds of MB). Drive reports the same digest
/// for what it holds, so the two can be compared without downloading anything.
enum MediaVaultHash {
    static func md5(of file: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = Insecure.MD5()
            while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hasher.update(data: piece) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// Stills of clips that have left this phone, by the Photos identifier the clip row still carries.
/// In Application Support, not Caches: iOS must not clear them, the original is gone.
enum MediaVaultPosters {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClipPosters", isDirectory: true)

    static func url(for localIdentifier: String, in directory: URL = directory) -> URL {
        let safe = String(localIdentifier.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent(safe + ".jpg")
    }

    static func image(for localIdentifier: String, in directory: URL = directory) -> UIImage? {
        UIImage(contentsOfFile: url(for: localIdentifier, in: directory).path)
    }
}

struct PhotosMediaVaultExporter: MediaVaultExporter {
    func present(_ localIdentifiers: [String]) async -> Set<String> {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return [] }
        return await Task.detached(priority: .utility) {
            var out = Set<String>()
            PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
                .enumerateObjects { asset, _, _ in out.insert(asset.localIdentifier) }
            return out
        }.value
    }

    func export(localIdentifier: String) async throws -> (url: URL, fileExtension: String) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw CloudVaultError.notFound(localIdentifier)
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        guard let resource = wanted.lazy.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else {
            throw CloudVaultError.notFound(localIdentifier)
        }
        let ext = MediaVaultNaming.fileExtension(isVideo: asset.mediaType == .video, mimeType: nil,
                                                 fileName: resource.originalFilename)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString).\(ext)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // an iCloud-offloaded original is fetched first
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return (url, ext)
    }

    func canSeeWholeLibrary() async -> Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    func poster(localIdentifier: String) async -> Data? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // one callback
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 900, height: 900),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.8))
            }
        }
    }

    func creationDate(of localIdentifier: String) async -> Date? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject?.creationDate
    }

    func setCreationDate(_ date: Date, of localIdentifier: String) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw CloudVaultError.notFound(localIdentifier)
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).creationDate = date
        }
    }

    func delete(localIdentifiers: [String]) async throws {
        guard PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil).count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil))
        }
    }

    func save(file: URL, isVideo: Bool) async throws -> String {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw MediaVaultFailure("Allow full access to Photos to bring a clip back.")
        }
        let box = SavedAssetID()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = box.value else { throw MediaVaultFailure("Photos did not save the clip.") }
        return id
    }
}

private final class SavedAssetID: @unchecked Sendable { var value: String? }

struct MediaVaultFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Copies clips to the vault, fetches them back for playback, and brings Google Photos picks in.
/// OFF by default; hidden unless the build has a Google client ID.
@MainActor
@Observable
final class MediaVaultService {
    enum Phase: Equatable {
        case idle, working(done: Int, total: Int), failed(String)
        /// Moving existing copies into the chosen folders (prompt 270).
        case organizing(done: Int, total: Int)
        /// Confirming copies before originals leave the phone (prompt 274).
        case checking(done: Int, total: Int)
    }

    struct Account: Sendable {
        var isSignedIn: @MainActor @Sendable () -> Bool
        var grants: @MainActor @Sendable (String) -> Bool

        static let shared = Account(isSignedIn: { GoogleAccount.shared.isSignedIn },
                                    grants: { GoogleAccount.shared.grants($0) })
    }

    private(set) var settings: MediaVaultSettings
    private(set) var index: MediaVaultIndex
    /// Drive folder id → its names below "Snappet Clips", as of the last pass (prompt 272).
    private(set) var folderPaths: [String: [String]] = [:]
    /// Folders in "Snappet Clips" holding no copy, as of the last pass; 0 while copies are still moving.
    private(set) var emptyFolderCount = 0
    /// Copies whose clip is no longer in Snappet and that were not removed automatically (prompt 274).
    private(set) var leftoverCount = 0
    /// Clips that have a copy and are no longer in this phone's Photos — they play from Drive.
    private(set) var onlyInDrive: Set<UUID> = []
    /// Clips that are on the phone AND copied: what "Free up space" could remove, before checking.
    private(set) var freeable = (count: 0, bytes: Int64(0))
    /// Clips whose copy the person removed by hand: not copied again until they ask.
    private(set) var excluded: Set<UUID> = []
    /// Clips being downloaded back into Photos right now, and the last one that failed (with why).
    private(set) var bringingBack: Set<UUID> = []
    private(set) var bringBackFailure: (clip: UUID, message: String)?
    /// False with limited or no Photos access: then "is it on this phone" cannot be answered, so
    /// nothing is called Drive-only, nothing is offered for removal and nothing is copied (prompt 276).
    private(set) var libraryVisible = true
    /// Clips the person chose to play over cellular although copies are Wi-Fi only (until relaunch).
    private(set) var allowedOnCellular: Set<UUID> = []
    private(set) var phase: Phase = .idle
    private(set) var note: String?
    private(set) var coverage = MediaVaultPlanner.Coverage(copied: 0, total: 0, onlyInVault: 0)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let account: Account
    @ObservationIgnored private let google: GoogleAuthorizedHTTP
    @ObservationIgnored private let exporter: any MediaVaultExporter
    @ObservationIgnored private let network: @Sendable () async -> CloudBackupNetwork
    @ObservationIgnored let cacheDirectory: URL
    @ObservationIgnored let posterDirectory: URL
    /// The last bring-back: the date Photos gave the asset, and the date put in its place (nil: left alone).
    @ObservationIgnored private(set) var lastRestoredDate: (assigned: Date?, corrected: Date?)?
    /// Videos larger than this are streamed, not downloaded whole.
    @ObservationIgnored var streamAbove = MediaVaultFetch.streamAbove
    @ObservationIgnored private var folderID: String?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var fetching: [UUID: Task<URL, Error>] = [:]
    /// A pass copies every clip that has no copy yet and keeps going while the app is open
    /// (user, 2026-11-20). This many failures in a row means the trouble is not one clip
    /// (connection, account), so the pass stops and says why.
    static let failuresInARowBeforeStopping = 3
    /// Copies moved or renamed per pass — one small request each, no bytes.
    static let moveLimit = 200

    private enum Key {
        static let settings = "mediaVault.settings"
        static let index = "mediaVault.index"
        static let folders = "mediaVault.folderPaths"
        static let known = "mediaVault.knownClips"
        static let excluded = "mediaVault.excludedClips"
    }

    init(defaults: UserDefaults = .standard, account: Account = .shared,
         google: GoogleAuthorizedHTTP = .forSharedAccount(),
         exporter: any MediaVaultExporter = PhotosMediaVaultExporter(),
         network: @escaping @Sendable () async -> CloudBackupNetwork = { await CloudBackupNetworkProbe.current() },
         cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipVault", isDirectory: true),
         posterDirectory: URL = MediaVaultPosters.directory) {
        self.posterDirectory = posterDirectory
        self.defaults = defaults
        self.account = account
        self.google = google
        self.exporter = exporter
        #if DEBUG
        // Device checks (prompt 276): pretend to be on cellular, or stream every video however small.
        let assumeCellular = UserDefaults.standard.bool(forKey: "vaultAssumeCellular")
        self.network = { assumeCellular ? .cellular : await network() }
        let forcedStreamAbove = UserDefaults.standard.integer(forKey: "vaultStreamAbove")
        if forcedStreamAbove > 0 { streamAbove = Int64(forcedStreamAbove) }
        #else
        self.network = network
        #endif
        self.cacheDirectory = cacheDirectory
        settings = defaults.data(forKey: Key.settings)
            .flatMap { try? JSONDecoder().decode(MediaVaultSettings.self, from: $0) } ?? MediaVaultSettings()
        index = defaults.data(forKey: Key.index)
            .flatMap { try? JSONDecoder().decode(MediaVaultIndex.self, from: $0) } ?? MediaVaultIndex()
        folderPaths = defaults.data(forKey: Key.folders)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        excluded = Set((defaults.stringArray(forKey: Key.excluded) ?? []).compactMap(UUID.init(uuidString:)))
    }

    // MARK: - Cleaning up (prompt 274)

    /// The clips Snappet had at the end of the last pass on this phone — how a deletion is told
    /// apart from a clip this phone never had.
    private var known: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Key.known) ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: Key.known) }
    }

    private func setExcluded(_ new: Set<UUID>) {
        excluded = new
        defaults.set(new.map(\.uuidString).sorted(), forKey: Key.excluded)
    }

    /// A restore replaced the store: what is missing now was not deleted by the person.
    func storeWasReplaced() { defaults.removeObject(forKey: Key.known) }

    private static func storeIDs(_ context: ModelContext) -> Set<UUID> {
        Set(((try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []).map(\.id))
    }

    private func drop(_ rowIDs: some Sequence<UUID>) {
        var next = index
        for id in rowIDs { next.remove(id) }
        setIndex(next)
    }

    /// Trash the copies of clips this phone deleted (when the switch is on), and count the rest.
    private func cleanUp(storeIDs: Set<UUID>) async {
        let plan = MediaVaultCleanup.plan(index: index, storeIDs: storeIDs, known: known,
                                          followDeletions: settings.removeWithClip)
        var removed: [UUID] = []
        for entry in plan.remove {
            do { try await store.trash(fileID: entry.fileID); removed.append(entry.rowID) }
            catch CloudVaultError.notFound { removed.append(entry.rowID) }   // already gone
            catch { mediaVaultLog.error("could not trash a copy: \(error.localizedDescription, privacy: .public)") }
        }
        drop(removed)
        leftoverCount = plan.leftovers.count + plan.remove.count - removed.count
        if !storeIDs.isEmpty { known = storeIDs }
        setExcluded(excluded.intersection(storeIDs))
    }

    /// Remove the copies of clips that are no longer in Snappet. Asked for by the person.
    func removeLeftovers(context: ModelContext) async {
        guard canUseDrive, !running else { return }
        running = true
        defer { running = false }
        do {
            try await loadIndex(rootID: try await resolveFolder())
            let ids = Self.storeIDs(context)
            let orphans = MediaVaultCleanup.plan(index: index, storeIDs: ids, known: [], followDeletions: false).leftovers
            guard !orphans.isEmpty else { leftoverCount = 0; return }
            phase = .organizing(done: 0, total: orphans.count)
            var removed: [UUID] = []
            for (done, entry) in orphans.enumerated() {
                do { try await store.trash(fileID: entry.fileID); removed.append(entry.rowID) }
                catch CloudVaultError.notFound { removed.append(entry.rowID) }
                catch { mediaVaultLog.error("could not trash a copy: \(error.localizedDescription, privacy: .public)") }
                phase = .organizing(done: done + 1, total: orphans.count)
            }
            drop(removed)
            leftoverCount = orphans.count - removed.count
            phase = .idle
            note = MediaVaultText.removedCopies(removed.count)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Remove one clip's copy, and do not copy that clip again until asked.
    func removeCopy(of rowID: UUID) async {
        guard canUseDrive, let entry = index.entry(for: rowID) else { return }
        do {
            try await store.trash(fileID: entry.fileID)
        } catch CloudVaultError.notFound {
            // already gone
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        drop([rowID])
        onlyInDrive.remove(rowID)
        setExcluded(excluded.union([rowID]))
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(entry.cacheName))
    }

    /// Undo `removeCopy`'s "do not copy again".
    func copyAgain(_ rowID: UUID) { setExcluded(excluded.subtracting([rowID])) }

    /// Move the whole "Snappet Clips" folder to Drive's trash and switch copies off.
    func removeAllCopies() async {
        guard canUseDrive, !running else { return }
        running = true
        defer { running = false }
        do {
            let root = try await resolveFolder()
            let count = index.count
            try await store.trash(folderID: root)
            folderID = nil
            setIndex(MediaVaultIndex())
            folderPaths = [:]
            defaults.removeObject(forKey: Key.folders)
            setExcluded([])
            emptyFolderCount = 0
            leftoverCount = 0
            onlyInDrive = []
            freeable = (0, 0)
            try? FileManager.default.removeItem(at: cacheDirectory)
            update { $0.keepCopies = false; $0.started = false }
            phase = .idle
            note = MediaVaultText.removedCopies(count)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Remove from this phone the originals that Drive demonstrably holds. Each copy is checked
    /// against a listing taken right now: its size in Drive must equal what was sent (or, for a
    /// copy made before sizes were recorded, the original's size measured now). iOS then asks the
    /// person itself and keeps the originals in Recently Deleted for 30 days.
    /// `only`: just these clips (prompt 275). An original shared with a clip outside `only` stays.
    func freeUpSpace(context: ModelContext, only: Set<UUID>? = nil) async {
        guard canUseDrive, !running else { return }
        running = true
        defer { running = false }
        do {
            let root = try await resolveFolder()
            let listed = MediaVaultIndex(files: try await store.listClipFiles(rootID: root))   // only what Drive lists
            let all = await clips(in: context)
            guard libraryVisible else { phase = .idle; note = "Allow full access to Photos to free up space."; return }
            let candidates = all.filter { $0.isOnPhone && listed.contains($0.rowID) && (only?.contains($0.rowID) ?? true) }
            guard !candidates.isEmpty else { phase = .idle; note = "Nothing to free up."; return }
            var verified = Set<UUID>()
            phase = .checking(done: 0, total: candidates.count)
            for (done, clip) in candidates.enumerated() {
                if let entry = listed.entry(for: clip.rowID) {
                    if !MediaVaultCleanup.needsMeasuring(entry) {
                        if MediaVaultCleanup.isVerified(entry) { verified.insert(clip.rowID) }
                    } else if let exported = try? await exporter.export(localIdentifier: clip.localIdentifier) {
                        // A copy from before sizes and checksums were recorded: read the original now.
                        let size = (try? FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? NSNumber)?.int64Value
                        let md5 = try? await MediaVaultHash.md5(of: exported.url)
                        try? FileManager.default.removeItem(at: exported.url)
                        if MediaVaultCleanup.isVerified(entry, measured: size, measuredMD5: md5) { verified.insert(clip.rowID) }
                    }
                }
                phase = .checking(done: done + 1, total: candidates.count)
            }
            let assets = MediaVaultCleanup.freeable(all, verified: verified)
            let kept = Set(candidates.map(\.localIdentifier)).count - assets.count
            guard !assets.isEmpty else {
                phase = .idle
                note = "Nothing was removed: no copy could be confirmed."
                return
            }
            await keepPosters(of: assets)   // before they go: the feed still needs a thumbnail
            do {
                try await exporter.delete(localIdentifiers: assets)
            } catch {
                for asset in assets { try? FileManager.default.removeItem(at: MediaVaultPosters.url(for: asset, in: posterDirectory)) }
                phase = .idle
                note = "Nothing was removed from this iPhone."
                return
            }
            let gone = Set(assets)
            let freedRows = all.filter { gone.contains($0.localIdentifier) }
            let bytes = Dictionary(grouping: freedRows, by: \.localIdentifier).values
                .reduce(Int64(0)) { $0 + ($1.first.flatMap { listed.entry(for: $0.rowID)?.byteCount } ?? 0) }
            setIndex(listed.keepingRecentUploads(from: index, now: .now))
            await refreshCoverage(context: context)
            phase = .idle
            note = MediaVaultText.freed(count: assets.count, bytes: bytes, unverified: kept)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func keepPosters(of assets: [String]) async {
        try? FileManager.default.createDirectory(at: posterDirectory, withIntermediateDirectories: true)
        for asset in assets {
            guard let jpeg = await exporter.poster(localIdentifier: asset) else { continue }
            try? jpeg.write(to: MediaVaultPosters.url(for: asset, in: posterDirectory), options: .atomic)
        }
    }

    /// A pass, a check or a removal is under way: the clean-up actions wait.
    var isBusy: Bool {
        switch phase {
        case .working, .organizing, .checking: true
        default: false
        }
    }

    /// Remove ONE clip's original from this phone — and with it every clip that shares the original.
    func freeUpClip(_ rowID: UUID, context: ModelContext) async {
        let all = await clips(in: context)
        guard let asset = all.first(where: { $0.rowID == rowID })?.localIdentifier else { return }
        await freeUpSpace(context: context, only: Set(all.filter { $0.localIdentifier == asset }.map(\.rowID)))
    }

    /// Clips placed on a Studio project's timeline: editing or exporting that project needs the original.
    func clipsUsedInStudio(context: ModelContext) -> Set<UUID> {
        Set(((try? context.fetch(FetchDescriptor<StudioProject>())) ?? []).flatMap { $0.clips.compactMap(\.sessionMediaID) })
    }

    /// What the chooser offers: clips on this phone whose original has a copy for every clip using it.
    func freeUpItems(context: ModelContext) async -> [MediaVaultFreeUpItem] {
        let all = await clips(in: context)
        guard libraryVisible else { return [] }
        let infos = MediaVaultCatalog.infos(context: context)
        let sessionOf = Dictionary(((try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []).map { ($0.id, $0.sessionID) },
                                   uniquingKeysWith: { first, _ in first })
        let whole = Dictionary(grouping: all.filter(\.isOnPhone), by: \.localIdentifier)
            .filter { $0.value.allSatisfy { index.contains($0.rowID) } }
        return all.compactMap { clip -> MediaVaultFreeUpItem? in
            guard whole[clip.localIdentifier] != nil, let info = infos[clip.rowID], let session = sessionOf[clip.rowID],
                  let entry = index.entry(for: clip.rowID) else { return nil }
            return MediaVaultFreeUpItem(id: clip.rowID, asset: clip.localIdentifier, capturedAt: info.capturedAt,
                                        activity: info.activity, sessionID: session,
                                        sessionStartedAt: info.sessionStartedAt, bytes: entry.byteCount)
        }
    }

    /// `bringBack`, with the progress and failure the clip's own mark shows.
    func bringBackNow(_ rowID: UUID, context: ModelContext) async {
        guard !bringingBack.contains(rowID) else { return }
        bringingBack.insert(rowID)
        bringBackFailure = nil
        defer { bringingBack.remove(rowID) }
        do {
            try await bringBack(rowID, context: context)
        } catch {
            mediaVaultLog.error("bring back failed: \(error.localizedDescription, privacy: .public)")
            bringBackFailure = (rowID, error.localizedDescription)
        }
    }

    /// Put a clip that lives only in Drive back into this phone's Photos, and point the clip at it —
    /// needed before it can be edited in the Studio or used in a reel.
    func bringBack(_ rowID: UUID, context: ModelContext) async throws {
        guard let media = ((try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []).first(where: { $0.id == rowID }) else {
            throw CloudVaultError.notFound(rowID.uuidString)
        }
        let old = media.localIdentifier
        // Recovered from Recently Deleted in the meantime: it is back already, a second one would be a duplicate.
        if await exporter.present([old]).contains(old) {
            onlyInDrive.remove(rowID)
            return
        }
        let file = try await localURL(for: rowID)
        let saveStarted = Date.now
        let id = try await exporter.save(file: file, isVideo: media.kind == .video)
        await restoreDate(of: id, saveStarted: saveStarted, media: media, context: context)
        try? FileManager.default.removeItem(at: MediaVaultPosters.url(for: old, in: posterDirectory))
        media.localIdentifier = id
        media.cloudIdentifier = nil   // names the asset that is gone; the next link pass maps the new one
        try context.save()
        onlyInDrive.remove(rowID)
    }

    /// A file without a capture date of its own lands in Photos under "now": put it where it was
    /// filmed. Never fails the bring-back — the clip is back either way.
    private func restoreDate(of asset: String, saveStarted: Date, media: SessionMedia, context: ModelContext) async {
        // Best evidence first: the original's own date, recorded while it was on the phone; then
        // session start + offset; then (its session gone) when the clip was added to Snappet.
        let known = media.linkCapturedAt ?? MediaVaultCatalog.infos(context: context)[media.id]?.capturedAt ?? media.createdAt
        let assigned = await exporter.creationDate(of: asset)
        lastRestoredDate = (assigned, nil)
        guard let date = MediaVaultRestoreDate.correction(assigned: assigned, saveStarted: saveStarted, saveEnded: .now,
                                                          known: known) else { return }
        lastRestoredDate = (assigned, date)
        do {
            try await exporter.setCreationDate(date, of: asset)
        } catch {
            mediaVaultLog.error("could not date a restored clip: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var store: GoogleDriveMediaStore { GoogleDriveMediaStore(google: google) }
    private var canUseDrive: Bool { account.isSignedIn() && account.grants(GoogleScope.driveFile) }

    func update(_ change: (inout MediaVaultSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        defaults.set(try? JSONEncoder().encode(next), forKey: Key.settings)
        note = nil
        if case .failed = phase { phase = .idle }
    }

    func contains(_ rowID: UUID) -> Bool { index.contains(rowID) }

    /// Whether screens should say anything about copies: the person started them, or some exist.
    var showsCopyState: Bool { (settings.keepCopies && settings.started) || index.count > 0 }

    /// Where a clip's copy sits, in words; nil when it has no copy.
    func location(of rowID: UUID) -> String? {
        guard let entry = index.entry(for: rowID) else { return nil }
        return MediaVaultText.location(folders: entry.parentID.flatMap { folderPaths[$0] })
    }

    /// Offer the clean-up only once every copy is where it belongs — mid-reorganise, a folder that
    /// looks empty may be about to be filled or emptied.
    private func noteEmptyFolders(_ tree: MediaVaultFolderTree, placements: [UUID: MediaVaultPlacement]) {
        guard MediaVaultOrganizer.moves(index: index, placements: placements, limit: 1).isEmpty else {
            emptyFolderCount = 0
            return
        }
        emptyFolderCount = tree.emptyFolders(occupied: Set(index.entries.values.compactMap(\.parentID))).count
    }

    /// Move the empty folders to Drive's trash. Asked for by the person, never automatic. Everything
    /// is listed again first, so a folder is only removed if Drive says right now that no copy is in it.
    func removeEmptyFolders() async {
        guard canUseDrive, !running else { return }
        running = true
        defer { running = false }
        do {
            let root = try await resolveFolder()
            try await loadIndex(rootID: root)
            let tree = MediaVaultFolderTree(rootID: root, folders: try await store.listFolders())
            let empty = tree.emptyFolders(occupied: Set(index.entries.values.compactMap(\.parentID)))
            guard !empty.topmost.isEmpty else { emptyFolderCount = 0; return }
            phase = .organizing(done: 0, total: empty.topmost.count)
            for (done, id) in empty.topmost.enumerated() {
                do { try await store.trash(folderID: id) } catch is CloudVaultError { }   // already gone
                phase = .organizing(done: done + 1, total: empty.topmost.count)
            }
            remember(MediaVaultFolderTree(rootID: root, folders: try await store.listFolders()))
            emptyFolderCount = 0
            phase = .idle
            note = MediaVaultText.removedFolders(empty.count)
        } catch {
            mediaVaultLog.error("vault tidy failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func remember(_ tree: MediaVaultFolderTree) {
        let paths = tree.paths()
        guard paths != folderPaths else { return }
        folderPaths = paths
        defaults.set(try? JSONEncoder().encode(paths), forKey: Key.folders)
    }

    private func setIndex(_ new: MediaVaultIndex) {
        index = new
        defaults.set(try? JSONEncoder().encode(new), forKey: Key.index)
    }

    private func resolveFolder() async throws -> String {
        if let folderID { return folderID }
        let id = try await store.folderID()
        folderID = id
        return id
    }

    /// Re-read what is in Drive (also how a restored phone learns what it can play).
    func refreshIndex() async {
        guard canUseDrive else { return }
        do {
            try await loadIndex(rootID: try await resolveFolder())
        } catch {
            mediaVaultLog.error("vault listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadIndex(rootID: String) async throws {
        let listed = MediaVaultIndex(files: try await store.listClipFiles(rootID: rootID))
        setIndex(listed.keepingRecentUploads(from: index, now: .now))
    }

    /// The folder for `path` under the root, creating what is missing (and remembering it in `tree`).
    private func ensureFolder(_ path: [String], tree: inout MediaVaultFolderTree) async throws -> String {
        var (id, missing) = tree.resolve(path)
        for name in missing {
            let created = try await store.createFolder(named: name, parent: id)
            tree.insert(MediaVaultFolder(id: created, name: name, parentID: id))
            id = created
        }
        return id
    }

    /// Where each clip's copy belongs under the chosen layout.
    func placements(context: ModelContext) -> [UUID: MediaVaultPlacement] {
        let layout = settings.layout, zone = settings.timeZone
        return MediaVaultPaths.placements(MediaVaultCatalog.infos(context: context), layout: layout, timeZone: zone)
    }

    /// Move / rename copies whose place changed (a new layout, a retag, a copy from before prompt 270).
    private func organize(_ placements: [UUID: MediaVaultPlacement], tree: inout MediaVaultFolderTree) async throws {
        let moves = MediaVaultOrganizer.moves(index: index, placements: placements, limit: Self.moveLimit)
        guard !moves.isEmpty else { return }
        phase = .organizing(done: 0, total: moves.count)
        for (done, move) in moves.enumerated() {
            let target = try await ensureFolder(move.folders, tree: &tree)
            do {
                try await store.relocate(fileID: move.fileID, name: move.name,
                                         properties: MediaVaultTag.properties(rowID: move.rowID, stamp: move.stamp),
                                         to: target, from: move.fromParentID)
            } catch is CloudVaultError {
                continue   // deleted in Drive since the listing: the next listing drops it
            }
            if var entry = index.entry(for: move.rowID) {
                entry.name = move.name
                entry.parentID = target
                entry.stamp = move.stamp
                var next = index
                next.insert(entry)
                setIndex(next)
            }
            phase = .organizing(done: done + 1, total: moves.count)
        }
    }

    // MARK: - Copy clips up

    private func clips(in context: ModelContext) async -> [MediaVaultClip] {
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []
        let rows = media.map { (id: $0.id, local: $0.localIdentifier, isVideo: $0.kind == .video) }
        let present = await exporter.present(Array(Set(rows.map(\.local))))
        // Without the whole library in view, "does not resolve" is not "is gone": call every clip
        // present, and let `libraryVisible` hold back what depends on knowing.
        let visible = await exporter.canSeeWholeLibrary()
        libraryVisible = visible
        return rows.map { MediaVaultClip(rowID: $0.id, localIdentifier: $0.local, isVideo: $0.isVideo,
                                         isOnPhone: !visible || present.contains($0.local)) }
    }

    /// Recount "N of M clips copied" without uploading anything.
    func refreshCoverage(context: ModelContext) async {
        let all = await clips(in: context)
        recount(all)
        guard !all.isEmpty else { return }
        leftoverCount = MediaVaultCleanup.plan(index: index, storeIDs: Set(all.map(\.rowID)), known: known,
                                               followDeletions: false).leftovers.count
    }

    /// Everything the screens show that follows from "which clips, and which copies".
    private func recount(_ all: [MediaVaultClip]) {
        coverage = MediaVaultPlanner.coverage(all, index: index, excluding: excluded)
        onlyInDrive = Set(all.filter { !$0.isOnPhone && index.contains($0.rowID) }.map(\.rowID))
        let here = Dictionary(grouping: libraryVisible ? all.filter { $0.isOnPhone && index.contains($0.rowID) } : [], by: \.localIdentifier)
        freeable = (here.count, here.values.reduce(Int64(0)) { $0 + ($1.first.flatMap { index.entry(for: $0.rowID)?.byteCount } ?? 0) })
    }

    /// Copy a batch of clips that are on this phone and not in the vault yet. Cheap when off.
    /// Copies wait for the running session to end (prompt 279); the status line says so.
    func sayPausedForSession() {
        guard !running else { return }
        note = MediaVaultText.skipped(.sessionRunning)
    }

    /// `sessionRunning` is asked before the pass and again before every clip (prompt 279).
    func runIfNeeded(context: ModelContext, sessionRunning: () -> Bool = { false }) async {
        guard settings.keepCopies, settings.started, !running else { return }
        let decision = MediaVaultPolicy.decide(settings: settings, signedIn: account.isSignedIn(),
                                               hasDrivePermission: account.grants(GoogleScope.driveFile),
                                               network: await network(), sessionRunning: sessionRunning())
        guard decision == .run else {
            if case let .skip(reason) = decision { note = MediaVaultText.skipped(reason) }
            return
        }
        running = true
        defer { running = false }
        note = nil
        if settings.timeZoneID == nil { update { $0.timeZoneID = TimeZone.current.identifier } }
        do {
            let root = try await resolveFolder()
            var tree = MediaVaultFolderTree(rootID: root, folders: try await store.listFolders())
            try await loadIndex(rootID: root)
            let all = await clips(in: context)
            let placements = placements(context: context)
            await cleanUp(storeIDs: Set(all.map(\.rowID)))
            recount(all)
            try await organize(placements, tree: &tree)
            remember(tree)
            let batch = MediaVaultPlanner.toUpload(all, index: index, excluding: excluded)
            noteEmptyFolders(tree, placements: placements)
            guard !batch.isEmpty else { phase = .idle; return }
            guard libraryVisible else {   // the originals cannot be read: say so instead of failing clip by clip
                phase = .idle
                note = MediaVaultText.skipped(.needsPhotos)
                return
            }
            phase = .working(done: 0, total: batch.count)
            var failed = 0, failedInARow = 0
            for (done, clip) in batch.enumerated() {
                guard settings.keepCopies else { break }   // switched off mid-pass: pause here
                // A long pass can outlive the Wi-Fi it started on, and a session can start during it.
                if done > 0, case let .skip(reason) = MediaVaultPolicy.decide(
                    settings: settings, signedIn: account.isSignedIn(),
                    hasDrivePermission: account.grants(GoogleScope.driveFile), network: await network(),
                    sessionRunning: sessionRunning()) {
                    phase = .idle
                    note = MediaVaultText.skipped(reason)
                    return
                }
                do {
                    let exported = try await exporter.export(localIdentifier: clip.localIdentifier)
                    defer { try? FileManager.default.removeItem(at: exported.url) }
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let entry = try await put(exported.url, fileExtension: exported.fileExtension, rowID: clip.rowID,
                                              byteCount: bytes, placement: placements[clip.rowID], tree: &tree,
                                              wifiOnly: settings.wifiOnly)
                    var next = index
                    next.insert(entry)
                    setIndex(next)
                    remember(tree)
                    failedInARow = 0
                } catch where CloudBackupNetwork.isNetworkLoss(error) {
                    // The network went, or iOS refused to send over mobile data: wait, do not
                    // export the next clip only to have it refused too (prompt 281).
                    phase = .idle
                    note = MediaVaultText.skipped(settings.wifiOnly ? .waitingForWiFi : .offline)
                    return
                } catch {
                    // One clip that will not export or upload must not hold up the rest.
                    failed += 1
                    failedInARow += 1
                    mediaVaultLog.error("vault copy skipped a clip: \(error.localizedDescription, privacy: .public)")
                    if failedInARow >= Self.failuresInARowBeforeStopping { throw error }
                }
                recount(all)
                phase = .working(done: done + 1, total: batch.count)
            }
            noteEmptyFolders(tree, placements: placements)
            phase = .idle
            note = MediaVaultText.couldNotCopy(failed)
        } catch {
            mediaVaultLog.error("vault copy failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Upload one clip's bytes to its place. With no placement (the clip is unknown to the store)
    /// it goes to the root under its id and is left unplaced, so a later pass files it.
    private func put(_ file: URL, fileExtension: String, rowID: UUID, byteCount: Int64,
                       placement: MediaVaultPlacement?, tree: inout MediaVaultFolderTree,
                       wifiOnly: Bool = false) async throws -> MediaVaultEntry {
        let name = placement?.fileName(fileExtension: fileExtension)
            ?? MediaVaultNaming.fileName(rowID: rowID, fileExtension: fileExtension)
        let folder = try await ensureFolder(placement?.folders ?? [], tree: &tree)
        let md5 = try? await MediaVaultHash.md5(of: file)   // without it the copy is measured again before a free-up
        let fileID = try await store.upload(file, name: name, folderID: folder,
                                            properties: MediaVaultTag.properties(rowID: rowID, stamp: placement?.stamp,
                                                                                 bytes: byteCount, md5: md5),
                                            wifiOnly: wifiOnly)
        return MediaVaultEntry(rowID: rowID, fileID: fileID, name: name, byteCount: byteCount,
                               parentID: folder, stamp: placement?.stamp, addedAt: .now, sentBytes: byteCount, sentMD5: md5)
    }

    // MARK: - Fetch for playback

    /// How a clip that is not in Photos can be shown right now.
    func source(for rowID: UUID) -> MediaSource {
        let entry = index.entry(for: rowID)
        let cached = entry.map { FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent($0.cacheName).path) } ?? false
        return .resolve(isOnPhone: false, isCached: cached, isInVault: entry != nil)
    }

    /// A local file for a vaulted clip: the cached copy, or a fresh download. Concurrent callers for
    /// one clip share the download.
    func localURL(for rowID: UUID) async throws -> URL {
        guard let entry = index.entry(for: rowID) else { throw CloudVaultError.notFound(rowID.uuidString) }
        let target = cacheDirectory.appendingPathComponent(entry.cacheName)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: target.path)
            return target
        }
        if let existing = fetching[rowID] { return try await existing.value }
        let store = store, directory = cacheDirectory
        let task = Task { () throws -> URL in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = directory.appendingPathComponent(".\(entry.cacheName).part")
            try await store.download(fileID: entry.fileID, to: partial)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            return target
        }
        fetching[rowID] = task
        defer { fetching[rowID] = nil }
        do {
            let url = try await task.value
            trimCache(keeping: entry.cacheName)
            return url
        } catch let error as CloudVaultError {
            if case .notFound = error { forget(rowID) }   // deleted in Drive: stop promising it
            throw error
        }
    }

    /// The copy turned out not to be in Drive any more.
    private func forget(_ rowID: UUID) {
        var next = index
        next.remove(rowID)
        setIndex(next)
        onlyInDrive.remove(rowID)
    }

    /// What a clip's surface plays when the clip is not in Photos.
    enum Playback {
        case file(URL)
        /// A large video, read from Drive piece by piece as the player asks.
        case stream(AVURLAsset)
    }

    #if DEBUG
    @ObservationIgnored private var roundTripStarted = false

    /// Device check for free-up → play from Drive → bring back (prompts 274–277), run with the launch
    /// argument `-vaultRoundTripProbe`. It really removes ONE original from Photos (the smallest
    /// copied video of at least 1 MB that no other clip or Studio project uses; iOS asks first and
    /// keeps it in Recently Deleted for 30 days) and brings it back. The outcome is left in
    /// UserDefaults under `mediaVault.roundTripProbe`.
    func roundTripProbe(context: ModelContext) async {
        guard !roundTripStarted else { return }
        roundTripStarted = true
        var lines: [String] = []
        func finish() {
            defaults.set(lines.joined(separator: " | "), forKey: "mediaVault.roundTripProbe")
            defaults.synchronize()
            mediaVaultLog.notice("round trip probe: \(lines.joined(separator: " | "), privacy: .public)")
        }
        func stamp(_ date: Date?) -> String { date.map { ISO8601DateFormatter().string(from: $0) } ?? "none" }
        defaults.set("running", forKey: "mediaVault.roundTripProbe")
        guard canUseDrive else { lines.append("FAIL not signed in to Google with Drive access"); return finish() }
        do {
            try await loadIndex(rootID: try await resolveFolder())
            let items = await freeUpItems(context: context)
            let inStudio = clipsUsedInStudio(context: context)
            let shared = Dictionary(grouping: items, by: \.asset).filter { $0.value.count > 1 }
            guard let item = items.filter({ item in
                shared[item.asset] == nil && !inStudio.contains(item.id) && item.bytes >= 1_000_000
                    && ["mov", "mp4", "m4v"].contains(index.entry(for: item.id)?.fileExtension ?? "")
            }).min(by: { $0.bytes < $1.bytes }) else { lines.append("FAIL no suitable clip"); return finish() }
            let media = try context.fetch(FetchDescriptor<SessionMedia>()).first { $0.id == item.id }
            let originalDate = await exporter.creationDate(of: item.asset)
            lines.append("clip bytes=\(item.bytes) activity=\(item.activity) originalDate=\(stamp(originalDate)) recorded=\(stamp(media?.linkCapturedAt)) derived=\(stamp(item.capturedAt))")
            defaults.set("waiting for the iOS delete prompt | " + lines.joined(separator: " | "), forKey: "mediaVault.roundTripProbe")

            await freeUpSpace(context: context, only: [item.id])
            lines.append("freeUp: \(note ?? "no note")")
            guard onlyInDrive.contains(item.id) else { lines.insert("FAIL the clip did not leave the phone", at: 0); return finish() }
            let stillThere = await exporter.present([item.asset]).contains(item.asset)
            lines.append("goneFromPhotos=\(!stillThere) thumbnailKept=\(FileManager.default.fileExists(atPath: MediaVaultPosters.url(for: item.asset, in: posterDirectory).path))")

            var clock = Date()
            switch try await playback(for: item.id, isVideo: true) {
            case .file(let url):
                let md5 = try await MediaVaultHash.md5(of: url)
                lines.append("playback=download in \(Int(Date().timeIntervalSince(clock) * 1000))ms matchesDriveChecksum=\(md5 == index.entry(for: item.id)?.md5)")
                let asset = AVURLAsset(url: url)
                lines.append("playable=\(try await asset.load(.isPlayable)) duration=\(String(format: "%.2f", try await asset.load(.duration).seconds))s")
            case .stream(let asset):
                lines.append("playback=stream playable=\(try await asset.load(.isPlayable)) duration=\(String(format: "%.2f", try await asset.load(.duration).seconds))s in \(Int(Date().timeIntervalSince(clock) * 1000))ms")
            }

            clock = Date()
            try await bringBack(item.id, context: context)
            let after = try context.fetch(FetchDescriptor<SessionMedia>()).first { $0.id == item.id }
            let newAsset = after?.localIdentifier ?? ""
            let newDate = await exporter.creationDate(of: newAsset)
            let back = await exporter.present([newAsset]).contains(newAsset)
            lines.append("broughtBack=\(back) newAsset=\(newAsset != item.asset) in \(Int(Date().timeIntervalSince(clock) * 1000))ms")
            lines.append("photosAssigned=\(stamp(lastRestoredDate?.assigned)) fallbackSet=\(stamp(lastRestoredDate?.corrected)) finalDate=\(stamp(newDate))")
            if let originalDate, let newDate {
                lines.append("dateDiffFromOriginal=\(String(format: "%.1f", newDate.timeIntervalSince(originalDate)))s")
            }
            lines.append("stillCopied=\(contains(item.id)) onlyInDrive=\(onlyInDrive.contains(item.id)) thumbnailRemoved=\(!FileManager.default.fileExists(atPath: MediaVaultPosters.url(for: item.asset, in: posterDirectory).path))")
            await refreshCoverage(context: context)
            lines.insert(back && newDate != nil ? "OK" : "FAIL", at: 0)
        } catch {
            lines.insert("FAIL \(error.localizedDescription)", at: 0)
        }
        finish()
    }

    /// Device check for the paths that need something to be deleted (prompts 274, 277), run with
    /// `-vaultExtrasProbe`. It never touches a real clip:
    /// 1. saves a small generated image with no capture date into Photos, checks the date fallback
    ///    re-dates it, and removes it again (iOS asks);
    /// 2. adds a temporary second clip row for an existing video, copies it to Drive, deletes the
    ///    row and checks the copy follows it to Drive's trash;
    /// 3. the same with a row this phone never "knew", which must only be OFFERED, then removes it
    ///    with "Remove these copies".
    /// The outcome is left in UserDefaults under `mediaVault.extrasProbe`.
    func extrasProbe(context: ModelContext) async {
        guard !roundTripStarted else { return }
        roundTripStarted = true
        var lines: [String] = []
        func save() { defaults.set(lines.joined(separator: " | "), forKey: "mediaVault.extrasProbe"); defaults.synchronize() }
        func stamp(_ date: Date?) -> String { date.map { ISO8601DateFormatter().string(from: $0) } ?? "none" }
        func inTrash(_ rowID: UUID) async -> Int {
            let q = "appProperties has { key='\(MediaVaultTag.clipKey)' and value='\(rowID.uuidString.lowercased())' } and trashed = true"
            return (try? GoogleDriveAPI.sizedPage(from: try await google.send(GoogleDriveAPI.query(q)).0).files.count) ?? -1
        }
        defaults.set("running", forKey: "mediaVault.extrasProbe")
        guard canUseDrive else { lines.append("FAIL not signed in"); return save() }

        // 1. The date fallback on a real Photos asset.
        do {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("snappet-date-test-\(UUID().uuidString).png")
            try image.pngData()?.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let started = Date.now
            let asset = try await exporter.save(file: file, isVideo: false)
            let assigned = await exporter.creationDate(of: asset)
            let known = Date(timeIntervalSince1970: 1_709_294_400)   // 2024-03-01 12:00 UTC
            let correction = MediaVaultRestoreDate.correction(assigned: assigned, saveStarted: started, saveEnded: .now, known: known)
            if let correction { try await exporter.setCreationDate(correction, of: asset) }
            let final = await exporter.creationDate(of: asset)
            lines.append("DATE photosAssigned=\(stamp(assigned)) savedAt=\(stamp(started)) fallbackChose=\(stamp(correction)) finalDate=\(stamp(final)) \(final == known ? "OK" : "FAIL")")
            save()
            do { try await exporter.delete(localIdentifiers: [asset]); lines.append("testImageRemoved=true") }
            catch { lines.append("testImageRemoved=false (still in Photos, dated 2024-03-01)") }
        } catch {
            lines.append("DATE FAIL \(error.localizedDescription)")
        }
        save()

        // 2 and 3. Throwaway clip rows.
        do {
            let root = try await resolveFolder()
            try await loadIndex(rootID: root)
            let items = await freeUpItems(context: context)
            guard let model = items.filter({ $0.bytes >= 1_000_000 && ["mov", "mp4", "m4v"].contains(index.entry(for: $0.id)?.fileExtension ?? "") })
                .min(by: { $0.bytes < $1.bytes }),
                  let original = try context.fetch(FetchDescriptor<SessionMedia>()).first(where: { $0.id == model.id }) else {
                lines.append("TRASH FAIL no clip to model the throwaway on"); return save()
            }
            let before = Self.storeIDs(context).count
            let preexisting = MediaVaultCleanup.plan(index: index, storeIDs: Self.storeIDs(context), known: [], followDeletions: false).leftovers.count

            func throwaway(offset: Double) async throws -> UUID {
                let row = SessionMedia(sessionID: original.sessionID, localIdentifier: original.localIdentifier, kind: .video,
                                       offsetSec: original.offsetSec + offset, durationSec: original.durationSec)
                context.insert(row)
                try context.save()
                var tree = MediaVaultFolderTree(rootID: root, folders: try await store.listFolders())
                let exported = try await exporter.export(localIdentifier: original.localIdentifier)
                defer { try? FileManager.default.removeItem(at: exported.url) }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? NSNumber)?.int64Value ?? 0
                let entry = try await put(exported.url, fileExtension: exported.fileExtension, rowID: row.id, byteCount: bytes,
                                          placement: placements(context: context)[row.id], tree: &tree)
                var next = index
                next.insert(entry)
                setIndex(next)
                return row.id
            }
            func delete(_ id: UUID) throws {
                if let row = try context.fetch(FetchDescriptor<SessionMedia>()).first(where: { $0.id == id }) { context.delete(row) }
                try context.save()
            }

            // 2. Known to this phone, then deleted: its copy follows without asking.
            let followed = try await throwaway(offset: 1)
            await cleanUp(storeIDs: Self.storeIDs(context))          // a pass ends: the phone now "knows" the row
            let copiedName = index.entry(for: followed)?.name ?? "?"
            try delete(followed)
            await cleanUp(storeIDs: Self.storeIDs(context))          // the next pass begins
            let followedTrash = await inTrash(followed)
            lines.append("FOLLOW copy=\(copiedName) removeWithClip=\(settings.removeWithClip) stillIndexed=\(contains(followed)) inDriveTrash=\(followedTrash) \(!contains(followed) && followedTrash == 1 ? "OK" : "FAIL")")
            save()

            // 3. Never known to this phone: only offered, then removed when asked.
            if preexisting == 0 {
                let stray = try await throwaway(offset: 2)
                try delete(stray)
                await cleanUp(storeIDs: Self.storeIDs(context))
                let offered = leftoverCount, keptForNow = contains(stray)
                await removeLeftovers(context: context)
                let strayTrash = await inTrash(stray)
                lines.append("LEFTOVER offered=\(offered) notRemovedUntilAsked=\(keptForNow) afterRemove: stillIndexed=\(contains(stray)) inDriveTrash=\(strayTrash) note=\(note ?? "none") \(offered == 1 && keptForNow && !contains(stray) && strayTrash == 1 ? "OK" : "FAIL")")
            } else {
                lines.append("LEFTOVER skipped: \(preexisting) real leftover copies exist and would be removed too")
            }
            let after = Self.storeIDs(context).count
            lines.append("clipRowsBefore=\(before) after=\(after) originalStillCopied=\(contains(model.id)) \(before == after && contains(model.id) ? "OK" : "FAIL")")
            await refreshCoverage(context: context)
        } catch {
            lines.append("TRASH FAIL \(error.localizedDescription)")
        }
        lines.insert(lines.contains { $0.contains("FAIL") } ? "FAIL" : "OK", at: 0)
        save()
        mediaVaultLog.notice("extras probe: \(lines.joined(separator: " | "), privacy: .public)")
    }

    /// Device check for streaming (prompt 276), run with the launch argument `-vaultStreamProbe`.
    /// READ-ONLY: lists the copies, reads two byte ranges of the largest video and opens it through
    /// the stream loader far enough to decode one frame. The outcome is left in UserDefaults under
    /// `mediaVault.streamProbe` for the Mac to read.
    func streamProbe() async {
        var lines: [String] = []
        func finish() {
            defaults.set(lines.joined(separator: " | "), forKey: "mediaVault.streamProbe")
            defaults.synchronize()
            mediaVaultLog.notice("stream probe: \(lines.joined(separator: " | "), privacy: .public)")
        }
        defaults.set("running", forKey: "mediaVault.streamProbe")
        guard canUseDrive else { lines.append("FAIL not signed in to Google with Drive access"); return finish() }
        do {
            try await loadIndex(rootID: try await resolveFolder())
            let entries = Array(index.entries.values)
            lines.append("copies=\(entries.count) withDriveChecksum=\(entries.filter { $0.md5 != nil }.count) withSentChecksum=\(entries.filter { $0.sentMD5 != nil }.count)")
            guard let entry = entries.filter({ ["mov", "mp4", "m4v"].contains($0.fileExtension) }).max(by: { $0.byteCount < $1.byteCount }) else {
                lines.append("FAIL no video copy to probe"); return finish()
            }
            lines.append("file=\(entry.fileExtension) bytes=\(entry.byteCount)")
            let reader = MediaVaultRangeReader(google: google, fileID: entry.fileID, total: entry.byteCount)
            var clock = Date()
            let head = try await reader.read(0..<min(entry.byteCount, 2))
            lines.append("first2=\(head.count)B in \(Int(Date().timeIntervalSince(clock) * 1000))ms")
            let middle = entry.byteCount / 2
            clock = Date()
            let piece = try await reader.read(middle..<min(entry.byteCount, middle + MediaVaultFetch.chunkBytes))
            lines.append("middle=\(piece.count)B in \(Int(Date().timeIntervalSince(clock) * 1000))ms")
            clock = Date()
            let asset = MediaVaultStream.asset(reader: reader, fileExtension: entry.fileExtension)
            let duration = try await asset.load(.duration).seconds
            let playable = try await asset.load(.isPlayable)
            lines.append("duration=\(String(format: "%.2f", duration))s playable=\(playable) opened in \(Int(Date().timeIntervalSince(clock) * 1000))ms")
            clock = Date()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: CMTime(seconds: duration / 2, preferredTimescale: 600)).image
            lines.append("frameAtMiddle=\(frame.width)x\(frame.height) in \(Int(Date().timeIntervalSince(clock) * 1000))ms")
            lines.insert("OK", at: 0)
        } catch {
            lines.insert("FAIL \(error.localizedDescription)", at: 0)
        }
        finish()
    }
    #endif

    /// The person chose to fetch this clip over cellular.
    func allowOnCellular(_ rowID: UUID) { allowedOnCellular.insert(rowID) }

    /// How this clip would be fetched, and what stands in the way (nothing: nil).
    func fetchPlan(for rowID: UUID, isVideo: Bool) async -> (mode: MediaVaultFetch.Mode, blocked: MediaVaultFetch.Blocked?) {
        guard let entry = index.entry(for: rowID) else { return (.download, .gone) }
        let cached = FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(entry.cacheName).path)
        let mode = MediaVaultFetch.mode(isVideo: isVideo, byteCount: entry.byteCount, isCached: cached, streamAbove: streamAbove)
        let blocked = MediaVaultFetch.blocked(mode: mode, canUseDrive: canUseDrive, wifiOnly: settings.wifiOnly,
                                              network: mode == .cached ? .wifi : await network(),
                                              allowed: allowedOnCellular.contains(rowID), bytes: entry.byteCount)
        return (mode, blocked)
    }

    /// The clip, ready to play: a cached or freshly downloaded file, or a stream for a large video.
    /// Throws `MediaVaultFetch.Blocked` when it cannot be fetched now.
    func playback(for rowID: UUID, isVideo: Bool) async throws -> Playback {
        let plan = await fetchPlan(for: rowID, isVideo: isVideo)
        if let blocked = plan.blocked { throw blocked }
        guard let entry = index.entry(for: rowID) else { throw MediaVaultFetch.Blocked.gone }
        do {
            if plan.mode == .stream {
                // Ask for the first bytes now, so a copy that is gone is said here and not as a dead player.
                let reader = MediaVaultRangeReader(google: google, fileID: entry.fileID, total: entry.byteCount)
                _ = try await reader.read(0..<min(entry.byteCount, 2))
                return .stream(MediaVaultStream.asset(reader: reader, fileExtension: entry.fileExtension))
            }
            return .file(try await localURL(for: rowID))
        } catch let error as CloudVaultError {
            if case .notFound = error { forget(rowID); throw MediaVaultFetch.Blocked.gone }
            throw error
        } catch GoogleAuthError.signedOut {
            throw MediaVaultFetch.Blocked.signedOut   // the sign-in lapsed: say so, not "couldn't load"
        }
    }

    private func trimCache(keeping: String) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> MediaVaultCache.File? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return .init(name: url.lastPathComponent, byteCount: Int64(values.fileSize ?? 0),
                             lastUsed: values.contentModificationDate ?? .distantPast)
            }
        for name in MediaVaultCache.toEvict(files, keeping: keeping) {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Bring clips back from Google Photos

    func beginGooglePick() async throws -> GooglePhotosPickerAPI.Session {
        try GooglePhotosPickerAPI.session(from: try await google.send(GooglePhotosPickerAPI.createSession()).0)
    }

    /// Wait until the person finishes picking in Google Photos, then return the picks. Cancelling the
    /// task stops the wait. `sleep` is injectable so tests don't wait.
    func waitForPicks(_ session: GooglePhotosPickerAPI.Session,
                      sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })
        async throws -> [GooglePickedItem] {
        var waited: TimeInterval = 0
        var current = session
        while !current.mediaItemsSet {
            guard waited < session.timeout else { throw GoogleAuthError.cancelled }
            try await sleep(session.pollInterval)
            waited += session.pollInterval
            current = try GooglePhotosPickerAPI.session(
                from: try await google.send(GooglePhotosPickerAPI.getSession(id: session.id)).0, fallback: session)
        }
        var items: [GooglePickedItem] = []
        var token: String?
        repeat {
            let page = try GooglePhotosPickerAPI.items(
                from: try await google.send(GooglePhotosPickerAPI.listItems(sessionID: session.id, pageToken: token)).0)
            items += page.items
            token = page.nextPageToken
        } while token != nil
        _ = try? await google.send(GooglePhotosPickerAPI.deleteSession(id: session.id))
        return items
    }

    struct ImportResult: Equatable, Sendable {
        var saved = 0
        var unmatched = 0
        var failed = 0
        var message: String { MediaVaultText.importOutcome(saved: saved, unmatched: unmatched, failed: failed) }
    }

    /// Check each pick against the missing clips and copy the matches Google Photos → Drive. Nothing
    /// is written to this phone's Photos; nothing is attached on a guess.
    func importFromGoogle(_ picks: [GooglePickedItem], missing: [MediaLinkRow],
                          placements: [UUID: MediaVaultPlacement] = [:]) async -> ImportResult {
        let plan = GoogleImportPlanner.plan(missing: missing, picks: picks, alreadyInVault: Set(index.entries.keys))
        var result = ImportResult(unmatched: plan.unmatchedPickCount)
        guard !plan.matches.isEmpty else { return result }
        let ordered = plan.matches.sorted { $0.key.uuidString < $1.key.uuidString }
        phase = .working(done: 0, total: ordered.count)
        defer { phase = .idle }
        guard let root = try? await resolveFolder(), let folders = try? await store.listFolders() else {
            result.failed = ordered.count
            return result
        }
        var tree = MediaVaultFolderTree(rootID: root, folders: folders)
        for (done, (rowID, item)) in ordered.enumerated() {
            let ext = MediaVaultNaming.fileExtension(isVideo: item.isVideo, mimeType: item.mimeType, fileName: item.fileName)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gpick-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                guard let url = item.downloadURL else { throw GoogleAuthError.badResponse }
                try await google.download(URLRequest(url: url), to: temporary)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
                let entry = try await put(temporary, fileExtension: ext, rowID: rowID, byteCount: bytes,
                                            placement: placements[rowID], tree: &tree)
                var next = index
                next.insert(entry)
                setIndex(next)
                result.saved += 1
            } catch {
                mediaVaultLog.error("google import failed: \(error.localizedDescription, privacy: .public)")
                result.failed += 1
            }
            phase = .working(done: done + 1, total: ordered.count)
        }
        return result
    }
}

// MARK: - What each clip's Drive path is made from (prompt 270, the store edge)

/// Reads the facts a clip's place is built from. The session's activity is resolved the way the
/// Clips tab resolves it (`ClipActivity`): a festival night, a Kilter session, a Health import by
/// its workout type, else the most common exercise activity.
@MainActor
enum MediaVaultCatalog {
    static func infos(context: ModelContext) -> [UUID: MediaVaultClipInfo] {
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []
        guard !media.isEmpty else { return [:] }
        let filmed = Set(media.map(\.sessionID))

        let lineups = Dictionary(((try? context.fetch(FetchDescriptor<FestivalLineup>())) ?? []).map { ($0.packID, $0.name) },
                                 uniquingKeysWith: { first, _ in first })
        let nights = Dictionary(((try? context.fetch(FetchDescriptor<FestivalAttendance>())) ?? []).map { ($0.sessionID, $0.packID) },
                                uniquingKeysWith: { first, _ in first })
        var artists: [UUID: String] = [:]
        for tag in ((try? context.fetch(FetchDescriptor<FestivalClipTag>())) ?? []) where tag.isResolved && !tag.artist.isEmpty {
            artists[tag.mediaID] = tag.artist
        }

        struct Facts { var startedAt: Date; var activity: ClipActivity.Activity; var festival: String? }
        var sessions: [UUID: Facts] = [:]
        for kilter in ((try? context.fetch(FetchDescriptor<KilterSession>())) ?? []) where filmed.contains(kilter.id) {
            sessions[kilter.id] = Facts(startedAt: kilter.startedAt, activity: .climbing)
        }
        for workout in ((try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []) where filmed.contains(workout.id) {
            guard sessions[workout.id] == nil else { continue }
            if let pack = nights[workout.id] {
                sessions[workout.id] = Facts(startedAt: workout.startedAt, activity: .festival, festival: lineups[pack])
            } else {
                let activity = workout.isImportedFromHealth ? ClipActivity.forImportLabel(workout.routineName)
                    : ClipActivity.dominant(workout.exercises.map { ClipActivity.forExercise($0.discipline) })
                sessions[workout.id] = Facts(startedAt: workout.startedAt, activity: activity)
            }
        }

        var out: [UUID: MediaVaultClipInfo] = [:]
        for clip in media {
            if let session = sessions[clip.sessionID] {
                out[clip.id] = MediaVaultClipInfo(capturedAt: session.startedAt.addingTimeInterval(max(0, clip.offsetSec)),
                                                  sessionStartedAt: session.startedAt, activity: session.activity.label,
                                                  festival: session.festival, artist: artists[clip.id])
            } else {   // its session is gone: file it by when the row was made
                out[clip.id] = MediaVaultClipInfo(capturedAt: clip.createdAt, sessionStartedAt: clip.createdAt,
                                                  activity: ClipActivity.Activity.general.label, artist: artists[clip.id])
            }
        }
        return out
    }
}

extension EnvironmentValues {
    /// The clip vault, for surfaces that play clips (set once at the app shell).
    @Entry var mediaVault: MediaVaultService? = nil
}
