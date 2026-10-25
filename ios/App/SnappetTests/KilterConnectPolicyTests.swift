import XCTest
@testable import Snappet

/// Unit tests for the **pure** Kilter connect policy (prompt 204): which board wins, when an attempt is
/// retried, and what a failure says. The CoreBluetooth side is device-only.
final class KilterConnectPolicyTests: XCTestCase {

    private func c(_ rssi: Int, known: Bool = false, id: UUID = UUID()) -> KilterConnectPolicy.Candidate {
        .init(id: id, rssi: rssi, isKnown: known)
    }

    func testKnownBoardBeatsAStrongerStranger() {
        let mine = c(-80, known: true)
        XCTAssertEqual(KilterConnectPolicy.pick([c(-40), mine, c(-55)])?.id, mine.id)
    }

    func testStrongestWinsAmongStrangers() {
        let near = c(-50)
        XCTAssertEqual(KilterConnectPolicy.pick([c(-85), near, c(-70)])?.id, near.id)
    }

    func testFarBoardsOnlyWhenNothingNearer() {
        let near = c(-88)
        XCTAssertEqual(KilterConnectPolicy.pick([c(-97), near])?.id, near.id)
        let far = c(-97)
        XCTAssertEqual(KilterConnectPolicy.pick([far])?.id, far.id, "a far board is still better than none")
        XCTAssertNil(KilterConnectPolicy.pick([]))
    }

    func testUnavailableRSSISortsLastButIsUsable() {
        let real = c(-75)
        XCTAssertEqual(KilterConnectPolicy.pick([c(127), real])?.id, real.id)
        let only = c(127)
        XCTAssertEqual(KilterConnectPolicy.pick([only])?.id, only.id)
    }

    func testKnownBoardsConnectImmediately() {
        XCTAssertTrue(KilterConnectPolicy.connectsImmediately(c(-90, known: true)))
        XCTAssertFalse(KilterConnectPolicy.connectsImmediately(c(-40)))
    }

    func testRetryOnceForLinkFailuresNeverForAnEmptyScan() {
        XCTAssertTrue(KilterConnectPolicy.shouldRetry(after: .connect, attempt: 1))
        XCTAssertTrue(KilterConnectPolicy.shouldRetry(after: .discovery, attempt: 1))
        XCTAssertFalse(KilterConnectPolicy.shouldRetry(after: .connect, attempt: 2))
        XCTAssertFalse(KilterConnectPolicy.shouldRetry(after: .scan, attempt: 1))
    }

    func testFailureMessagesSayWhatToDo() {
        XCTAssertTrue(KilterConnectPolicy.failureMessage(.scan).contains("one connection at a time"))
        XCTAssertTrue(KilterConnectPolicy.failureMessage(.connect).contains("Move closer"))
        XCTAssertTrue(KilterConnectPolicy.failureMessage(.discovery).contains("off and on"))
    }

    func testTimingsAreSane() {
        XCTAssertLessThan(KilterConnectPolicy.selectionWindow, KilterConnectPolicy.rememberedGrace)
        XCTAssertLessThan(KilterConnectPolicy.rememberedGrace, KilterConnectPolicy.scanTimeout)
        // A dropped board is released within a minute, so a shared board isn't held after you leave.
        XCTAssertLessThanOrEqual(KilterConnectPolicy.reconnectWindow, .seconds(60))
        XCTAssertTrue(KilterConnectPolicy.gaveUpReconnectMessage.contains("Tap Connect"))
    }
}
