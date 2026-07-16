import XCTest
@testable import Snappet

/// Accept/reject table for `FestivalPackValidator` (festival prompt 01) — the Kilter-posture install
/// gate: a valid pack yields the browse-row counts; each structural defect yields the exact typed
/// error the install UI (prompt 02) shows verbatim.
final class FestivalPackValidatorTests: XCTestCase {

    private func expectFailure(_ pack: FestivalPack, _ expected: FestivalPackValidator.Failure,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try FestivalPackValidator.validate(pack), file: file, line: line) {
            XCTAssertEqual($0 as? FestivalPackValidator.Failure, expected, file: file, line: line)
        }
    }

    // MARK: - Accept

    func testFixturePackValidatesWithTheBrowseRowCounts() throws {
        let v = try FestivalPackValidator.validate(FestivalFixtures.glastonbury())
        XCTAssertEqual(v, .init(dayCount: 2, stageCount: 6, setCount: 8))
    }

    func testOverlapAcrossDifferentStagesIsAllowed() throws {
        // Eric Prydz (Arcadia) overlaps Fred again.. AND Overmono on other stages — that's a festival,
        // not a defect; the matcher scores it. The fixture validating at all proves this, but be explicit:
        let pack = FestivalFixtures.glastonbury()
        let prydz = FestivalFixtures.set(named: "Eric Prydz", in: pack)
        let overmono = FestivalFixtures.set(named: "Overmono", in: pack)
        XCTAssertTrue(prydz.window.intersects(overmono.window))
        XCTAssertNoThrow(try FestivalPackValidator.validate(pack))
    }

    func testMidnightCrossingSetIsInsideItsPosterDay() {
        // Jayda G 01:00–02:30 sits past midnight but inside SAT's rollover window — accepted above.
        // Listing her under SUN instead must be rejected (the explicit day-boundary rule).
        var pack = FestivalFixtures.glastonbury()
        let jayda = pack.days[0].stages[1].sets.removeLast()
        pack.days[1].stages[1].sets.append(jayda)
        expectFailure(pack, .setOutsideDay(day: "2026-06-28", artist: "Jayda G"))
    }

    // MARK: - Reject

    func testRejectsUnsupportedVersion() {
        var pack = FestivalFixtures.glastonbury()
        pack.formatVersion = 99
        expectFailure(pack, .unsupportedVersion(99))
    }

    func testRejectsEmptyName() {
        var pack = FestivalFixtures.glastonbury()
        pack.name = "   "
        expectFailure(pack, .emptyName)
    }

    func testRejectsUnrealUTCOffset() {
        var pack = FestivalFixtures.glastonbury()
        pack.utcOffsetSeconds = 15 * 3600
        expectFailure(pack, .badUTCOffset(15 * 3600))
    }

    func testRejectsNoDays() {
        var pack = FestivalFixtures.glastonbury()
        pack.days = []
        expectFailure(pack, .noDays)
    }

    func testRejectsBadDayDate() {
        var pack = FestivalFixtures.glastonbury()
        pack.days[0].date = "June 27th"
        expectFailure(pack, .badDayDate("June 27th"))
    }

    func testRejectsDuplicateDay() {
        var pack = FestivalFixtures.glastonbury()
        pack.days[1].date = pack.days[0].date
        // Duplicate SAT: its SUN-timed sets now also sit outside SAT's window, but the duplicate is
        // what we must report… day order: date check runs on the second day before its sets.
        expectFailure(pack, .duplicateDay("2026-06-27"))
    }

    func testRejectsDayOutsideFestivalWindow() {
        var pack = FestivalFixtures.glastonbury()
        pack.endDate = "2026-06-27"   // shrink the window so SUN falls outside
        expectFailure(pack, .dayOutsideFestival("2026-06-28"))
    }

    func testRejectsDayWithoutStages() {
        var pack = FestivalFixtures.glastonbury()
        pack.days[0].stages = []
        expectFailure(pack, .emptyDay("2026-06-27"))
    }

    func testRejectsStageWithoutSets() {
        var pack = FestivalFixtures.glastonbury()
        pack.days[0].stages[2].sets = []
        expectFailure(pack, .emptyStage(day: "2026-06-27", stage: "Arcadia"))
    }

    func testRejectsEmptyArtist() {
        var pack = FestivalFixtures.glastonbury()
        pack.days[0].stages[0].sets[0].artist = "  "
        expectFailure(pack, .emptyArtist(day: "2026-06-27", stage: "Pyramid Stage"))
    }

    func testRejectsSetEndingBeforeItStarts() {
        var pack = FestivalFixtures.glastonbury()
        pack.days[0].stages[0].sets[0].end = pack.days[0].stages[0].sets[0].start
        expectFailure(pack, .invalidWindow(artist: "Little Simz"))
    }

    func testRejectsOverlapWithinOneStage() {
        var pack = FestivalFixtures.glastonbury()
        // Stretch Little Simz into Fred again..'s slot on the same stage.
        pack.days[0].stages[0].sets[0].end = FestivalFixtures.date("2026-06-27T22:30")
        expectFailure(pack, .overlapWithinStage(stage: "Pyramid Stage",
                                                first: "Little Simz", second: "Fred again.."))
    }

    func testAcceptsBackToBackSetsOnOneStage() throws {
        // Overmono ends exactly when Jayda G starts (01:00) — a handover, not an overlap.
        XCTAssertNoThrow(try FestivalPackValidator.validate(FestivalFixtures.glastonbury()))
    }

    func testRejectsSetBeforeTheDayWindowOpens() {
        var pack = FestivalFixtures.glastonbury()
        // 05:00 breakfast set starts before the 06:00 rollover — belongs to the previous poster day.
        pack.days[0].stages[0].sets[0] = FestivalFixtures.set(
            "Early Riser", "2026-06-27T05:00", "2026-06-27T05:45")
        expectFailure(pack, .setOutsideDay(day: "2026-06-27", artist: "Early Riser"))
    }
}
