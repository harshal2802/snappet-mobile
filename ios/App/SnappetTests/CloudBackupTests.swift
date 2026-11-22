import CryptoKit
import SwiftData
import XCTest
@testable import Snappet

/// Automatic cloud backup (cloud-connect P2, prompt 267) — the pure core: when to upload, what to
/// keep, what to offer a fresh install, sealing, and heart-rate stripping.
final class CloudBackupTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ change: (inout CloudBackupPolicy.Input) -> Void = { _ in }) -> CloudBackupPolicy.Input {
        var i = CloudBackupPolicy.Input(settings: CloudBackupSettings(destination: .iCloud),
                                        accountAvailable: true, network: .wifi, recordCount: 10,
                                        contentHash: "new", lastUploadedHash: "old",
                                        lastUploadAt: now.addingTimeInterval(-3600), now: now)
        change(&i)
        return i
    }

    private func manifest(_ name: String, device: String = "A", at offset: TimeInterval = 0,
                          hash: String = "h", records: Int = 5) -> CloudBackupManifest {
        CloudBackupManifest(fileName: name, createdAt: now.addingTimeInterval(offset), deviceID: device,
                            deviceName: "iPhone", contentHash: hash, byteCount: 100, recordCount: records,
                            sessionCount: 2, clipCount: 3, backupFormatVersion: 1, includesHeartRate: false)
    }

    // MARK: - Defaults are opt-in

    func testDefaultsKeepEverythingOnThePhone() {
        let settings = CloudBackupSettings()
        XCTAssertEqual(settings.destination, .off)
        XCTAssertFalse(settings.includeHeartRate)
        XCTAssertTrue(settings.wifiOnly)
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.settings = settings }), .skip(.off))
    }

    // MARK: - When to upload

    func testChangedStoreOnWiFiUploads() {
        XCTAssertEqual(CloudBackupPolicy.decide(input()), .upload)
    }

    func testEachGuardSkipsWithItsReason() {
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.storeHealthy = false }), .skip(.storeUnhealthy))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.accountAvailable = false }), .skip(.noAccount))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.recordCount = 0 }), .skip(.nothingToBackUp))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.lastUploadedHash = "new" }), .skip(.unchanged))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.network = .offline }), .skip(.offline))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.network = .cellular }), .skip(.waitingForWiFi))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.lastUploadAt = self.now.addingTimeInterval(-60) }),
                       .skip(.tooSoon))
    }

    func testOnlyUnmeteredWiFiOrCableCountsAsWiFi() {
        func kind(_ connected: Bool, _ wifi: Bool, _ expensive: Bool) -> CloudBackupNetwork {
            .classify(connected: connected, overWiFiOrCable: wifi, isExpensive: expensive)
        }
        XCTAssertEqual(kind(true, true, false), .wifi)
        XCTAssertEqual(kind(true, false, true), .cellular, "ordinary mobile data")
        XCTAssertEqual(kind(true, false, false), .cellular, "5G that iOS calls inexpensive is still mobile data (prompt 281)")
        XCTAssertEqual(kind(true, true, true), .cellular, "a personal hotspot is someone's mobile data")
        XCTAssertEqual(kind(false, true, false), .offline)
        XCTAssertEqual(kind(false, false, false), .offline)
    }

    func testLowDataModeOnWiFiPausesAutomaticWorkOnly() {
        func kind(wifi: Bool, expensive: Bool = false) -> CloudBackupNetwork {
            .classify(connected: true, overWiFiOrCable: wifi, isExpensive: expensive, isConstrained: true)
        }
        XCTAssertEqual(kind(wifi: true), .lowData)
        XCTAssertEqual(kind(wifi: false, expensive: true), .cellular, "on mobile data the Wi-Fi rule decides")
        XCTAssertEqual(kind(wifi: true, expensive: true), .cellular)

        var on = CloudBackupSettings(); on.destination = .iCloud
        XCTAssertEqual(CloudBackupPolicy.precheck(settings: on, storeHealthy: true, sessionRunning: false,
                                                  network: .lowData, manual: false), .lowDataMode)
        XCTAssertNil(CloudBackupPolicy.precheck(settings: on, storeHealthy: true, sessionRunning: false,
                                                network: .lowData, manual: true), "Back up now is the person asking")
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.network = .lowData }), .skip(.lowDataMode))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.network = .lowData; $0.manual = true }), .upload)
        XCTAssertEqual(CloudBackupStatusText.skipped(.lowDataMode), "Paused in Low Data Mode.")
    }

    func testWhichFailuresMeanTheNetworkWent() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed] {
            XCTAssertTrue(CloudBackupNetwork.isNetworkLoss(URLError(code)), "\(code)")
        }
        XCTAssertFalse(CloudBackupNetwork.isNetworkLoss(URLError(.badServerResponse)))
        XCTAssertFalse(CloudBackupNetwork.isNetworkLoss(GoogleAuthError.badResponse))
    }

    func testCellularUploadsWhenWiFiOnlyIsOff() {
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.network = .cellular; $0.settings.wifiOnly = false }),
                       .upload)
    }

    func testBackUpNowSkipsOnlyTheSpacingRule() {
        XCTAssertEqual(CloudBackupPolicy.decide(input {
            $0.manual = true; $0.lastUploadAt = self.now.addingTimeInterval(-60) }), .upload)
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.manual = true; $0.network = .cellular }),
                       .skip(.waitingForWiFi))
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.manual = true; $0.lastUploadedHash = "new" }),
                       .skip(.unchanged))
    }

    func testAClockSetBackwardsDoesNotBlockBackupsForever() {
        XCTAssertEqual(CloudBackupPolicy.decide(input { $0.lastUploadAt = self.now.addingTimeInterval(86_400) }),
                       .upload)
    }

    // MARK: - Generations

    func testKeepsNewestThreePerDeviceAndNeverTouchesAnotherDevice() {
        let all = [manifest("a1", at: -400), manifest("a2", at: -300), manifest("a3", at: -200),
                   manifest("a4", at: -100), manifest("a5", at: 0),
                   manifest("b1", device: "B", at: -9000), manifest("b2", device: "B", at: -8000)]
        XCTAssertEqual(CloudBackupPolicy.toDelete(all.shuffled(), deviceID: "A").map(\.fileName), ["a2", "a1"])
        XCTAssertTrue(CloudBackupPolicy.toDelete(all, deviceID: "C").isEmpty)
    }

    // MARK: - Restore offer

    func testOffersTheNewestBackupOnlyToAnEmptyInstall() {
        let all = [manifest("old", at: -500, hash: "h1"), manifest("new", at: 0, hash: "h2")]
        XCTAssertEqual(CloudBackupPolicy.restoreOffer(all, localUserRecordCount: 0, declinedHashes: [])?.fileName, "new")
        XCTAssertNil(CloudBackupPolicy.restoreOffer(all, localUserRecordCount: 4, declinedHashes: []),
                     "an install with records is never offered a replace-everything restore")
    }

    func testADeclinedBackupIsNotOfferedAgainAndEmptyOnesNever() {
        let all = [manifest("old", at: -500, hash: "h1"), manifest("new", at: 0, hash: "h2"),
                   manifest("empty", at: 100, hash: "h3", records: 0)]
        XCTAssertEqual(CloudBackupPolicy.restoreOffer(all, localUserRecordCount: 0, declinedHashes: ["h2"])?.fileName, "old")
        XCTAssertNil(CloudBackupPolicy.restoreOffer(all, localUserRecordCount: 0, declinedHashes: ["h1", "h2"]))
    }

    // MARK: - Naming

    func testPayloadNamesSortByTimeAndCarryTheDevice() {
        let name = CloudBackupNaming.payloadName(createdAt: Date(timeIntervalSince1970: 1_795_122_240),
                                                 deviceID: "1A2B3C4D-5E6F-0000-0000-000000000000")
        XCTAssertEqual(name, "snappet-20261119T210400Z-1a2b3c4d.snpbak")
        XCTAssertEqual(CloudBackupNaming.manifestName(forPayload: name), name + ".manifest.json")
        XCTAssertTrue(CloudBackupNaming.isManifest(name + ".manifest.json"))
        XCTAssertFalse(CloudBackupNaming.isManifest(name))
    }

    // MARK: - Sealing

    func testSealedBytesOpenWithTheKeyAndHideThePlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = Data("{\"kind\":\"snappet.backup\",\"journal\":\"private words\"}".utf8)
        let sealed = try CloudBackupCrypto.seal(plain, key: key)
        XCTAssertNil(sealed.range(of: Data("private words".utf8)), "the cloud never sees plain records")
        XCTAssertEqual(try CloudBackupCrypto.open(sealed, key: key), plain)
        XCTAssertNotEqual(try CloudBackupCrypto.seal(plain, key: key), sealed, "a fresh nonce every time")
    }

    func testWrongKeyTamperingAndForeignFilesAreRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var sealed = try CloudBackupCrypto.seal(Data("payload".utf8), key: key)
        XCTAssertThrowsError(try CloudBackupCrypto.open(sealed, key: SymmetricKey(size: .bits256))) {
            XCTAssertEqual($0 as? CloudBackupCryptoError, .wrongKeyOrDamaged)
        }
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try CloudBackupCrypto.open(sealed, key: key)) {
            XCTAssertEqual($0 as? CloudBackupCryptoError, .wrongKeyOrDamaged)
        }
        XCTAssertThrowsError(try CloudBackupCrypto.open(Data("{\"json\":true}".utf8), key: key)) {
            XCTAssertEqual($0 as? CloudBackupCryptoError, .notASnappetBackup)
        }
    }

    // MARK: - Payload + heart rate

    @MainActor
    func testPayloadLeavesHeartRateSamplesOutUnlessAskedAndHashesStably() throws {
        let container = try ModelContainer(for: Schema(SnappetSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let series = [HRPoint(t: 0, bpm: 101, rrIntervalsMs: [612]), HRPoint(t: 1, bpm: 143)]
        context.insert(WorkoutSession(routineName: "Bouldering", completedAt: .now, hrSeries: series, maxHR: 181))
        context.insert(KilterSession(angle: 40, source: "manual", hrSeries: series))
        context.insert(JournalEntry(title: "kept", body: ""))
        try context.save()

        var file = try SnappetBackup.snapshot(of: context)
        let without = try CloudBackupPayload.prepare(file, includeHeartRate: false)
        let stripped = try SnappetBackup.decode(without.plaintext)
        XCTAssertTrue(stripped.workoutSessions.allSatisfy(\.hrSeries.isEmpty))
        XCTAssertTrue(stripped.kilterSessions.allSatisfy(\.hrSeries.isEmpty))
        XCTAssertEqual(stripped.workoutSessions.first?.maxHR, 181, "session summaries stay")
        XCTAssertEqual(stripped.recordCount, file.recordCount, "no row is dropped, only the samples")
        XCTAssertFalse(without.includesHeartRate)
        XCTAssertEqual(without.sessionCount, 2)

        let with = try CloudBackupPayload.prepare(file, includeHeartRate: true)
        XCTAssertEqual(try SnappetBackup.decode(with.plaintext).workoutSessions.first?.hrSeries, series)
        XCTAssertNotEqual(with.contentHash, without.contentHash)

        // Same data exported a minute later hashes the same; a real change does not.
        file.exportedAt = file.exportedAt.addingTimeInterval(60)
        XCTAssertEqual(try CloudBackupPayload.prepare(file, includeHeartRate: false).contentHash, without.contentHash)
        context.insert(JournalEntry(title: "new", body: ""))
        try context.save()
        XCTAssertNotEqual(try CloudBackupPayload.prepare(SnappetBackup.snapshot(of: context),
                                                         includeHeartRate: false).contentHash, without.contentHash)
        XCTAssertEqual(file.userRecordCount, 3)
        withExtendedLifetime(container) {}
    }

    // MARK: - Wording

    func testStatusWording() {
        XCTAssertNil(CloudBackupStatusText.skipped(.unchanged))
        XCTAssertEqual(CloudBackupStatusText.skipped(.waitingForWiFi), "Waiting for Wi-Fi.")
        XCTAssertEqual(CloudBackupStatusText.skipped(.noAccount), "Sign in to iCloud in Settings to back up.")
        XCTAssertEqual(CloudBackupStatusText.contents(manifest("m")), "2 sessions · 3 clips · no heart-rate samples")
    }
}

/// The service against a local folder vault: the whole upload → list → trim → download → restore
/// loop, with no cloud account.
@MainActor
final class CloudBackupServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "CloudBackupServiceTests"
    private let key = SymmetricKey(size: .bits256)

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
        container = nil
    }

    private func service(network: CloudBackupNetwork = .wifi, key: SymmetricKey? = nil,
                         defaults other: UserDefaults? = nil) -> CloudBackupService {
        let folder = folder!
        return CloudBackupService(defaults: other ?? defaults, vaultFor: { _ in FolderVault(directory: folder) },
                                  keys: FixedBackupKeyStore(key: key ?? self.key),
                                  network: { network }, deviceName: "Test iPhone")
    }

    private func seed(_ title: String = "first") throws {
        container.mainContext.insert(JournalEntry(title: title, body: "private words"))
        container.mainContext.insert(WorkoutSession(routineName: "Bouldering", completedAt: .now,
                                                    hrSeries: [HRPoint(t: 0, bpm: 120)]))
        try container.mainContext.save()
    }

    private func vaultNames() throws -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Device finding (2026-11-20): the first backup to a brand-new iCloud container vanished from
    /// the cloud, and every later run said "unchanged" — so nothing was ever backed up again.
    func testABackupMissingFromTheCloudIsUploadedAgain() async throws {
        try seed()
        let backup = service()
        backup.update { $0.destination = .iCloud }
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
        XCTAssertEqual(try vaultNames().count, 2, "payload + manifest")

        for name in try vaultNames() { try FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        await backup.refreshRemote()
        XCTAssertTrue(backup.remote.isEmpty)
        XCTAssertNil(backup.remoteProblem, "an empty cloud folder is not an error")

        // Same data, not manual, minutes after the last run: still uploads, because the copy is gone.
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true)
        XCTAssertEqual(try vaultNames().count, 2, "the lost backup is replaced")
        XCTAssertEqual(backup.remote.count, 1)

        // And while it IS there, unchanged data is not uploaded twice.
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
        XCTAssertEqual(try vaultNames().count, 2)
    }

    /// Phone finding (2026-11-21, prompt 279): with a session on, the app got warm and was closed in
    /// the background. An automatic run during a session uploads nothing; "Back up now" still works.
    func testNothingIsBackedUpOnItsOwnWhileASessionIsRunning() async throws {
        try seed()
        let backup = service()
        backup.update { $0.destination = .iCloud }
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, sessionRunning: true)
        XCTAssertTrue(try vaultNames().isEmpty)
        XCTAssertEqual(backup.note, "Paused while a session is running.")

        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true, sessionRunning: true)
        XCTAssertEqual(try vaultNames().count, 2, "the person asked for this one")
    }

    func testWhatCanBeRuledOutBeforeTheStoreIsRead() {
        var on = CloudBackupSettings()
        on.destination = .iCloud
        func check(_ settings: CloudBackupSettings, healthy: Bool = true, session: Bool = false,
                   network: CloudBackupNetwork = .wifi, manual: Bool = false) -> CloudBackupPolicy.SkipReason? {
            CloudBackupPolicy.precheck(settings: settings, storeHealthy: healthy, sessionRunning: session,
                                       network: network, manual: manual)
        }
        XCTAssertEqual(check(CloudBackupSettings()), .off)
        XCTAssertEqual(check(on, healthy: false), .storeUnhealthy)
        XCTAssertEqual(check(on, session: true), .sessionRunning)
        XCTAssertNil(check(on, session: true, manual: true))
        XCTAssertEqual(check(on, network: .offline), .offline)
        XCTAssertEqual(check(on, network: .cellular), .waitingForWiFi)
        XCTAssertEqual(check(on, network: .cellular, manual: true), .waitingForWiFi, "Back up now still honors Wi-Fi only")
        XCTAssertNil(check(on))

        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(CloudBackupPolicy.isTooSoon(lastUploadAt: now.addingTimeInterval(-60), now: now, manual: false))
        XCTAssertFalse(CloudBackupPolicy.isTooSoon(lastUploadAt: now.addingTimeInterval(-60), now: now, manual: true))
        XCTAssertFalse(CloudBackupPolicy.isTooSoon(lastUploadAt: nil, now: now, manual: false), "a lost backup is replaced at once")
        XCTAssertFalse(CloudBackupPolicy.isTooSoon(lastUploadAt: now.addingTimeInterval(-CloudBackupPolicy.minimumInterval - 1),
                                                   now: now, manual: false))
    }

    func testASessionIsRunningWhileItsLiveActivityIsUpOrItStartedRecently() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(SessionQuietTime.isRunning(unfinishedStarts: [], liveActivityRunning: false, now: now))
        XCTAssertTrue(SessionQuietTime.isRunning(unfinishedStarts: [], liveActivityRunning: true, now: now))
        XCTAssertTrue(SessionQuietTime.isRunning(unfinishedStarts: [now.addingTimeInterval(-3600)], liveActivityRunning: false, now: now))
        XCTAssertFalse(SessionQuietTime.isRunning(unfinishedStarts: [now.addingTimeInterval(-3 * 86_400)],
                                                  liveActivityRunning: false, now: now),
                       "a session abandoned days ago does not hold backups off forever")
    }

    func testAFreshStartReturnsToAWorkoutLeftRecently() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SessionReturn.shouldReopen(runningStart: now.addingTimeInterval(-40 * 60), now: now, alreadyRouted: false))
        XCTAssertFalse(SessionReturn.shouldReopen(runningStart: nil, now: now, alreadyRouted: false))
        XCTAssertFalse(SessionReturn.shouldReopen(runningStart: now.addingTimeInterval(-40 * 60), now: now, alreadyRouted: true),
                       "a link that started the app decides where it goes")
        XCTAssertFalse(SessionReturn.shouldReopen(runningStart: now.addingTimeInterval(-6 * 3600), now: now, alreadyRouted: false),
                       "a workout forgotten for hours stays on Home's Resume card")
    }

    func testAFreshStartReturnsToTheSessionThePersonIsIn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func to(workout: TimeInterval?, kilter: TimeInterval?, routed: Bool = false) -> SessionReturn.Destination? {
            SessionReturn.destination(workoutStart: workout.map { now.addingTimeInterval(-$0) },
                                      kilterStart: kilter.map { now.addingTimeInterval(-$0) }, now: now, alreadyRouted: routed)
        }
        XCTAssertEqual(to(workout: 600, kilter: nil), .workout)
        XCTAssertEqual(to(workout: nil, kilter: 600), .kilter, "a board session is returned to as well (prompt 285)")
        XCTAssertEqual(to(workout: 3000, kilter: 600), .kilter, "the one started last")
        XCTAssertEqual(to(workout: 600, kilter: 3000), .workout)
        XCTAssertEqual(to(workout: 600, kilter: 6 * 3600), .workout, "a forgotten board session does not win")
        XCTAssertNil(to(workout: nil, kilter: 6 * 3600))
        XCTAssertNil(to(workout: nil, kilter: 600, routed: true), "a link that started the app decides")
        XCTAssertNil(to(workout: nil, kilter: nil))
    }

    func testAnUnreadableBackupIsNamedNotReportedAsNoBackups() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent(
            CloudBackupNaming.manifestName(forPayload: "snappet-20261120T000000Z-abcd1234.snpbak")))
        let backup = service()
        backup.update { $0.destination = .iCloud }
        await backup.refreshRemote()
        XCTAssertTrue(backup.remote.isEmpty)
        XCTAssertNotNil(backup.remoteProblem, "a backup that can't be read is a problem to show")
    }

    func testIsStoredNeedsBothThePayloadAndItsManifest() {
        let manifest = CloudBackupManifest(
            fileName: "a.snpbak", createdAt: .now, deviceID: "d", deviceName: "n", contentHash: "h",
            byteCount: 1, recordCount: 1, sessionCount: 0, clipCount: 0,
            backupFormatVersion: SnappetBackup.formatVersion, includesHeartRate: false)
        XCTAssertTrue(CloudBackupPolicy.isStored(manifest, in: ["a.snpbak", "a.snpbak.manifest.json"]))
        XCTAssertFalse(CloudBackupPolicy.isStored(manifest, in: ["a.snpbak"]))
        XCTAssertFalse(CloudBackupPolicy.isStored(manifest, in: ["a.snpbak.manifest.json"]))
        XCTAssertFalse(CloudBackupPolicy.isStored(manifest, in: []))
    }

    func testNothingIsWrittenWhileOff() async throws {
        try seed()
        let backup = service()
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
        XCTAssertTrue(try vaultNames().isEmpty, "off = nothing leaves the phone")
        XCTAssertNil(backup.lastManifest)
    }

    func testUploadIsSealedListedAndNotRepeatedForUnchangedData() async throws {
        try seed()
        let backup = service()
        backup.update { $0.destination = .iCloud }
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true)

        let manifest = try XCTUnwrap(backup.lastManifest)
        XCTAssertEqual(backup.phase, .idle)
        XCTAssertEqual(try vaultNames(), [manifest.fileName, manifest.fileName + ".manifest.json"])
        XCTAssertEqual(manifest.sessionCount, 1)
        XCTAssertFalse(manifest.includesHeartRate)
        let sealed = try Data(contentsOf: folder.appendingPathComponent(manifest.fileName))
        XCTAssertNil(sealed.range(of: Data("private words".utf8)), "the vault holds no plaintext")
        XCTAssertEqual(backup.remote, [manifest])

        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
        XCTAssertEqual(try vaultNames().count, 2, "unchanged data is not uploaded again")
    }

    func testWaitsForWiFiAndSaysSo() async throws {
        try seed()
        let backup = service(network: .cellular)
        backup.update { $0.destination = .iCloud }
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
        XCTAssertTrue(try vaultNames().isEmpty)
        XCTAssertEqual(backup.note, "Waiting for Wi-Fi.")
    }

    func testFallbackStoreIsNeverBackedUp() async throws {
        try seed()
        let backup = service()
        backup.update { $0.destination = .iCloud }
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: false, manual: true)
        XCTAssertTrue(try vaultNames().isEmpty)
    }

    func testOlderGenerationsAreTrimmedToThree() async throws {
        let backup = service()
        backup.update { $0.destination = .iCloud }
        for round in 0..<5 {
            try seed("entry \(round)")
            await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
            try await Task.sleep(for: .milliseconds(1100))   // names carry a 1-second stamp
        }
        XCTAssertEqual(backup.remote.count, 3)
        XCTAssertEqual(try vaultNames().count, 6, "three payloads + their manifests")
        XCTAssertEqual(backup.remote.first, backup.lastManifest)
    }

    func testRestoreOntoAFreshInstallBringsEveryRecordBackWithoutHeartRateSamples() async throws {
        try seed()
        let source = service()
        source.update { $0.destination = .iCloud }
        await source.runIfNeeded(context: container.mainContext, storeHealthy: true)
        let exported = try SnappetBackup.snapshot(of: container.mainContext)

        // A second install: same cloud folder, same key (iCloud Keychain), its own settings.
        let otherSuite = suite + ".other"
        UserDefaults().removePersistentDomain(forName: otherSuite)
        defer { UserDefaults().removePersistentDomain(forName: otherSuite) }
        let fresh = service(defaults: UserDefaults(suiteName: otherSuite))
        await fresh.checkRestoreOffer(localUserRecordCount: 0)
        let offer = try XCTUnwrap(fresh.restoreOffer, "an empty install is offered the backup")
        XCTAssertEqual(offer.deviceName, "Test iPhone")

        let file = try await fresh.download(offer)
        XCTAssertEqual(file.recordCount, exported.recordCount)
        XCTAssertEqual(file.journalEntries, exported.journalEntries)
        XCTAssertTrue(file.workoutSessions.allSatisfy(\.hrSeries.isEmpty), "samples were left out of the cloud file")

        fresh.declineOffer()
        XCTAssertNil(fresh.restoreOffer)
        await fresh.checkRestoreOffer(localUserRecordCount: 0)
        XCTAssertNil(fresh.restoreOffer, "a declined backup is not offered again")
    }

    func testIncludingHeartRateIsAChoiceThatChangesTheFile() async throws {
        try seed()
        let backup = service()
        backup.update { $0.destination = .iCloud; $0.includeHeartRate = true }
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true)
        let manifest = try XCTUnwrap(backup.lastManifest)
        XCTAssertTrue(manifest.includesHeartRate)
        let restored = try await backup.download(manifest)
        XCTAssertEqual(restored.workoutSessions.first?.hrSeries, [HRPoint(t: 0, bpm: 120)])
    }

    func testABackupCannotBeOpenedWithoutItsKeyAndIsNotOfferedThen() async throws {
        try seed()
        let source = service()
        source.update { $0.destination = .iCloud }
        await source.runIfNeeded(context: container.mainContext, storeHealthy: true)
        let manifest = try XCTUnwrap(source.lastManifest)

        let stranger = service(key: SymmetricKey(size: .bits256))
        do {
            _ = try await stranger.download(manifest)
            XCTFail("a different key must not open the backup")
        } catch {
            XCTAssertEqual(error as? CloudBackupCryptoError, .wrongKeyOrDamaged)
        }
    }

    func testSettingsAndLastBackupSurviveARelaunch() async throws {
        try seed()
        let first = service()
        first.update { $0.destination = .iCloud; $0.wifiOnly = false }
        await first.runIfNeeded(context: container.mainContext, storeHealthy: true)

        let relaunched = service()
        XCTAssertEqual(relaunched.settings, CloudBackupSettings(destination: .iCloud, includeHeartRate: false, wifiOnly: false))
        XCTAssertEqual(relaunched.lastManifest, first.lastManifest)
        XCTAssertEqual(relaunched.deviceID, first.deviceID)
    }
}

/// Prompt 267 added an iCloud container entitlement. With SwiftData's default configuration that
/// alone switches on CloudKit mirroring, which rejects this schema — the store would not open and
/// the app would start on the empty fallback. This runs inside the app (which has the entitlement).
final class StoreConfigurationTests: XCTestCase {
    func testTheRealStoreConfigurationOpensDespiteTheICloudEntitlement() throws {
        XCTAssertNoThrow(try ModelContainer(for: Schema(SnappetSchema.models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        // The on-disk configuration keeps SwiftData's default location and name.
        let configuration = SnappetSchema.onDiskConfiguration
        XCTAssertEqual(configuration.url.lastPathComponent, "default.store")
        XCTAssertFalse(configuration.isStoredInMemoryOnly)
    }
}
