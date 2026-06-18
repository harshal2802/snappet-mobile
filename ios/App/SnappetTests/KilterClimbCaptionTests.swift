import XCTest
@testable import Snappet

/// Unit tests for the **pure** climb-name overlay caption builder: name on the first line, then
/// `grade · angle°`, with the setter folded in only when enabled and present.
final class KilterClimbCaptionTests: XCTestCase {

    func testNameGradeAngleWithoutSetter() {
        let c = KilterClimbCaption.caption(name: "Blue Crux", gradeLabel: "6c/V5", angle: 40,
                                           setter: "jdoe", includeSetter: false)
        XCTAssertEqual(c, "Blue Crux\n6c/V5 · 40°")
    }

    func testIncludesSetterWhenEnabled() {
        let c = KilterClimbCaption.caption(name: "Blue Crux", gradeLabel: "6c/V5", angle: 40,
                                           setter: "jdoe", includeSetter: true)
        XCTAssertEqual(c, "Blue Crux\n6c/V5 · 40° · by jdoe")
    }

    func testSetterEnabledButMissingIsOmitted() {
        let c = KilterClimbCaption.caption(name: "Blue Crux", gradeLabel: "6c/V5", angle: 40,
                                           setter: nil, includeSetter: true)
        XCTAssertEqual(c, "Blue Crux\n6c/V5 · 40°")
        let blank = KilterClimbCaption.caption(name: "Blue Crux", gradeLabel: "6c/V5", angle: 40,
                                               setter: "   ", includeSetter: true)
        XCTAssertEqual(blank, "Blue Crux\n6c/V5 · 40°")
    }

    func testZeroAngleAndEmptyGradeAreDropped() {
        XCTAssertEqual(KilterClimbCaption.caption(name: "Slab", gradeLabel: "", angle: 0,
                                                  setter: nil, includeSetter: false), "Slab")
        XCTAssertEqual(KilterClimbCaption.caption(name: "Slab", gradeLabel: "7a", angle: 0,
                                                  setter: nil, includeSetter: false), "Slab\n7a")
    }

    func testEmptyNameReturnsDetailOnly() {
        XCTAssertEqual(KilterClimbCaption.caption(name: "  ", gradeLabel: "7a", angle: 25,
                                                  setter: nil, includeSetter: false), "7a · 25°")
    }

    // MARK: - climbTagContent (prompt 10 — the toggleable "Attempt N" line on the climb-name tag)

    func testClimbTagAppendsAttemptLineWhenOn() {
        // The base caption (which may itself be two lines) gets "Attempt N" on its own trailing line.
        XCTAssertEqual(
            KilterClimbCaption.climbTagContent(caption: "Cave Roof · V5", attempt: 3, showAttempt: true),
            "Cave Roof · V5\nAttempt 3")
        XCTAssertEqual(
            KilterClimbCaption.climbTagContent(caption: "Blue Crux\n6c/V5 · 40°", attempt: 2, showAttempt: true),
            "Blue Crux\n6c/V5 · 40°\nAttempt 2")
    }

    func testClimbTagOffReturnsBaseUnchanged() {
        XCTAssertEqual(
            KilterClimbCaption.climbTagContent(caption: "Cave Roof · V5", attempt: 3, showAttempt: false),
            "Cave Roof · V5")
    }

    func testClimbTagNilOrNonPositiveAttemptIsNoOp() {
        XCTAssertEqual(
            KilterClimbCaption.climbTagContent(caption: "Cave Roof", attempt: nil, showAttempt: true),
            "Cave Roof")
        XCTAssertEqual(
            KilterClimbCaption.climbTagContent(caption: "Cave Roof", attempt: 0, showAttempt: true),
            "Cave Roof")
    }

    func testClimbTagEmptyCaptionWithAttemptIsAttemptOnly() {
        XCTAssertEqual(
            KilterClimbCaption.climbTagContent(caption: "", attempt: 1, showAttempt: true),
            "Attempt 1")
    }
}
