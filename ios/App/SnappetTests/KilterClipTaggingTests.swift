import XCTest
@testable import Snappet

/// Prompt 214: which clips the Tag clips sheet shows, and what "Done" changes.
final class KilterClipTaggingTests: XCTestCase {
    private struct Clip { let id = UUID(); let climb: String? }

    func testFiltersSplitUntaggedThisClimbAndAll() {
        let clips = [Clip(climb: nil), Clip(climb: "A"), Clip(climb: "B"), Clip(climb: nil)]
        func n(_ f: KilterClipTagging.Filter) -> Int {
            KilterClipTagging.visible(clips, f, climbUUID: "A") { $0.climb }.count
        }
        XCTAssertEqual(n(.untagged), 2)
        XCTAssertEqual(n(.thisClimb), 1)
        XCTAssertEqual(n(.all), 4)
    }

    func testDoneTagsSelectedMovesFromAnotherClimbAndUntagsDeselected() {
        let untagged = UUID(), onOther = UUID(), onHere = UUID(), keptHere = UUID(), leftAlone = UUID()
        let current: [UUID: String?] = [untagged: nil, onOther: "B", onHere: "A", keptHere: "A", leftAlone: "B"]
        let changes = KilterClipTagging.changes(current: current, selected: [untagged, onOther, keptHere], climbUUID: "A")
        XCTAssertEqual(changes[untagged], .some("A"))
        XCTAssertEqual(changes[onOther], .some("A"), "a clip on another climb moves here")
        XCTAssertEqual(changes[onHere], .some(nil), "deselected → untagged")
        XCTAssertNil(changes[keptHere], "already here and still selected → no change")
        XCTAssertNil(changes[leftAlone], "not touched")
    }

    func testNoSelectionChangesNothingElsewhere() {
        let a = UUID()
        XCTAssertTrue(KilterClipTagging.changes(current: [a: "B"], selected: [], climbUUID: "A").isEmpty)
    }
}
