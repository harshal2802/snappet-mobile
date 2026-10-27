import XCTest
@testable import Snappet

/// Prompt 207: don't hog a shared board. Pure rules + the per-board setting's storage; the BLE let-go /
/// reconnect-to-light legs are device-only (real board).
@MainActor
final class KilterBoardSharingTests: XCTestCase {
    private func board(letGo: Bool? = nil, idle: Int? = nil) -> RememberedBoard {
        var b = RememberedBoard(layoutId: 1, productSizeId: 10, angleHistory: [], label: "Gym · left", serial: "4821",
                                coarsePlace: nil, lastSeen: .now)
        b.letGoWhenIdle = letGo
        b.idleSeconds = idle
        return b
    }

    func testDefaultsAreOnAndTenSeconds() {
        XCTAssertEqual(KilterBoardSharing.setting(for: nil), .init(letGoWhenIdle: true, idleSeconds: 10))
        XCTAssertEqual(KilterBoardSharing.setting(for: board()), .init(letGoWhenIdle: true, idleSeconds: 10),
                       "a board remembered before sharing existed shares by default")
        XCTAssertEqual(KilterBoardSharing.idleOptions.first, 10)
    }

    func testPerBoardSettingAndUnknownTimesSnapToDefault() {
        XCTAssertEqual(KilterBoardSharing.setting(for: board(letGo: false, idle: 60)).letGoWhenIdle, false)
        XCTAssertEqual(KilterBoardSharing.setting(for: board(idle: 120)).idleSeconds, 120)
        XCTAssertEqual(KilterBoardSharing.setting(for: board(idle: 7)).idleSeconds, 10, "not an offered option")
    }

    func testLetGoTimeFollowsTheLastLight() {
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(KilterBoardSharing.letGoAt(lastLight: t, setting: .default), t.addingTimeInterval(10))
        XCTAssertNil(KilterBoardSharing.letGoAt(lastLight: t, setting: .init(letGoWhenIdle: false, idleSeconds: 10)),
                     "sharing off: hold the board (a home board)")
    }

    func testLabelsAndBusyMessage() {
        XCTAssertEqual(KilterBoardSharing.idleOptions.map(KilterBoardSharing.label(seconds:)),
                       ["10 s", "30 s", "1 min", "2 min", "5 min"])
        XCTAssertTrue(KilterBoardSharing.busyMessage(board: "Gym · left").contains("Someone else is on Gym · left"))
        XCTAssertTrue(KilterBoardSharing.busyMessage(board: nil).contains("the board"))
        XCTAssertLessThanOrEqual(KilterBoardSharing.relightTimeout, .seconds(5))
    }

    func testSettingIsStoredPerBoardAndOldBoardsStillDecode() throws {
        let suite = "kilter.sharing.test.\(UUID())"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let memory = KilterBoardMemory(defaults: d)
        let gym = UUID(), home = UUID()
        memory.remember(identifier: gym, layoutId: 1, productSizeId: 10)
        memory.remember(identifier: home, layoutId: 1, productSizeId: 11)
        memory.setSharing(identifier: home, letGoWhenIdle: false, idleSeconds: 10)
        memory.setSharing(identifier: gym, letGoWhenIdle: true, idleSeconds: 60)
        let reread = KilterBoardMemory(defaults: d)
        XCTAssertEqual(KilterBoardSharing.setting(for: reread.recall(identifier: home)).letGoWhenIdle, false)
        XCTAssertEqual(KilterBoardSharing.setting(for: reread.recall(identifier: gym)).idleSeconds, 60)
        memory.setSharing(identifier: UUID(), letGoWhenIdle: false, idleSeconds: 30)   // unknown: no-op
        XCTAssertEqual(reread.boards.count, 2)

        // A board saved by an older build has no sharing keys and must still decode (on by default).
        let legacy = #"{"layoutId":1,"productSizeId":10,"angleHistory":[],"label":"Old","lastSeen":0}"#
        let decoded = try JSONDecoder().decode(RememberedBoard.self, from: Data(legacy.utf8))
        XCTAssertEqual(KilterBoardSharing.setting(for: decoded), .default)
    }
}
