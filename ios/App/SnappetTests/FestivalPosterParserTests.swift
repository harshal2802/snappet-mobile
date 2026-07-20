import XCTest
@testable import Snappet

/// The pure heuristic FLOOR for poster scanning (festival prompt 06): OCR text → editable
/// `FestivalDraft` → `toPack()` → the `FestivalPackValidator` gate. Driven entirely off OCR-text
/// fixtures — no camera, no Vision, no simulator, exactly as the rest of the festival suites do.
final class FestivalPosterParserTests: XCTestCase {

    // A realistic multi-line poster: a title, a location, a date, two stages, single-time and
    // ranged sets, artist names with spaces.
    private let poster = """
    Sunset Sounds 2026
    Riverside Park
    2026-08-15

    MAIN STAGE
    18:00 Opening Act
    19:30 The Midnights
    21:00 - 22:30 Neon Parade

    RIVER STAGE
    20:00 DJ Marlow
    22:00 Aurora Skies
    """

    // MARK: - The happy path: a poster structures into days → stages → sets

    func testParsesTitleLocationDateStagesAndSets() {
        let d = FestivalPosterParser.parse(ocrText: poster, defaultOffsetSeconds: 0)

        XCTAssertEqual(d.name, "Sunset Sounds 2026")
        XCTAssertEqual(d.location, "Riverside Park")
        XCTAssertEqual(d.startDate, "2026-08-15")
        XCTAssertEqual(d.endDate, "2026-08-15")
        XCTAssertEqual(d.source, .heuristic)

        XCTAssertEqual(d.days.count, 1)
        let day = d.days[0]
        XCTAssertEqual(day.date, "2026-08-15")
        XCTAssertEqual(day.stages.map(\.name), ["Main Stage", "River Stage"])

        let main = day.stages[0]
        XCTAssertEqual(main.sets.map(\.artist), ["Opening Act", "The Midnights", "Neon Parade"])
        // A single-time row fabricates a +60-minute end; a ranged row keeps its printed end.
        XCTAssertEqual(main.sets[0].start, "18:00")
        XCTAssertEqual(main.sets[0].end, "19:00")
        XCTAssertEqual(main.sets[2].start, "21:00")
        XCTAssertEqual(main.sets[2].end, "22:30")

        XCTAssertEqual(day.stages[1].sets.map(\.artist), ["DJ Marlow", "Aurora Skies"])
        XCTAssertEqual(d.allSetCount, 5)
    }

    func testDraftBuildsAPackThatValidates() throws {
        let d = FestivalPosterParser.parse(ocrText: poster, defaultOffsetSeconds: 0)
        let pack = d.toPack()
        let v = try FestivalPackValidator.validate(pack)
        XCTAssertEqual(v.dayCount, 1)
        XCTAssertEqual(v.stageCount, 2)
        XCTAssertEqual(v.setCount, 5)
    }

    // MARK: - Garbage in → an empty-but-valid draft the user fills (never a dead end)

    func testGarbageYieldsANameGuessAndNoDays() {
        let d = FestivalPosterParser.parse(ocrText: "asdf qwer\nzxcv\n!!!", defaultOffsetSeconds: 0)
        XCTAssertEqual(d.name, "asdf qwer")     // first line is the title guess
        XCTAssertTrue(d.days.isEmpty)           // nothing schedule-shaped to parse
        XCTAssertEqual(d.allSetCount, 0)
    }

    func testEmptyDraftFailsValidationWithTheRightTypedError() {
        let d = FestivalPosterParser.parse(ocrText: "just some words\nnothing here", defaultOffsetSeconds: 0)
        XCTAssertThrowsError(try FestivalPackValidator.validate(d.toPack())) { error in
            XCTAssertEqual(error as? FestivalPackValidator.Failure, .noDays,
                           "an empty draft surfaces the exact validator error, it never installs")
        }
    }

    func testWithinStageOverlapSurfacesTheTypedError() {
        let text = """
        Clash Fest
        2026-09-01
        MAIN
        20:00 - 21:00 A
        20:30 - 21:30 B
        """
        let pack = FestivalPosterParser.parse(ocrText: text, defaultOffsetSeconds: 0).toPack()
        XCTAssertThrowsError(try FestivalPackValidator.validate(pack)) { error in
            XCTAssertEqual(error as? FestivalPackValidator.Failure,
                           .overlapWithinStage(stage: "Main", first: "A", second: "B"))
        }
    }

    // MARK: - Cross-midnight + time-token robustness

    func testLateNightSetCrossesMidnightWhenTheEndIsEarlierThanTheStart() {
        let text = """
        Night Fest
        2026-07-04
        WAREHOUSE
        23:00 - 00:30 Closing DJ
        """
        let pack = FestivalPosterParser.parse(ocrText: text, defaultOffsetSeconds: 0).toPack()
        let set = pack.allSets.first { $0.artist == "Closing DJ" }!
        // 23:00 → 00:30 the next morning is a 90-minute window, not a negative one.
        XCTAssertEqual(set.window.duration, 90 * 60, accuracy: 1)
        XCTAssertGreaterThan(set.end, set.start)
        XCTAssertNoThrow(try FestivalPackValidator.validate(pack))
    }

    func testTimeNormalizationAndArtistResidue() {
        XCTAssertEqual(FestivalPosterParser.normalizedTime("9:05"), "09:05")
        XCTAssertEqual(FestivalPosterParser.normalizedTime("21.00"), "21:00")
        XCTAssertNil(FestivalPosterParser.normalizedTime("2500"))
        XCTAssertNil(FestivalPosterParser.normalizedTime("Overmono"))
        XCTAssertEqual(FestivalPosterParser.artistResidue(of: "21:00 - 22:30 Neon Parade"), "Neon Parade")
        XCTAssertEqual(FestivalPosterParser.artistResidue(of: "The Midnights 19:30"), "The Midnights")
    }

    // MARK: - Local pack id: deterministic, stable, converges set content ids

    func testLocalPackIDIsDeterministicAndPrefixed() {
        let a = FestivalPosterParser.parse(ocrText: poster, defaultOffsetSeconds: 0).localPackID
        let b = FestivalPosterParser.parse(ocrText: poster, defaultOffsetSeconds: 0).localPackID
        XCTAssertEqual(a, b, "the same poster text converges on the same local pack id")
        XCTAssertTrue(a.hasPrefix("poster-"), "locally-built packs carry a poster- slug")
        let other = FestivalPosterParser.parse(ocrText: "Other Fest\n2026-01-01\nMAIN\n20:00 X",
                                               defaultOffsetSeconds: 0).localPackID
        XCTAssertNotEqual(a, other, "different lineups get different local ids")
    }

    func testTwoScansOfTheSamePosterConvergeOnTheSameSetContentIDs() {
        let p1 = FestivalPosterParser.parse(ocrText: poster, defaultOffsetSeconds: 0).toPack()
        let p2 = FestivalPosterParser.parse(ocrText: poster, defaultOffsetSeconds: 0).toPack()
        XCTAssertEqual(p1.id, p2.id)
        XCTAssertEqual(p1.allSets.map(\.id), p2.allSets.map(\.id),
                       "content-derived set ids are stable across re-scans (UUIDv5, prompt 01)")
    }
}
