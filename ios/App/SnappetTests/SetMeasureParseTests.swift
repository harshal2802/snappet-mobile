import XCTest
@testable import Snappet

/// Unit tests for `SetMeasure.parseDuration` / `parseDistance` / `distanceFieldText` — the inverses
/// powering the all-axis set editor (workout-redesign follow-up). Pure, no device.
final class SetMeasureParseTests: XCTestCase {

    func testParseDuration() {
        XCTAssertEqual(SetMeasure.parseDuration("1:30"), 90)
        XCTAssertEqual(SetMeasure.parseDuration("0:45"), 45)
        XCTAssertEqual(SetMeasure.parseDuration("1:02:03"), 3723)   // H:MM:SS
        XCTAssertEqual(SetMeasure.parseDuration("90"), 90)          // plain seconds
        XCTAssertEqual(SetMeasure.parseDuration("45s"), 45)         // trailing-s form
        XCTAssertEqual(SetMeasure.parseDuration("  1:00  "), 60)    // trimmed
        XCTAssertNil(SetMeasure.parseDuration(""))
        XCTAssertNil(SetMeasure.parseDuration("abc"))
        XCTAssertNil(SetMeasure.parseDuration("1:2:3:4"))           // too many parts
        XCTAssertNil(SetMeasure.parseDuration("99:99:99:99"))
        XCTAssertNil(SetMeasure.parseDuration("100000"))            // ≥ a day → rejected
    }

    func testParseDistance() {
        XCTAssertEqual(SetMeasure.parseDistance("5.2", unit: .km)!, 5200, accuracy: 0.001)
        XCTAssertEqual(SetMeasure.parseDistance("5,2", unit: .km)!, 5200, accuracy: 0.001)  // decimal comma
        XCTAssertEqual(SetMeasure.parseDistance("1", unit: .mi)!, 1609.344, accuracy: 0.001)
        XCTAssertNil(SetMeasure.parseDistance("", unit: .km))
        XCTAssertNil(SetMeasure.parseDistance("0", unit: .km))      // must be > 0
        XCTAssertNil(SetMeasure.parseDistance("abc", unit: .km))
    }

    func testDistanceFieldTextRoundTrips() {
        XCTAssertEqual(SetMeasure.distanceFieldText(5200, unit: .km), "5.2")
        XCTAssertEqual(SetMeasure.distanceFieldText(1609.344, unit: .mi), "1")
        XCTAssertEqual(SetMeasure.distanceFieldText(0, unit: .km), "")
        // field → parse → field is stable
        let m = SetMeasure.parseDistance(SetMeasure.distanceFieldText(5200, unit: .km), unit: .km)!
        XCTAssertEqual(m, 5200, accuracy: 0.001)
    }
}
