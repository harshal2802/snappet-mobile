import XCTest
@testable import Snappet

/// The accent reaches the widget extension through the App Group (prompt 243).
final class SnappetAccentPublishTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "snappet.tests.accent-publish"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNothingPublishedReadsTheDefault() {
        XCTAssertEqual(SnappetAccent.stored(in: defaults), .periwinkle)
        XCTAssertEqual(SnappetAccent.stored(in: nil), .periwinkle, "no App Group container → the default")
    }

    func testPublishRoundTripsAndReportsOnlyRealChanges() {
        XCTAssertTrue(SnappetAccent.publish(.teal, to: defaults), "first write is a change")
        XCTAssertEqual(SnappetAccent.stored(in: defaults), .teal)
        XCTAssertFalse(SnappetAccent.publish(.teal, to: defaults), "same accent → no widget reload")
        XCTAssertTrue(SnappetAccent.publish(.coral, to: defaults))
        XCTAssertEqual(SnappetAccent.stored(in: defaults), .coral)
    }

    func testUnknownStoredValueFallsBackToTheDefault() {
        defaults.set("magenta", forKey: SnappetAccent.appGroupKey)
        XCTAssertEqual(SnappetAccent.stored(in: defaults), .periwinkle)
    }

    func testPublishWithoutAContainerIsANoOp() {
        XCTAssertFalse(SnappetAccent.publish(.glacier, to: nil))
    }
}
