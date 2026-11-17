import XCTest

/// The test-store guard itself (prompt 266): it confirms the `uiTest.freshStore` marker on a test-store launch,
/// and it refuses — terminating the app before any tap — when the marker is missing.
@MainActor
final class TestStoreGuardUITests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testTheTestStoreShowsTheMarkerAndPasses() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        XCTAssertNil(app.launchCheckingTestStore(), "a -uiTestFreshStore launch is on the test store")
        XCTAssertEqual(app.state, .runningForeground)
        let marker = app.descendants(matching: .any).matching(identifier: TestStoreGuard.markerIdentifier).firstMatch
        XCTAssertTrue(marker.exists)
        // Invisible and out of the way: at most 1pt.
        XCTAssertLessThanOrEqual(marker.frame.width, 1.5)
        XCTAssertLessThanOrEqual(marker.frame.height, 1.5)
        app.terminate()
    }

    /// A launch with no test-store argument, check forced: no marker, so the guard terminates the app and reports.
    /// Simulator only — on a real device this would open the user's real store (it never taps, but stay out).
    func testALaunchWithoutTheTestStoreIsRefusedAndTerminated() throws {
        try XCTSkipIf(TestStoreGuard.isRealDevice, "launches without a test store; simulator only")
        let app = XCUIApplication()
        XCTAssertFalse(app.argumentsImplyTestStore)
        let refusal = app.launchCheckingTestStore(require: true, timeout: 5)
        XCTAssertEqual(refusal, TestStoreGuard.refusal)
        XCTAssertEqual(app.state, .notRunning, "the guard terminates the app before any tap")
    }

    func testOnTheSimulatorTheCheckSkipsALaunchWithoutTheTestStore() throws {
        try XCTSkipIf(TestStoreGuard.isRealDevice, "simulator behaviour")
        let app = XCUIApplication()
        XCTAssertNil(app.launchCheckingTestStore(), "the check doesn't apply on the simulator without a store arg")
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()
    }
}
