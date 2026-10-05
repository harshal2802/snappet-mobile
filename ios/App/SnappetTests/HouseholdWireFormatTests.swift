import XCTest
@testable import Snappet

/// Household P1 (prompt 156): the op JSON is a cross-platform contract (P2 sync, P4's Kotlin port).
/// The golden strings below are the examples in `pdd/context/household-wire-format.md`, byte for byte;
/// if either drifts, this fails before two phones disagree.
final class HouseholdWireFormatTests: XCTestCase {
    static let golden: [String] = [
        #"{"at":"2026-10-04T08:00:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000001","kind":"add_member","member":"00000000-0000-0000-0000-0000000000a1","name":"Alex","seq":1,"v":1}"#,
        #"{"at":"2026-10-04T08:01:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d1","fields":{"assignment":{"mode":"up_for_grabs"},"effort":"l","emoji":"🧊","name":"Clean the fridge","repeats":{"every":14,"mode":"after_done"},"room":"Kitchen"},"id":"00000000-0000-0000-0000-000000000002","kind":"create_chore","seq":2,"v":1}"#,
        #"{"at":"2026-10-04T08:02:00.000Z","chore":"00000000-0000-0000-0000-0000000000c2","device":"00000000-0000-0000-0000-0000000000d1","fields":{"assignment":{"members":["00000000-0000-0000-0000-0000000000a1","00000000-0000-0000-0000-0000000000a2"],"mode":"rotate"},"effort":"s","emoji":"🍽️","name":"Dishes","repeats":{"days":[2,5],"mode":"weekdays"},"room":"Kitchen"},"id":"00000000-0000-0000-0000-000000000003","kind":"create_chore","seq":3,"v":1}"#,
        #"{"at":"2026-10-04T09:30:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","fields":{"effort":"m"},"id":"00000000-0000-0000-0000-000000000004","kind":"edit_chore","seq":1,"v":1}"#,
        #"{"at":"2026-10-04T18:30:00.250Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-000000000005","kind":"complete","member":"00000000-0000-0000-0000-0000000000a2","seq":2,"v":1}"#,
        #"{"at":"2026-10-04T18:31:00.000Z","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-000000000006","kind":"undo","op":"00000000-0000-0000-0000-000000000005","seq":3,"v":1}"#,
        #"{"at":"2026-10-04T19:00:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000007","kind":"claim","member":"00000000-0000-0000-0000-0000000000a1","seq":4,"v":1}"#,
        #"{"at":"2026-10-04T19:05:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000008","kind":"set_goal","reward":"Pizza night","seq":5,"target":40,"v":1,"week":"2026-09-28"}"#,
        #"{"at":"2026-10-04T19:10:00.000Z","chore":"00000000-0000-0000-0000-0000000000c2","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000009","kind":"archive_chore","seq":6,"v":1}"#,
    ]

    /// Prompts 157–158: the additive kinds and the `lean` field (also examples in the spec).
    static let goldenLater: [String] = [
        #"{"at":"2026-10-05T08:00:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-00000000000a","kind":"rename_household","name":"Flat 4B","seq":7,"v":1}"#,
        #"{"at":"2026-10-05T08:01:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d1","fields":{"lean":true},"id":"00000000-0000-0000-0000-00000000000b","kind":"edit_chore","seq":8,"v":1}"#,
        #"{"at":"2026-10-05T08:02:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-00000000000c","kind":"ask_help","member":"00000000-0000-0000-0000-0000000000a2","note":"Away till Tue","seq":4,"v":1}"#,
        #"{"at":"2026-10-05T08:03:00.000Z","by":"00000000-0000-0000-0000-0000000000a2","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-00000000000d","kind":"thank","member":"00000000-0000-0000-0000-0000000000a1","seq":5,"v":1}"#,
        #"{"at":"2026-10-05T08:04:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-00000000000e","kind":"pause_house","seq":9,"until":"2026-10-11","v":1}"#,
        #"{"at":"2026-10-05T08:05:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-00000000000f","kind":"resume_house","seq":10,"v":1}"#,
        #"{"at":"2026-10-05T08:06:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000010","kind":"name_pet","name":"Biscuit","seq":11,"v":1}"#,
    ]

    func testLaterKindsRoundTripAndDecode() throws {
        let ops = try Self.goldenLater.map { try ChoreOp.fromWire(Data($0.utf8)) }
        for (line, op) in zip(Self.goldenLater, ops) {
            XCTAssertEqual(String(decoding: try op.wireData(), as: UTF8.self), line)
        }
        let c1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
        let a1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let a2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
        XCTAssertEqual(ops[0].kind, .renameHousehold(name: "Flat 4B"))
        XCTAssertEqual(ops[1].kind, .editChore(chore: c1, fields: ChoreFields(lean: true)))
        XCTAssertEqual(ops[2].kind, .askHelp(chore: c1, member: a2, note: "Away till Tue"))
        XCTAssertEqual(ops[3].kind, .thank(member: a1, by: a2, chore: c1))
        XCTAssertEqual(ops[4].kind, .pauseHouse(until: "2026-10-11"))
        XCTAssertEqual(ops[5].kind, .resumeHouse)
        XCTAssertEqual(ops[6].kind, .namePet(name: "Biscuit"))
        let board = ChoreBoard.fold(try Self.golden.map { try ChoreOp.fromWire(Data($0.utf8)) } + ops)
        XCTAssertEqual(board.householdName, "Flat 4B")
        XCTAssertEqual(board.chores[c1]?.lean, true)
        XCTAssertEqual(board.helpRequests.count, 1)
        XCTAssertEqual(board.thanks.count, 1)
        XCTAssertEqual(board.pauses.count, 1)
        XCTAssertNotNil(board.pauses.first?.end, "resumed")
        XCTAssertEqual(board.petName, "Biscuit")
    }

