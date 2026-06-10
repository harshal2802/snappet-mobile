import XCTest
@testable import Snappet
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Unit tests for `PomodoroActivityAttributes.ContentState` — the producer / renderer contract.
/// No device, no ActivityKit runtime needed: the `ContentState` is a plain `Codable` struct that
/// the app pushes and the widget decodes, so correctness is verifiable here.
final class PomodoroLiveActivityTests: XCTestCase {

    #if canImport(ActivityKit)

    func testContentStateCarriesFieldsThrough() {
        let end = Date(timeIntervalSince1970: 50_000)
        let state = PomodoroActivityAttributes.ContentState(endDate: end, phase: "Focus", paused: false)
        XCTAssertEqual(state.endDate, end)
        XCTAssertEqual(state.phase, "Focus")
        XCTAssertFalse(state.paused)
    }

    func testPausedDefaultIsFalse() {
        let state = PomodoroActivityAttributes.ContentState(
            endDate: Date(timeIntervalSince1970: 1_000), phase: "Break")
        XCTAssertFalse(state.paused)
    }

    func testContentStateCodableRoundTrips() throws {
        let end = Date(timeIntervalSince1970: 99_999)
        let state = PomodoroActivityAttributes.ContentState(endDate: end, phase: "Focus", paused: true)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PomodoroActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.paused)
        XCTAssertEqual(decoded.phase, "Focus")
    }

    func testBreakPhaseRoundTrips() throws {
        let state = PomodoroActivityAttributes.ContentState(
            endDate: Date(timeIntervalSince1970: 200), phase: "Break", paused: false)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PomodoroActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded.phase, "Break")
        XCTAssertFalse(decoded.paused)
    }

    #endif
}
