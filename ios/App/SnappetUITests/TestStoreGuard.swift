import XCTest

/// The test-store guard (prompt 266). UI tests sometimes run on a real iPhone, where on 2026-11-16 the first
/// launch after a fresh install attached to an app process iOS had started WITHOUT the test arguments, and the
/// test tapped Quick Start in the user's real data. Every UI-test launch goes through `launchOnTestStore()`,
/// which confirms the app's invisible `uiTest.freshStore` marker BEFORE any tap; if it is missing the app is
/// terminated first and the test fails, so no later tap can land in real data.
enum TestStoreGuard {
    /// Mirrors `UITestStore.freshStoreArguments` in `Snappet/Core/UITestStore.swift` — the test target can't
    /// import the app, so keep the two lists in step.
    static let freshStoreArguments: Set<String> = [
        "-uiTestFreshStore",
        "-uiTestSeedStudioDemo",
        "-uiTestSeedRecapClip",
        "-uiTestSeedRoutineHistory",
        "-uiTestSeedActivityClips",
        "-uiTestSeedRacketHR",
        "-uiTestSeedRacketVideos",
        "-uiTestSeedFestivalLineup",
        "-uiTestSeedFestivalNight",
        "-uiTestSeedFestivalPlan",
        "-uiTestSeedRunningWorkout",
        "-uiTestSeedRunningWorkoutOld",
        "-uiTestSeedStudioHRTiming",
    ]
    /// `UITestStore.corruptStoreArgument`: the fallback-banner test's in-memory store, which carries the marker too.
    static let corruptStoreArgument = "-uiTestCorruptStore"
    /// `UITestStore.markerIdentifier`.
    static let markerIdentifier = "uiTest.freshStore"
    static let refusal = "Snappet is not on the test store; refusing to touch real data"
    static let markerTimeout: TimeInterval = 15

    /// The marker's value is the app's `TestLaunchIsolation.readOut` (prompt 320), e.g.
    /// "cloud backup off; restore offer off; copies off; network watch off; prefs saved". On a real device the
    /// launch is refused unless the person's cloud, clip copies and settings are all kept out of the test.
    /// Returns `nil` when the read-out is safe.
    static func isolationRefusal(readOut: String?) -> String? {
        guard let readOut else { return "Snappet did not say what this test launch is kept away from" }
        let parts = Set(readOut.components(separatedBy: "; "))
        let backupSafe = parts.contains("cloud backup off") || parts.contains("cloud backup test vault")
        let offerSafe = parts.contains("restore offer off") || parts.contains("restore offer test vault")
        let prefsSafe = parts.contains("prefs saved") || parts.contains("prefs kept")
        guard backupSafe, offerSafe, parts.contains("copies off"), parts.contains("network watch off"), prefsSafe else {
            return "This test launch is not isolated from real data (\(readOut)); refusing to touch it"
        }
        return nil
    }

    static var isRealDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// Links opened through `XCUIDevice.shared.system.open` reach whatever Snappet is installed, so link tests
    /// never run on a real device.
    static func skipLinkTestsOnDevice() throws {
        if isRealDevice { throw XCTSkip("link tests are simulator-only") }
    }
}

extension XCUIApplication {
    /// Whether these launch arguments ask the app for the in-memory test store.
    var argumentsImplyTestStore: Bool {
        launchArguments.contains {
            TestStoreGuard.freshStoreArguments.contains($0) || $0 == TestStoreGuard.corruptStoreArgument
        }
    }

    /// Launches, then — always on a real device, and on the simulator when the arguments ask for the test store
    /// (or `require` forces it) — waits for the test-store marker. Returns `nil` when the app is confirmed (or the
    /// check doesn't apply); otherwise terminates the app and returns the refusal. No tap happens in here.
    @discardableResult
    func launchCheckingTestStore(require: Bool? = nil,
                                 timeout: TimeInterval = TestStoreGuard.markerTimeout) -> String? {
        launch()
        let applies = require ?? (TestStoreGuard.isRealDevice || argumentsImplyTestStore)
        guard applies else { return nil }
        let marker = descendants(matching: .any).matching(identifier: TestStoreGuard.markerIdentifier).firstMatch
        guard marker.waitForExistence(timeout: timeout) else {
            terminate()
            return TestStoreGuard.refusal
        }
        // On a phone, also confirm the cloud, clip copies and settings are kept out of this launch (prompt 320).
        if TestStoreGuard.isRealDevice, let refusal = TestStoreGuard.isolationRefusal(readOut: marker.value as? String) {
            terminate()
            return refusal
        }
        return nil
    }

    /// Every UI test's launch. Fails the test (after terminating the app) when Snappet isn't on the test store.
    func launchOnTestStore(file: StaticString = #filePath, line: UInt = #line) {
        if let refusal = launchCheckingTestStore() {
            XCTFail(refusal, file: file, line: line)
        }
    }
}
