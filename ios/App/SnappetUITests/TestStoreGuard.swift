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
    /// `UITestStore.markerIdentifier`.
    static let markerIdentifier = "uiTest.freshStore"
    static let refusal = "Snappet is not on the test store; refusing to touch real data"
    static let markerTimeout: TimeInterval = 15

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
        launchArguments.contains { TestStoreGuard.freshStoreArguments.contains($0) }
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
        if marker.waitForExistence(timeout: timeout) { return nil }
        terminate()
        return TestStoreGuard.refusal
    }

    /// Every UI test's launch. Fails the test (after terminating the app) when Snappet isn't on the test store.
    func launchOnTestStore(file: StaticString = #filePath, line: UInt = #line) {
        if let refusal = launchCheckingTestStore() {
            XCTFail(refusal, file: file, line: line)
        }
    }
}
