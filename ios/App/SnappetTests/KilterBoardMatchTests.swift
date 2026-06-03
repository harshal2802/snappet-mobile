import XCTest
import CoreBluetooth
@testable import Snappet

/// Unit tests for the **pure** board-discovery predicate `KilterBoardController.isLikelyBoard`.
/// This is the off-device-testable half of the BLE connect fix: Aurora-family boards advertise by
/// local name (not by service UUID), so scanning filtered by the service UUID never discovered them
/// — the cause of the "stuck connecting" bug. The live radio path stays device-pending.
final class KilterBoardMatchTests: XCTestCase {
    private let service = CBUUID(string: "4488B571-7806-4DF6-BCFF-A2897E4953FF")

    func testMatchesByAdvertisedLocalName() {
        XCTAssertTrue(KilterBoardController.isLikelyBoard(name: "Kilter Board A1B2", advertisedServiceUUIDs: []))
        XCTAssertTrue(KilterBoardController.isLikelyBoard(name: "kilterboard", advertisedServiceUUIDs: []))
    }

    func testMatchesOtherAuroraFamilyBoards() {
        for name in ["Aurora 1234", "Tension Board", "Grasshopper", "Decoy", "SoIll"] {
            XCTAssertTrue(KilterBoardController.isLikelyBoard(name: name, advertisedServiceUUIDs: []),
                          "expected \(name) to match")
        }
    }

    func testMatchesByAdvertisedServiceEvenWithUnknownName() {
        XCTAssertTrue(KilterBoardController.isLikelyBoard(name: "Unnamed", advertisedServiceUUIDs: [service]))
        XCTAssertTrue(KilterBoardController.isLikelyBoard(name: nil, advertisedServiceUUIDs: [service]))
    }

    func testRejectsUnrelatedPeripherals() {
        XCTAssertFalse(KilterBoardController.isLikelyBoard(name: "AirPods Pro", advertisedServiceUUIDs: []))
        XCTAssertFalse(KilterBoardController.isLikelyBoard(name: "Polar H10", advertisedServiceUUIDs: []))
        XCTAssertFalse(KilterBoardController.isLikelyBoard(name: nil, advertisedServiceUUIDs: []))
        XCTAssertFalse(KilterBoardController.isLikelyBoard(
            name: "Some Speaker",
            advertisedServiceUUIDs: [CBUUID(string: "180D")]))   // HR service, not the board
    }
}
