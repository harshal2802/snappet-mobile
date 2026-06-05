import XCTest
@testable import Snappet

/// Unit tests for the `KilterLogEntry` model fields the session Climb panel edits — no SwiftData
/// container, no device: the `@Model` is constructed directly and its stored properties are checked.
/// Covers the additive `note` field (defaults to `nil`, survives assignment) the panel writes to.
final class KilterLogEntryTests: XCTestCase {

    private func entry(note: String? = nil) -> KilterLogEntry {
        KilterLogEntry(climbUUID: "abc", climbName: "Crimpy Road", angle: 40, difficulty: 18,
                       gradeLabel: "6c/V5", status: .sent, note: note)
    }

    func testNoteDefaultsToNil() {
        XCTAssertNil(entry().note)
    }

    func testNoteRoundTripsThroughInit() {
        XCTAssertEqual(entry(note: "felt solid on the crux").note, "felt solid on the crux")
    }

    func testNoteIsMutable() {
        let e = entry()
        e.note = "second go, sticky conditions"
        XCTAssertEqual(e.note, "second go, sticky conditions")
        e.note = nil                                   // the panel clears the note on empty text
        XCTAssertNil(e.note)
    }
}
