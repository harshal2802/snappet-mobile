import XCTest
@testable import Snappet

/// The person's settings survive a UI-test launch on their phone (prompt 320): the first test launch saves them,
/// later test launches keep that copy, the end-of-run launch puts them back exactly, and a normal launch restores
/// only when it is certainly safe. Runs on two scratch suites, a temp folder and a fixed clock; no device.
final class TestLaunchPrefsTests: XCTestCase {
    private var appName = ""
    private var groupName = ""
    private var app: UserDefaults!
    private var group: UserDefaults!
    private var folder: URL!
    private var file: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        appName = "snappet.tests.prefs.app.\(id)"
        groupName = "snappet.tests.prefs.group.\(id)"
        app = UserDefaults(suiteName: appName)
        group = UserDefaults(suiteName: groupName)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(id)", isDirectory: true)
        file = folder.appendingPathComponent("settings-snapshot.plist")
    }

    override func tearDown() {
        app.removePersistentDomain(forName: appName)
        group.removePersistentDomain(forName: groupName)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var domains: [TestLaunchPrefs.Domain] {
        [.defaults(app, name: appName), .defaults(group, name: groupName)]
    }

    @discardableResult
    private func launch(test: Bool, at minutes: Double = 0, restoreOnly: Bool = false,
                        settingsModifiedAt: Date? = nil, fileManager: FileManager = .default) -> TestLaunchPrefs.Outcome {
        TestLaunchPrefs.run(isTestLaunch: test || restoreOnly, restoreOnly: restoreOnly, domains: domains, file: file,
                            now: t0.addingTimeInterval(minutes * 60), settingsModifiedAt: { settingsModifiedAt },
                            fileManager: fileManager)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

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

    private func assertTestSettingsLeft(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 3, file: file, line: line)
        XCTAssertEqual(group.string(forKey: "accent"), "orange", file: file, line: line)
    }

    // MARK: - The decisions

    func testStepTable() {
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: true, snapshotExists: false), .snapshot)
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: true, snapshotExists: true), .keepSnapshot)
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: false, snapshotExists: true), .restore)
        XCTAssertEqual(TestLaunchPrefs.step(isTestLaunch: false, snapshotExists: false), .none)
    }

    func testFallbackTable() {
        let last = t0
        func at(_ hours: Double) -> Date { last.addingTimeInterval(hours * 3600) }
        XCTAssertEqual(TestLaunchPrefs.fallback(now: at(1), lastTestLaunchAt: last, settingsModifiedAt: nil), .restore)
        XCTAssertEqual(TestLaunchPrefs.fallback(now: at(1), lastTestLaunchAt: last, settingsModifiedAt: at(0.25)), .restore,
                       "the last test still runs after its launch")
        XCTAssertEqual(TestLaunchPrefs.fallback(now: at(5.9), lastTestLaunchAt: last, settingsModifiedAt: at(0.5)), .restore)
        XCTAssertEqual(TestLaunchPrefs.fallback(now: at(6.1), lastTestLaunchAt: last, settingsModifiedAt: nil), .tooOld)
        XCTAssertEqual(TestLaunchPrefs.fallback(now: at(24 * 30), lastTestLaunchAt: last, settingsModifiedAt: nil), .tooOld)
        XCTAssertEqual(TestLaunchPrefs.fallback(now: at(2), lastTestLaunchAt: last, settingsModifiedAt: at(1)), .changedSince,
                       "another launch (an older build) wrote settings after the run")
    }

    func testOnlyASafelySavedTestLaunchMayTouchSettings() {
        for outcome in [TestLaunchPrefs.Outcome.saved, .kept, .offOnSimulator] {
            XCTAssertTrue(TestLaunchPrefs.mayTouchSettings(isTestLaunch: true, outcome: outcome), outcome.rawValue)
        }
        for outcome in [TestLaunchPrefs.Outcome.failed, .notNeeded, .restored, .setAside, .restoredNotDeleted] {
            XCTAssertFalse(TestLaunchPrefs.mayTouchSettings(isTestLaunch: true, outcome: outcome), outcome.rawValue)
        }
        XCTAssertTrue(TestLaunchPrefs.mayTouchSettings(isTestLaunch: false, outcome: .failed))
    }

    // MARK: - Save, then the end-of-run restore

    func testATestRunThenTheRestoreLaunchPutsEverySettingBack() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        XCTAssertTrue(exists(file))
        actLikeATest()
        XCTAssertEqual(launch(test: false, at: 10, restoreOnly: true), .restored)
        assertRealSettingsBack()
        XCTAssertFalse(exists(file), "the snapshot is used once")
        XCTAssertFalse(exists(TestLaunchPrefs.claimedURL(for: file)))
        XCTAssertEqual(launch(test: false, at: 11), .notNeeded)
    }

    /// A run cut short leaves a snapshot; days of another build follow. The end-of-run launch of a LATER run must
    /// not roll those days back.
    func testTheRestoreLaunchSetsAStaleSnapshotAside() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false, at: 60 * 24 * 3, restoreOnly: true), .setAside)
        assertTestSettingsLeft()
        XCTAssertFalse(exists(file))
    }

    func testTheRestoreLaunchSetsASnapshotAsideWhenAnotherLaunchChangedSettings() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        app.set(5, forKey: "clips.grid.columns")   // an older build, after the run
        XCTAssertEqual(launch(test: false, at: 120, restoreOnly: true,
                              settingsModifiedAt: t0.addingTimeInterval(90 * 60)), .setAside)
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 5)
    }

    /// The reviewer's scenario: run 1 is cut short (snapshot S1 of the settings then), the person uses another
    /// build for days and changes settings, then run 2 starts. Run 2 must save the CURRENT settings, not keep S1.
    func testANewRunAfterAStaleSnapshotSavesTheCurrentSettings() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)                       // S1
        actLikeATest()
        // Days later, in another build, the person's settings are now these.
        app.set(6, forKey: "clips.grid.columns")
        app.set("activities", forKey: "clips.level")
        let days = 60.0 * 24 * 4
        XCTAssertEqual(launch(test: true, at: days, settingsModifiedAt: t0.addingTimeInterval(days * 60 - 3600)), .saved,
                       "S1 is not this run's: a fresh snapshot")
        XCTAssertTrue(exists(TestLaunchPrefs.setAsideURL(for: file, now: t0.addingTimeInterval(days * 60))), "S1 kept aside")
        app.set(2, forKey: "clips.grid.columns")                          // run 2's tests
        app.removeObject(forKey: "clips.level")
        XCTAssertEqual(launch(test: false, at: days + 10, restoreOnly: true), .restored)
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 6, "the settings from before run 2")
        XCTAssertEqual(app.string(forKey: "clips.level"), "activities")
    }

    func testATestLaunchSoonAfterTheLastKeepsTheSnapshot() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: true, at: 4, settingsModifiedAt: t0.addingTimeInterval(3 * 60)), .kept)
        XCTAssertEqual(launch(test: false, at: 9, restoreOnly: true, settingsModifiedAt: t0.addingTimeInterval(8 * 60)),
                       .restored)
        assertRealSettingsBack()
    }

    func testTheRestoreLaunchWithNoSnapshotDoesNothing() {
        seedRealSettings()
        XCTAssertEqual(launch(test: false, restoreOnly: true), .notNeeded)
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4)
    }

    func testSeveralTestLaunchesKeepTheFirstSnapshotAndStampTheLatest() throws {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: true, at: 5), .kept, "the second test launch must not save the test's settings")
        app.set(9, forKey: "clips.grid.columns")
        XCTAssertEqual(launch(test: true, at: 50), .kept)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
                                  as? [String: Any])
        XCTAssertEqual(plist["savedAt"] as? Date, t0)
        XCTAssertEqual(plist["lastTestLaunchAt"] as? Date, t0.addingTimeInterval(50 * 60))
        XCTAssertEqual(launch(test: false, at: 60, restoreOnly: true), .restored)
        assertRealSettingsBack()
    }

    func testEmptySettingsComeBackEmpty() {
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false, restoreOnly: true), .restored)
        XCTAssertNil(app.object(forKey: "clips.grid.columns"))
        XCTAssertNil(app.object(forKey: "festival.tourSeen"))
        XCTAssertNil(group.object(forKey: "accent"))
    }

    func testADomainTheSnapshotDoesNotNameIsLeftAlone() {
        seedRealSettings()
        XCTAssertEqual(TestLaunchPrefs.run(isTestLaunch: true, domains: [.defaults(app, name: appName)], file: file,
                                           now: t0), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false, restoreOnly: true), .restored)
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4)
        XCTAssertEqual(group.string(forKey: "accent"), "orange", "not in the snapshot: not overwritten")
    }

    // MARK: - A failed snapshot

    func testASnapshotThatCannotBeWrittenFailsTheLaunch() throws {
        // The snapshot's folder is a plain file, so nothing can be written under it.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        file = blocker.appendingPathComponent("settings-snapshot.plist")
        seedRealSettings()
        let outcome = launch(test: true)
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(TestLaunchPrefs.mayTouchSettings(isTestLaunch: true, outcome: outcome))
        XCTAssertTrue(TestLaunchIsolation.readOut(arguments: ["-uiTestFreshStore"], prefs: outcome).hasSuffix("prefs failed"))
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4, "nothing touched")
    }

    // MARK: - The next normal launch, a fallback

    func testANormalLaunchSoonAfterTheRunRestores() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false, at: 40, settingsModifiedAt: t0.addingTimeInterval(10 * 60)), .restored)
        assertRealSettingsBack()
    }

    func testANormalLaunchHoursLaterSetsTheSnapshotAside() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        let now = t0.addingTimeInterval(7 * 3600)
        XCTAssertEqual(launch(test: false, at: 7 * 60), .setAside)
        assertTestSettingsLeft()
        XCTAssertFalse(exists(file))
        XCTAssertTrue(exists(TestLaunchPrefs.setAsideURL(for: file, now: now)), "kept, not deleted")
        XCTAssertEqual(launch(test: false, at: 7 * 60 + 1), .notNeeded, "never tried again")
    }

    func testSettingsChangedByAnotherLaunchAreNeverRolledBack() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        // An older build ran after the run (it knows nothing of snapshots) and the person changed a setting.
        app.set(5, forKey: "clips.grid.columns")
        XCTAssertEqual(launch(test: false, at: 120, settingsModifiedAt: t0.addingTimeInterval(90 * 60)), .setAside)
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 5)
    }

    func testAnUnreadableSnapshotIsSetAsideAndSettingsAreLeftAlone() throws {
        seedRealSettings()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: file)
        XCTAssertEqual(launch(test: false), .setAside)
        XCTAssertFalse(exists(file))
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 4)
        XCTAssertEqual(launch(test: false, at: 1), .notNeeded, "never retried")
    }

    /// A delete that fails after a restore is reported; the snapshot was renamed first, so it never restores again.
    func testAFailedDeleteIsReportedAndNeverRestoresAgain() {
        seedRealSettings()
        XCTAssertEqual(launch(test: true), .saved)
        actLikeATest()
        XCTAssertEqual(launch(test: false, at: 5, restoreOnly: true, fileManager: NoDeleteFileManager()),
                       .restoredNotDeleted)
        assertRealSettingsBack()
        app.set(7, forKey: "clips.grid.columns")   // the person changes a setting afterwards
        XCTAssertEqual(launch(test: false, at: 6), .notNeeded)
        XCTAssertEqual(launch(test: false, at: 7, restoreOnly: true), .notNeeded)
        XCTAssertEqual(app.integer(forKey: "clips.grid.columns"), 7)
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

/// A file manager whose deletes always fail (moves still work).
private final class NoDeleteFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
