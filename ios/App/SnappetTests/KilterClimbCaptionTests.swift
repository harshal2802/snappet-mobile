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

    // MARK: - composeClimbTag (prompt 12 — the per-clip tag's rendered string = base + setter + attempt)

    func testComposeBaseOnlyWhenAllFlagsOff() {
        // No setter, no attempt → the base caption is returned verbatim (user text is never altered).
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "Blue Crux\n6c · 40°", setter: "jdoe",
                                               showSetter: false, attempt: 2, showAttempt: false),
            "Blue Crux\n6c · 40°")
    }

    func testComposeSetterRidesTheDetailLineNotBelowAttempt() {
        // " · by {setter}" is appended to the LAST line of the base (the detail line), and "Attempt N"
        // goes on its own trailing line — so the two system lines never collide.
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "Blue Crux\n6c · 40°", setter: "jdoe",
                                               showSetter: true, attempt: 2, showAttempt: true),
            "Blue Crux\n6c · 40° · by jdoe\nAttempt 2")
    }

    func testComposeSetterOnSingleLineBase() {
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "Cave Roof · V5", setter: "amaya",
                                               showSetter: true, attempt: nil, showAttempt: false),
            "Cave Roof · V5 · by amaya")
    }

    func testComposeSetterOnIgnoredWhenSetterMissingOrBlank() {
        // showSetter ON but no/blank setter → no suffix (a freeform tag never sprouts a stray " · by ").
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "Cave Roof", setter: nil,
                                               showSetter: true, attempt: nil, showAttempt: false),
            "Cave Roof")
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "Cave Roof", setter: "   ",
                                               showSetter: true, attempt: nil, showAttempt: false),
            "Cave Roof")
    }

    func testComposeAttemptOnlyLeavesUserTypedAttemptTextIntact() {
        // The user typed "Attempt 1" themselves; toggling the SYSTEM attempt off must not strip it — the
        // base is composed verbatim (no regex over user content). This is the prompt-12 corruption fix.
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "My line\nAttempt 1", setter: nil,
                                               showSetter: false, attempt: 4, showAttempt: false),
            "My line\nAttempt 1")
        // With the system attempt ON, the system line is ADDED below the user's text (both survive).
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "My line\nAttempt 1", setter: nil,
                                               showSetter: false, attempt: 4, showAttempt: true),
            "My line\nAttempt 1\nAttempt 4")
    }

    func testComposeEmptyBaseWithSetterAndAttempt() {
        XCTAssertEqual(
            KilterClimbCaption.composeClimbTag(base: "", setter: "jdoe",
                                               showSetter: true, attempt: 3, showAttempt: true),
            "by jdoe\nAttempt 3")
    }
}
