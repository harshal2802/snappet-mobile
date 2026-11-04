import XCTest
@testable import Snappet

/// Lineup edits (prompt 232): an overlay on the installed pack that keeps every set's content id,
/// so stars / "I'm here" / clip tags survive a late start, a stage-wide delay, or a renamed act.
final class FestivalLineupEditsTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()
    private func set(_ name: String, in p: FestivalPack? = nil) -> FestivalSet {
        FestivalFixtures.set(named: name, in: p ?? pack)
    }

    func testEmptyEditsReturnTheOriginal() {
        XCTAssertEqual(FestivalLineupEdits().apply(to: pack), pack)
        XCTAssertEqual(FestivalLineupEdits().encoded(), Data())
        XCTAssertTrue(FestivalLineupEdits.decode(Data()).isEmpty)
    }

    func testTimeChangeKeepsTheSetIDAndRoundTrips() throws {
        let fred = set("Fred again..")
        var edits = FestivalLineupEdits()
        edits.update(fred.id, start: fred.start + 1800, end: fred.end + 1800, original: pack)
        let decoded = FestivalLineupEdits.decode(edits.encoded())
        XCTAssertEqual(decoded, edits)
        let edited = decoded.apply(to: pack)
        let moved = try XCTUnwrap(edited.setsByID[fred.id], "the content id must not change")
        XCTAssertEqual(moved.start, fred.start + 1800)
        XCTAssertEqual(moved.end, fred.end + 1800)
        XCTAssertEqual(decoded.originalTimes(of: fred.id, in: pack), fred.window)
    }

    func testEditingBackToThePosterTimeClearsTheChange() {
        let fred = set("Fred again..")
        var edits = FestivalLineupEdits()
        edits.update(fred.id, start: fred.start + 600, original: pack)
        edits.update(fred.id, start: fred.start, original: pack)
        XCTAssertTrue(edits.isEmpty)
    }

    func testResetTimesKeepsOtherChanges() {
        let fred = set("Fred again..")
        var edits = FestivalLineupEdits()
        edits.update(fred.id, artist: "Fred again.. b2b Four Tet", start: fred.start + 600, original: pack)
        edits.resetTimes(fred.id)
        XCTAssertNil(edits.originalTimes(of: fred.id, in: pack))
        XCTAssertEqual(edits.apply(to: pack).setsByID[fred.id]?.artist, "Fred again.. b2b Four Tet")
    }

    func testRemoveAndAdd() throws {
        let simz = set("Little Simz")
        var edits = FestivalLineupEdits()
        edits.remove(simz.id)
        let start = FestivalFixtures.date("2026-06-27T18:00")
        let id = edits.add(artist: "Surprise Guest", stage: "The Park", start: start,
                           end: start + 3600, festivalID: pack.id)
        let edited = edits.apply(to: pack)
        XCTAssertNil(edited.setsByID[simz.id])
        let guest = try XCTUnwrap(edited.setsByID[id])
        XCTAssertEqual(guest.stage, "The Park")
        let sat = try XCTUnwrap(edited.days.first { $0.date == "2026-06-27" })
        XCTAssertEqual(sat.stages.last?.name, "The Park", "a new stage is appended after the poster's")
        XCTAssertEqual(edited.allSets.count, pack.allSets.count)

        // Removing an added set drops it rather than tombstoning.
        edits.remove(id)
        XCTAssertTrue(edits.added.isEmpty)
    }

    func testMovingAStartPastRolloverRefilesTheDay() throws {
        let olivia = set("Olivia Dean")   // Sun 19:00
        var edits = FestivalLineupEdits()
        // Into Saturday night (Sat 22:00) — it should show under Saturday now.
        edits.update(olivia.id, start: FestivalFixtures.date("2026-06-27T22:00"),
                     end: FestivalFixtures.date("2026-06-27T23:00"), original: pack)
        let edited = edits.apply(to: pack)
        let sat = try XCTUnwrap(edited.days.first { $0.date == "2026-06-27" })
        XCTAssertTrue(sat.allSets.contains { $0.id == olivia.id })
        let sun = try XCTUnwrap(edited.days.first { $0.date == "2026-06-28" })
        XCTAssertFalse(sun.stages.contains { $0.name == "Pyramid Stage" },
                       "a stage left empty drops out of that day")
    }

    func testRenameFestival() {
        var edits = FestivalLineupEdits()
        edits.name = "Glasto"
        XCTAssertEqual(edits.apply(to: pack).name, "Glasto")
    }

    // MARK: Delay

    func testDelayAllStagesFromATimeMovesLaterSetsAndExtendsPlayingOnes() {
        let from = FestivalFixtures.date("2026-06-27T23:15")
        let t = FestivalLineupEdits.delayTargets(in: pack, stages: nil, from: from)
        XCTAssertEqual(Set(t.moved.map(\.artist)), ["Overmono", "Jayda G"])
        XCTAssertEqual(Set(t.extended.map(\.artist)), ["Fred again..", "Eric Prydz"])

        var edits = FestivalLineupEdits()
        edits.shift(startAndEnd: t.moved, endOnly: t.extended, by: 1800, original: pack)
        let edited = edits.apply(to: pack)
        XCTAssertEqual(edited.setsByID[set("Overmono").id]?.start, set("Overmono").start + 1800)
        XCTAssertEqual(edited.setsByID[set("Fred again..").id]?.start, set("Fred again..").start,
                       "a set already playing keeps its start")
        XCTAssertEqual(edited.setsByID[set("Fred again..").id]?.end, set("Fred again..").end + 1800)
        XCTAssertEqual(edited.setsByID[set("Four Tet").id], set("Four Tet"),
                       "the next poster day is never touched")
    }

    func testDelayOneStage() {
        let from = FestivalFixtures.date("2026-06-27T19:00")
        let t = FestivalLineupEdits.delayTargets(in: pack, stages: ["West Holts"], from: from)
        XCTAssertEqual(t.moved.map(\.artist).sorted(), ["Jayda G", "Overmono"])
        XCTAssertTrue(t.extended.isEmpty)
    }

    func testDelayOutsideTheFestivalMovesNothing() {
        let t = FestivalLineupEdits.delayTargets(in: pack, stages: nil,
                                                 from: FestivalFixtures.date("2026-07-15T20:00"))
        XCTAssertTrue(t.moved.isEmpty && t.extended.isEmpty)
    }

    func testLaterSetsOnTheSameStageSameDay() {
        XCTAssertEqual(FestivalLineupEdits.laterSets(after: set("Overmono"), in: pack).map(\.artist),
                       ["Jayda G"])
        XCTAssertEqual(FestivalLineupEdits.laterSets(after: set("Little Simz"), in: pack).map(\.artist),
                       ["Fred again.."])
        XCTAssertTrue(FestivalLineupEdits.laterSets(after: set("Jayda G"), in: pack).isEmpty)
    }

    func testShiftLabel() {
        XCTAssertEqual(FestivalLineupEdits.shiftLabel(1800), "+30 min")
        XCTAssertEqual(FestivalLineupEdits.shiftLabel(-900), "−15 min")
        XCTAssertEqual(FestivalLineupEdits.shiftLabel(3600), "+1 h")
        XCTAssertEqual(FestivalLineupEdits.shiftLabel(4500), "+1 h 15")
    }
}