    func testGoldenOpsRoundTripByteForByte() throws {
        for line in Self.golden {
            let op = try ChoreOp.fromWire(Data(line.utf8))
            XCTAssertEqual(String(decoding: try op.wireData(), as: UTF8.self), line)
            XCTAssertNotEqual(op.kind, .unknown(""), line)
        }
    }

    func testGoldenOpsDecodeToTheIntendedValues() throws {
        let ops = try Self.golden.map { try ChoreOp.fromWire(Data($0.utf8)) }
        let fridge = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
        let alex = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let sam = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
        XCTAssertEqual(ops[1].kind, .createChore(chore: fridge, fields: ChoreFields(
            name: "Clean the fridge", emoji: "🧊", room: "Kitchen", effort: .l,
            repeats: .afterDone(days: 14), assignment: .upForGrabs)))
        if case .createChore(_, let f) = ops[2].kind {
            XCTAssertEqual(f.repeats, .weekdays([2, 5]))
            XCTAssertEqual(f.assignment, .rotate([alex, sam]))
        } else { XCTFail("create") }
        XCTAssertEqual(ops[4].at.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.25, accuracy: 0.0001,
                       "milliseconds survive")

        let board = ChoreBoard.fold(ops)
        XCTAssertEqual(board.chores[fridge]?.effort, .m)
        XCTAssertTrue(board.completions.isEmpty, "the complete was undone")
        XCTAssertEqual(board.claims[fridge]?.member, alex)
        XCTAssertEqual(board.goals["2026-09-28"]?.reward, "Pizza night")
        XCTAssertEqual(board.activeChores.map(\.name), ["Clean the fridge"], "Dishes archived")
    }

    func testAnUnknownKindIsKeptVerbatimAndIgnoredByTheFold() throws {
        let line = #"{"at":"2026-10-04T08:00:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-0000000000ff","kind":"send_kudos","seq":9,"v":1}"#
        let op = try ChoreOp.fromWire(Data(line.utf8))
        XCTAssertEqual(op.kind, .unknown("send_kudos"))
        XCTAssertEqual(op.seq, 9, "still counted by version vectors, so it gets relayed")
        XCTAssertEqual(ChoreBoard.fold([op]), ChoreBoard())
    }

    func testUnknownFieldValuesDropOnlyThatField() throws {
        let line = #"{"at":"2026-10-04T08:00:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d1","fields":{"effort":"xl","name":"Gutters","repeats":{"mode":"fortnightly"}},"id":"00000000-0000-0000-0000-0000000000fe","kind":"create_chore","seq":1,"v":1}"#
        let op = try ChoreOp.fromWire(Data(line.utf8))
        XCTAssertEqual(op.kind, .createChore(chore: UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!,
                                             fields: ChoreFields(name: "Gutters")))
    }

    func testAnotherWireVersionIsRejected() {
        let line = #"{"at":"2026-10-04T08:00:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-0000000000fd","kind":"complete","seq":1,"v":2}"#
        XCTAssertThrowsError(try ChoreOp.fromWire(Data(line.utf8))) {
            XCTAssertEqual($0 as? ChoreOp.WireError, .unsupportedVersion(2))
        }
    }

    func testEveryKindRoundTrips() throws {
        let d = UUID(), c = UUID(), m = UUID()
        let kinds: [ChoreOp.Kind] = [
            .addMember(member: m, name: "Jo"),
            .createChore(chore: c, fields: ChoreFields(name: "A", emoji: "🧽", room: "", effort: .s, repeats: .daily,
                                                      assignment: .fixed(m))),
            .editChore(chore: c, fields: ChoreFields(repeats: .weekly)),
            .editChore(chore: c, fields: ChoreFields(repeats: .once)),
            .archiveChore(chore: c), .complete(chore: c, member: m), .undo(op: d), .claim(chore: c, member: m),
            .setGoal(week: "2026-10-05", target: 3, reward: ""),
            .renameHousehold(name: "Home"), .askHelp(chore: c, member: m, note: ""), .thank(member: m, by: d, chore: nil),
            .thank(member: m, by: d, chore: c), .pauseHouse(until: nil), .pauseHouse(until: "2026-10-11"), .resumeHouse,
            .namePet(name: "Mochi"), .editChore(chore: c, fields: ChoreFields(lean: false)),
        ]
        for (i, k) in kinds.enumerated() {
            let op = ChoreOp(id: UUID(), device: d, seq: i + 1, at: Date(timeIntervalSince1970: 1_791_190_800.123), kind: k)
            let back = try ChoreOp.fromWire(try op.wireData())
            XCTAssertEqual(back.kind, op.kind)
            XCTAssertEqual(back.at.timeIntervalSince1970, op.at.timeIntervalSince1970, accuracy: 0.001)
        }
    }
}
