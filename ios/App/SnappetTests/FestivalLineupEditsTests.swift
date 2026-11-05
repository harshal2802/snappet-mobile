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

/// Prompt 232 completeness: added days, location, merge/restrict for sharing, old-blob decode.
final class FestivalLineupEditsSharingTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()
    private func set(_ name: String) -> FestivalSet { FestivalFixtures.set(named: name, in: pack) }

    func testAddedDayWidensTheFestivalAndTakesSets() throws {
        var edits = FestivalLineupEdits()
        edits.addedDays = ["2026-06-29"]
        edits.location = "Pilton"
        let start = FestivalFixtures.date("2026-06-29T20:00")
        let id = edits.add(artist: "Encore", stage: "Pyramid Stage", start: start, end: start + 3600,
                           festivalID: pack.id)
        let edited = edits.apply(to: pack)
        XCTAssertEqual(edited.days.map(\.date), ["2026-06-27", "2026-06-28", "2026-06-29"])
        XCTAssertEqual(edited.endDate, "2026-06-29")
        XCTAssertEqual(edited.location, "Pilton")
        let monday = try XCTUnwrap(edited.days.last)
        XCTAssertEqual(monday.allSets.map(\.id), [id], "a set on an added day files under it")
    }

    func testAnEmptyAddedDayStillShows() {
        var edits = FestivalLineupEdits()
        edits.addedDays = ["2026-06-26"]
        let edited = edits.apply(to: pack)
        XCTAssertEqual(edited.days.first?.date, "2026-06-26")
        XCTAssertEqual(edited.startDate, "2026-06-26")
        XCTAssertTrue(edited.days.first?.stages.isEmpty ?? false)
    }

    func testOldBlobsWithoutNewKeysStillDecode() throws {
        let fred = set("Fred again..")
        let json = #"{"changes":[],"removed":["\#(fred.id.uuidString)"],"added":[]}"#
        let edits = FestivalLineupEdits.decode(Data(json.utf8))
        XCTAssertEqual(edits.removed, [fred.id])
        XCTAssertTrue(edits.addedDays.isEmpty)
        XCTAssertNil(edits.location)
    }

    func testMergingLetsTheirChangesWinAndUnionsTheRest() {
        let fred = set("Fred again..")
        var mine = FestivalLineupEdits()
        mine.update(fred.id, artist: "Fred", start: fred.start + 600, original: pack)
        mine.remove(set("Little Simz").id)
        var theirs = FestivalLineupEdits()
        theirs.update(fred.id, start: fred.start + 1800, original: pack)
        theirs.remove(set("Jayda G").id)
        let merged = mine.merging(theirs)
        XCTAssertEqual(merged.changes[fred.id]?.start, fred.start + 1800, "theirs wins per field")
        XCTAssertEqual(merged.changes[fred.id]?.artist, "Fred", "fields they didn't touch keep mine")
        XCTAssertEqual(merged.removed, [set("Little Simz").id, set("Jayda G").id])
    }

    func testRestrictedKeepsOnlyThePlansSets() {
        let fred = set("Fred again.."), simz = set("Little Simz")
        var edits = FestivalLineupEdits()
        edits.update(fred.id, start: fred.start + 600, original: pack)
        edits.update(simz.id, start: simz.start + 600, original: pack)
        let start = FestivalFixtures.date("2026-06-27T18:00")
        let guest = edits.add(artist: "Guest", stage: "Park", start: start, end: start + 3600,
                              festivalID: pack.id)
        _ = edits.add(artist: "Other", stage: "Park", start: start + 3600, end: start + 7200,
                      festivalID: pack.id)
        let r = edits.restricted(to: [fred.id, guest])
        XCTAssertEqual(Set(r.changes.keys), [fred.id])
        XCTAssertEqual(r.added.map(\.id), [guest])
    }

    // MARK: Sharing

    func testSharedLineupCarriesEditsAndKeepsOriginalIDs() throws {
        let fred = set("Fred again..")
        var edits = FestivalLineupEdits()
        edits.update(fred.id, start: fred.start + 1800, end: fred.end + 1800, original: pack)
        let shared = SharedLineup.plan(from: pack, starredSetIDs: [fred.id], title: "My plan", edits: edits)
        let decoded = try XCTUnwrap(SharedLineup(decoding: shared.encoded))
        XCTAssertEqual(decoded.carriedPack?.allSets.map(\.id), [fred.id],
                       "the ORIGINAL pack travels, so ids match everyone's copy")
        XCTAssertEqual(decoded.edits, edits.restricted(to: [fred.id]))
        XCTAssertEqual(decoded.displayPack?.setsByID[fred.id]?.start, fred.start + 1800,
                       "the receiver sees the delay")
    }

    func testCodesWithoutEditsStillDecode() throws {
        let shared = SharedLineup.lineup(from: pack, title: pack.name)
        let decoded = try XCTUnwrap(SharedLineup(decoding: shared.encoded))
        XCTAssertNil(decoded.edits)
        XCTAssertEqual(decoded.displayPack, decoded.carriedPack)
    }

    func testALocalLineupNeverFallsBackToAnInstallLink() {
        let big = FestivalFixtures.bigFestival(days: 3, stagesPerDay: 8, setsPerStage: 18)
        var local = big
        local.id = "mine-abc123def456"
        XCTAssertFalse(SharedLineup.lineup(from: local, title: "Mine").fitsInScannableQR)
        guard case .payload = SharedLineup.lineup(from: local, title: "Mine").scannableForm().content else {
            return XCTFail("a hand-made lineup has no host — it must travel whole")
        }
        guard case .installLink = SharedLineup.lineup(from: big, title: "Hosted").scannableForm().content else {
            return XCTFail("a hosted lineup still falls back to its install link")
        }
    }

    // MARK: Create a lineup

    func testBlankDraftIsADatedOneStageStarterWithAUniqueID() {
        let tz = TimeZone(secondsFromGMT: 3600)!
        let now = FestivalFixtures.date("2026-06-27T12:00")
        let a = FestivalDraft.blank(now: now, timeZone: tz)
        let b = FestivalDraft.blank(now: now, timeZone: tz)
        XCTAssertEqual(a.startDate, "2026-06-27")
        XCTAssertEqual(a.utcOffsetSeconds, 3600)
        XCTAssertEqual(a.source, .manual)
        XCTAssertEqual(a.days.first?.stages.first?.sets.count, 1, "an empty row ready to type into")
        XCTAssertTrue(a.localPackID.hasPrefix("mine-"))
        XCTAssertNotEqual(a.localPackID, b.localPackID, "two lineups you create never replace each other")
    }

    func testFilledBlankDraftValidatesAndNextDayNeverDuplicates() throws {
        var draft = FestivalDraft.blank(now: FestivalFixtures.date("2026-06-27T12:00"),
                                        timeZone: TimeZone(secondsFromGMT: 3600)!)
        draft.name = "Backyard Fest"
        draft.days[0].stages[0].sets[0] = .init(artist: "DJ Me", start: "22:00", end: "01:00")
        XCTAssertNoThrow(try FestivalPackValidator.validate(draft.toPack()))
        XCTAssertEqual(draft.nextDayDate, "2026-06-28")
        draft.days.append(.init(date: draft.nextDayDate, stages: []))
        XCTAssertEqual(draft.nextDayDate, "2026-06-29")
    }
}
