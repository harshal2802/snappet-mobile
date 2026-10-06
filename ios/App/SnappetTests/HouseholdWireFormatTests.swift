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
        ]
        for (i, k) in kinds.enumerated() {
            let op = ChoreOp(id: UUID(), device: d, seq: i + 1, at: Date(timeIntervalSince1970: 1_791_190_800.123), kind: k)
            let back = try ChoreOp.fromWire(try op.wireData())
            XCTAssertEqual(back.kind, op.kind)
            XCTAssertEqual(back.at.timeIntervalSince1970, op.at.timeIntervalSince1970, accuracy: 0.001)
        }
    }
}
