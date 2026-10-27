import XCTest
@testable import Snappet

/// Prompt 205 (multi-board): the pure halves — the climber's own board list, the default name, the
/// "which board?" chooser rules and the arrival card's several-boards-here list. BLE / UI are device-only.
final class KilterMultiBoardTests: XCTestCase {

    // MARK: - KilterMyBoards

    private func mine(_ name: String, linked: UUID? = nil) -> KilterMyBoard {
        KilterMyBoard(name: name, layoutId: 1, productSizeId: 10, linkedBoardID: linked)
    }

    func testLinkPointsOneEntryAtTheBoardAndUnlinksAnyOther() {
        let board = UUID()
        let gym = mine("Gym"), home = mine("Home", linked: board)
        let linked = KilterMyBoards.link(gym.id, to: board, in: [gym, home])
        XCTAssertEqual(linked[0].linkedBoardID, board)
        XCTAssertNil(linked[1].linkedBoardID, "one physical board is one of your boards, never two")
    }

    func testUnlinkedAreTheFirstConnectAnswers() {
        let gym = mine("Gym"), home = mine("Home", linked: UUID())
        XCTAssertEqual(KilterMyBoards.unlinked([gym, home]).map(\.name), ["Gym"])
    }

    func testSuggestedNameNumbersDuplicates() {
        XCTAssertEqual(KilterMyBoards.suggestedName(sizeName: "12 x 12", existing: []), "12 x 12")
        XCTAssertEqual(KilterMyBoards.suggestedName(sizeName: "12 x 12", existing: [mine("12 x 12")]), "12 x 12 2")
        XCTAssertEqual(KilterMyBoards.suggestedName(sizeName: "12 x 12",
                                                    existing: [mine("12 x 12"), mine("12 x 12 2")]), "12 x 12 3")
    }

    func testDecodeRoundTripsAndToleratesJunk() throws {
        let list = [mine("Gym"), mine("Home", linked: UUID())]
        XCTAssertEqual(KilterMyBoards.decode(try JSONEncoder().encode(list)), list)
        XCTAssertEqual(KilterMyBoards.decode(nil), [])
        XCTAssertEqual(KilterMyBoards.decode(Data("nope".utf8)), [])
    }

    func testSaveLoadUsesTheGivenDefaults() {
        let suite = "KilterMultiBoardTests.\(UUID())"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        KilterMyBoards.save([mine("Gym")], d)
        XCTAssertEqual(KilterMyBoards.load(d).map(\.name), ["Gym"])
    }

    // MARK: - default name (Q1)

    func testDefaultLabelIsSizePlusSerial() {
        XCTAssertEqual(KilterBoardMemory.defaultLabel(sizeName: "12 x 12", serial: "4821"), "12 x 12 (#4821)")
        XCTAssertEqual(KilterBoardMemory.defaultLabel(sizeName: "12 x 12", serial: nil), "12 x 12")
        XCTAssertEqual(KilterBoardMemory.defaultLabel(sizeName: nil, serial: "4821"), "Kilter board (#4821)")
        XCTAssertEqual(KilterBoardMemory.defaultLabel(sizeName: " ", serial: ""), "Kilter board")
    }

    // MARK: - chooser (Q2)

    private func c(_ rssi: Int, known: Bool = false) -> KilterConnectPolicy.Candidate {
        .init(id: UUID(), rssi: rssi, isKnown: known)
    }

    func testChooserOnlyWithTwoOrMoreNearBoards() {
        XCTAssertFalse(KilterConnectPolicy.showsChooser([c(-60)]))
        XCTAssertTrue(KilterConnectPolicy.showsChooser([c(-60), c(-75, known: true)]),
                      "even a known board asks when another is in range")
        XCTAssertFalse(KilterConnectPolicy.showsChooser([c(-60), c(-97)]), "the far side of the gym doesn't count")
    }

    func testNearbyIsStrongestFirstAndKeepsFarOnlyWhenAlone() {
        let a = c(-80), b = c(-55), u = c(127)
        XCTAssertEqual(KilterConnectPolicy.nearby([a, u, b]).map(\.id), [b.id, a.id, u.id])
        let far1 = c(-95), far2 = c(-99)
        XCTAssertEqual(KilterConnectPolicy.nearby([far2, far1]).map(\.id), [far1.id, far2.id])
    }

    func testSignalBars() {
        XCTAssertEqual(KilterConnectPolicy.bars(rssi: -50), 4)
        XCTAssertEqual(KilterConnectPolicy.bars(rssi: -65), 3)
        XCTAssertEqual(KilterConnectPolicy.bars(rssi: -78), 2)
        XCTAssertEqual(KilterConnectPolicy.bars(rssi: -90), 1)
        XCTAssertEqual(KilterConnectPolicy.bars(rssi: 127), 1)
    }

    func testFlashIsShort() {
        XCTAssertEqual(KilterConnectPolicy.flashDuration, .seconds(5))
    }

    // MARK: - arrival card: several boards here

    private func remembered(_ label: String, at place: CoarsePlace?, seen: Date) -> RememberedBoard {
        RememberedBoard(layoutId: 1, productSizeId: 10, angleHistory: [], label: label, serial: nil,
                        coarsePlace: place, lastSeen: seen)
    }

    func testSuggestionsListsEveryBoardHereNewestFirst() {
        let gym = CoarsePlace(latitude: 51.5001, longitude: -0.1201)
        let home = CoarsePlace(latitude: 51.6, longitude: -0.2)
        let now = Date()
        let boards: [(id: UUID, board: RememberedBoard)] = [
            (UUID(), remembered("Gym left", at: gym, seen: now.addingTimeInterval(-3600))),
            (UUID(), remembered("Home", at: home, seen: now)),
            (UUID(), remembered("Gym right", at: gym, seen: now.addingTimeInterval(-60))),
            (UUID(), remembered("Nowhere", at: nil, seen: now)),
        ]
        XCTAssertEqual(KilterPlaceMatcher.suggestions(for: gym, in: boards).map(\.board.label), ["Gym right", "Gym left"])
        XCTAssertEqual(KilterPlaceMatcher.suggestion(for: gym, in: boards)?.board.label, "Gym right")
        XCTAssertTrue(KilterPlaceMatcher.suggestions(for: CoarsePlace(latitude: 0, longitude: 0), in: boards).isEmpty)
    }
}
