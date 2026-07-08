import XCTest
@testable import Snappet

/// Pins the watch relay's two pure seams (bug-hunt Wave 2, #272): the start/stop gate that
/// absorbs a stop arriving inside `start()`'s async authorization window, and the running HR
/// average that must only fold when a builder batch actually carried a new HR statistic.
final class WatchWorkoutRelayStateTests: XCTestCase {

    // MARK: - WatchWorkoutStartGate

    func testNormalStartProceeds() {
        var gate = WatchWorkoutStartGate()
        XCTAssertTrue(gate.beginStart(isRunning: false))
        XCTAssertTrue(gate.isStarting)
        XCTAssertEqual(gate.completeStart(), .proceed)
        XCTAssertFalse(gate.isStarting)
    }

    func testStopDuringStartWindowAbandonsTheStart() {
        var gate = WatchWorkoutStartGate()
        XCTAssertTrue(gate.beginStart(isRunning: false))
        // The phone's queued start+stop land back-to-back: the stop arrives mid-auth,
        // before any session/builder exists.
        XCTAssertTrue(gate.absorbEndDuringStart())
        XCTAssertEqual(gate.completeStart(), .abandon)
        // Fully consumed either way: a later start is clean.
        XCTAssertFalse(gate.pendingEnd)
        XCTAssertTrue(gate.beginStart(isRunning: false))
        XCTAssertEqual(gate.completeStart(), .proceed)
    }

    func testStrayStopWithNoOpenWindowIsIgnored() {
        var gate = WatchWorkoutStartGate()
        XCTAssertFalse(gate.absorbEndDuringStart())
        XCTAssertFalse(gate.pendingEnd)
    }

    func testDuplicateStartInsideWindowIsDropped() {
        var gate = WatchWorkoutStartGate()
        XCTAssertTrue(gate.beginStart(isRunning: false))
        XCTAssertFalse(gate.beginStart(isRunning: false))   // mid-auth duplicate
        XCTAssertEqual(gate.completeStart(), .proceed)      // the duplicate didn't poison the window
    }

    func testStartWhileRunningIsDropped() {
        var gate = WatchWorkoutStartGate()
        XCTAssertFalse(gate.beginStart(isRunning: true))
        XCTAssertFalse(gate.isStarting)
    }

    func testResetClearsAnAbsorbedStop() {
        var gate = WatchWorkoutStartGate()
        _ = gate.beginStart(isRunning: false)
        gate.absorbEndDuringStart()
        gate.reset()
        XCTAssertFalse(gate.isStarting)
        XCTAssertFalse(gate.pendingEnd)
        XCTAssertTrue(gate.beginStart(isRunning: false))
    }

    // MARK: - WatchHRAverage

    func testAverageIsSampleWeighted() {
        var avg = WatchHRAverage()
        avg.fold(100)
        avg.fold(140)
        XCTAssertEqual(avg.count, 2)
        XCTAssertEqual(avg.average, 120, accuracy: 0.001)
    }

    func testNonPositiveReadingsDoNotCount() {
        var avg = WatchHRAverage()
        avg.fold(0)
        avg.fold(-5)
        XCTAssertEqual(avg.count, 0)
        XCTAssertEqual(avg.average, 0)   // "no data yet"
        avg.fold(120)
        XCTAssertEqual(avg.average, 120, accuracy: 0.001)
    }

    func testResetClears() {
        var avg = WatchHRAverage()
        avg.fold(150)
        avg.reset()
        XCTAssertEqual(avg.count, 0)
        XCTAssertEqual(avg.average, 0)
    }
}
