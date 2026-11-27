import XCTest
@testable import Snappet

/// The real wiring of a test launch (prompt 320), not only the read-out: the account, the backup and the clip
/// copies are built the way the app builds them for test-launch arguments, and must be inert stand-ins that cannot
/// reach the person's Google account, Drive or settings. Photos changes are limited to what the test made.
@MainActor
final class TestLaunchWiringTests: XCTestCase {
    private let testLaunch = ["Snappet", "-uiTestSeedStudioHRTiming"]

    func testATestLaunchsGoogleAccountIsNeverThePersons() async {
        let google = GoogleAccount.make(arguments: testLaunch)
        XCTAssertTrue(google.isTestStandIn, "tokens in memory only, no network")
        XCTAssertFalse(google.isSignedIn)
        XCTAssertTrue(GoogleAccount.isOffline(testLaunch))
        do {
            _ = try await google.accessToken(forceRefresh: true)
            XCTFail("a test launch has no token")
        } catch {}
        // Every test-launch argument, and the two stand-ins on their own.
        for arg in UITestStore.testLaunchArguments + ["-uiTestGoogleSignedIn", "-uiTestNoGoogle"] {
            XCTAssertTrue(GoogleAccount.make(arguments: [arg]).isTestStandIn, arg)
        }
        XCTAssertFalse(GoogleAccount.make(arguments: ["Snappet"]).isTestStandIn, "a normal launch uses the Keychain")
    }

    func testTheSignedInStandInCannotReachTheNetwork() async {
        let google = GoogleAccount.make(arguments: ["-uiTestFreshStore", "-uiTestGoogleSignedIn"])
        XCTAssertTrue(google.isSignedIn)
        let http = GoogleAuthorizedHTTP(accessToken: { _ in "test" }, http: OfflineGoogleHTTP())
        do {
            _ = try await http.send(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!))
            XCTFail("offline")
        } catch {}
    }

    func testATestLaunchsBackupReachesNoCloud() {
        let backup = AppModel.makeCloudBackup(arguments: testLaunch)
        for destination in CloudBackupDestination.allCases {
            XCTAssertFalse(backup.hasVault(for: destination), destination.rawValue)
        }
        let vaulted = AppModel.makeCloudBackup(arguments: testLaunch + ["-uiTestCloudVault"])
        XCTAssertTrue(vaulted.hasVault(for: .googleDrive), "only the local test folder")
    }

    /// The clip copies never read the person's copies index or settings, and their destructive actions do nothing.
    func testATestLaunchsClipCopiesAreInert() async throws {
        let key = "mediaVault.settings"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        var real = MediaVaultSettings()
        real.keepCopies = true
        real.started = true
        UserDefaults.standard.set(try JSONEncoder().encode(real), forKey: key)

        let google = GoogleAccount.make(arguments: testLaunch)
        let vault = AppModel.makeMediaVault(arguments: testLaunch, google: google)
        XCTAssertFalse(vault.settings.keepCopies, "the person's settings are not read")
        XCTAssertFalse(vault.settings.started)
        await vault.removeAllCopies()
        let after = try XCTUnwrap(UserDefaults.standard.data(forKey: key))
        XCTAssertEqual(try JSONDecoder().decode(MediaVaultSettings.self, from: after), real, "the person's untouched")
    }

    // MARK: - Photos

    func testATestLaunchChangesOnlyPhotosItMade() {
        XCTAssertTrue(TestLaunchAssets.mayChange(["A"], isTestLaunch: false, owned: []))
        XCTAssertFalse(TestLaunchAssets.mayChange(["A"], isTestLaunch: true, owned: []), "nothing owned: refuse")
        XCTAssertTrue(TestLaunchAssets.mayChange(["A"], isTestLaunch: true, owned: ["A", "B"]))
        XCTAssertFalse(TestLaunchAssets.mayChange(["A", "C"], isTestLaunch: true, owned: ["A"]), "one not owned: refuse all")
        XCTAssertTrue(TestLaunchAssets.mayChange([], isTestLaunch: true, owned: []))
    }

    func testATestLaunchDiscoversOnlyPhotosItMade() {
        XCTAssertEqual(TestLaunchAssets.discoverable(["A", "B"], isTestLaunch: false, owned: []), ["A", "B"])
        XCTAssertEqual(TestLaunchAssets.discoverable(["A", "B"], isTestLaunch: true, owned: ["B"]), ["B"])
        XCTAssertEqual(TestLaunchAssets.discoverable(["A"], isTestLaunch: true, owned: []), [])
    }

    func testANormalLaunchOwnsNothingAndIsNotLimited() throws {
        TestLaunchAssets.noteCreated("X")   // the unit-test host is a normal launch
        XCTAssertFalse(TestLaunchAssets.owned.contains("X"))
        XCTAssertTrue(TestLaunchAssets.mayChange(["anything"]))
        try TestLaunchAssets.requireMayChange(["anything"])
    }
}
