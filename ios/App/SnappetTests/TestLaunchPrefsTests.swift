import XCTest
@testable import Snappet

/// The person's settings survive a UI-test launch on their phone (prompt 320): the first test launch saves them, a
/// later test launch keeps that first copy, and the next normal launch puts them back exactly. Runs on two scratch
/// suites and a temp file, no device.
final class TestLaunchPrefsTests: XCTestCase {
    private var appName = ""
    private var groupName = ""
    private var app: UserDefaults!
    private var group: UserDefaults!
    private var file: URL!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        appName = "snappet.tests.prefs.app.\(id)"
        groupName = "snappet.tests.prefs.group.\(id)"
        app = UserDefaults(suiteName: appName)
        group = UserDefaults(suiteName: groupName)
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefs-\(id)", isDirectory: true)
            .appendingPathComponent("settings-snapshot.plist")
    }

    override func tearDown() {
        app.removePersistentDomain(forName: appName)
        group.removePersistentDomain(forName: groupName)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        super.tearDown()
    }

    private var domains: [TestLaunchPrefs.Domain] {
        [.defaults(app, name: appName), .defaults(group, name: groupName)]
    }

    @discardableResult
    private func launch(test: Bool, now: Date = .now) -> TestLaunchPrefs.Outcome {
        TestLaunchPrefs.run(isTestLaunch: test, domains: domains, file: file, now: now)
    }

    /// The person's own settings, the ones lost on 2026-11-26.
    private func seedRealSettings() {
        app.set(4, forKey: "clips.grid.columns")
        app.set("sessions", forKey: "clips.level")
        app.set(["V5", "V6"], forKey: "freeform.recentGrades.vScale")
        app.set(["The Climbing Hangar"], forKey: "freeform.recentGyms")
        group.set("periwinkle", forKey: "accent")
    }

    /// What `SnappetApp.init` and the tests do to settings on a test launch.
    private func actLikeATest() {
        for key in ["clips.grid.columns", "clips.level", "freeform.recentGrades.vScale", "freeform.recentGyms"] {
            app.removeObject(forKey: key)
        }
        app.set(true, forKey: "festival.tourSeen")
        app.set(3, forKey: "clips.grid.columns")
        group.set("orange", forKey: "accent")
        group.set(Data([1, 2, 3]), forKey: "today-widget-outbox")
    }

    private func assertRealSettingsBack(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4, file: file, line: line)
        XCTAssertEqual(app.string(forKey: "clips.level"), "sessions", file: file, line: line)
        XCTAssertEqual(app.stringArray(forKey: "freeform.recentGrades.vScale"), ["V5", "V6"], file: file, line: line)
        XCTAssertEqual(app.stringArray(forKey: "freeform.recentGyms"), ["The Climbing Hangar"], file: file, line: line)
        XCTAssertNil(app.object(forKey: "festival.tourSeen"), "a key the test added is gone", file: file, line: line)
        XCTAssertEqual(group.string(forKey: "accent"), "periwinkle", file: file, line: line)
        XCTAssertNil(group.object(forKey: "today-widget-outbox"), file: file, line: line)
    }

    // MARK: - The decision

    func testStepTable() {
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: true, snapshotExists: false), .snapshot)
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: true, snapshotExists: true), .keepSnapshot)
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: false, snapshotExists: true), .restore)
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: false, snapshotExists: false), .none)
    }

    // MARK: - Save and restore

    func testATestLaunchThenANormalLaunchPutsEverySettingBack() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        actLikeATest()
        XCTAssertEqual(launch(test: false), .restored)
        assertRealSettingsBack()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the snapshot is used once")
    }

    func testSeveralTestLaunchesKeepTheFirstSnapshot() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: true), .kept, "the second test launch must not save the test's settings")
        app.set(9, forKey: "clips.grid.columns")
        XCTAssertEqual(launch(test: true), .kept)
        XCTAssertEqual(launch(test: false), .restored)
        assertRealSettingsBack()
    }

    func testAnOldSnapshotStillRestores() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true, now: Date(timeIntervalSinceNow: -60 * 86_400)), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false), .restored)
        assertRealSettingsBack()
    }

    func testEmptySettingsComeBackEmpty() {
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false), .restored)
        XCTAssertNil(app.object(forKey: "clips.grid.columns"))
        XCTAssertNil(app.object(forKey: "festival.tourSeen"))
        XCTAssertNil(group.object(forKey: "accent"))
    }

    func testANormalLaunchWithNoSnapshotTouchesNothing() {
        seedRealSettings()
        XCTAssertEqual(launch(test: false), .notNeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4)
        XCTAssertEqual(launch(test: false), .notNeeded)
    }

    func testAnUnreadableSnapshotIsDroppedAndSettingsAreLeftAlone() throws {
        seedRealSettings()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: file)
        XCTAssertEqual(launch(test: false), .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4)
        XCTAssertEqual(launch(test: false), .notNeeded, "never retried")
    }

    func testADomainTheSnapshotDoesNotNameIsLeftAlone() {
        seedRealSettings()
        XCTAssertEqual(TestLaunchPrefs.run(isTestLaunch: true, domains: [.defaults(app, name: appName)], file: file),
                       .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false), .restored)
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4)
        XCTAssertEqual(group.string(forKey: "accent"), "orange", "not in the snapshot: not overwritten")
    }

    // MARK: - The read-out a device test checks

    func testTheReadOutOfATestLaunch() {
        XCTAssertEqual(TestLaunchIsolation.readOut(arguments: ["-uiTestSeedStudioHRTiming"], prefs: .saved),
                       "cloud backup off; restore offer off; copies off; network watch off; prefs saved")
        XCTAssertEqual(TestLaunchIsolation.readOut(arguments: ["-uiTestFreshStore"], prefs: .offOnSimulator),
                       "cloud backup off; restore offer off; copies off; network watch off; prefs off (simulator)")
        XCTAssertEqual(TestLaunchIsolation.readOut(arguments: ["-uiTestSeedFestivalNight", "-uiTestCloudVault"],
                                                   prefs: .kept),
                       "cloud backup test vault; restore offer test vault; copies off; network watch off; prefs kept")
    }

    func testCloudWorkRunsOnlyOnANormalLaunchOrToTheTestVault() {
        for arg in UITestStore.testLaunchArguments {
            XCTAssertFalse(TestLaunchIsolation.cloudBackupRuns([arg]), arg)
            XCTAssertFalse(TestLaunchIsolation.cloudCopiesRun([arg]), arg)
            XCTAssertTrue(TestLaunchIsolation.cloudBackupRuns([arg, "-uiTestCloudVault"]), arg)
            XCTAssertFalse(TestLaunchIsolation.cloudCopiesRun([arg, "-uiTestCloudVault"]), arg)
        }
        XCTAssertTrue(TestLaunchIsolation.cloudBackupRuns([]))
        XCTAssertTrue(TestLaunchIsolation.cloudCopiesRun([]))
        // A device test that runs on the real store on purpose (`-vaultHoldCopies`) is not a test launch.
        XCTAssertTrue(TestLaunchIsolation.cloudCopiesRun(["-vaultHoldCopies", "YES"]))
    }
}
