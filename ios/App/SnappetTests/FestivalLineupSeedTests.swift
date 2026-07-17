import XCTest
@testable import Snappet

/// The now-anchored UI-test seed (festival prompt 02): whatever the wall clock says, the seeded
/// pack must validate, put one set live at `now`, and offer the clash pair — that's the contract
/// the Festival XCUITests stand on. Swept across a week of hourly `now`s (incl. the 06:00
/// day-rollover edge the synthetic-offset trick exists to dodge).
final class FestivalLineupSeedTests: XCTestCase {

    private var sweptNows: [Date] {
        // Hourly for 7 days from an arbitrary epoch (covers every local time-of-day + DST-ish
        // boundaries), plus a few odd minutes.
        let base = Date(timeIntervalSince1970: 1_782_000_000)
        var nows = (0..<(7 * 24)).map { base.addingTimeInterval(Double($0) * 3600) }
        nows += [base.addingTimeInterval(37 * 60), base.addingTimeInterval(5 * 3600 + 59 * 60)]
        return nows
    }

    func testSeedValidatesAndHasALiveSetAtAnyWallClockTime() throws {
        for now in sweptNows {
            let pack = FestivalLineupSeed.pack(now: now)
            XCTAssertNoThrow(try FestivalPackValidator.validate(pack),
                             "seed must validate at now=\(now)")
            let live = FestivalSchedule.liveSet(in: pack, starred: [], now: now)
            XCTAssertEqual(live?.artist, "Fred Midnight",
                           "the anchor set must be live at now=\(now)")
            XCTAssertEqual(FestivalSchedule.defaultDayDate(in: pack, now: now), pack.days[0].date,
                           "the default tab must be the live day at now=\(now)")
        }
    }

    func testSeedOffsetIsAlwaysARealWorldQuarterHourOffset() {
        for now in sweptNows {
            let offset = FestivalLineupSeed.utcOffset(anchoring: now)
            XCTAssertTrue(FestivalPackValidator.utcOffsetRange.contains(offset))
            XCTAssertEqual(offset % 900, 0, "offsets snap to 15 min")
            // The anchor promise: festival-local time at `now` is 18:00 ± 7.5 min.
            let localSeconds = (Int(now.timeIntervalSince1970.rounded()) + offset)
                .quotientAndRemainder(dividingBy: 86_400).remainder
            let positive = (localSeconds % 86_400 + 86_400) % 86_400
            let drift = abs(positive - FestivalLineupSeed.anchorHour * 3600)
            XCTAssertLessThanOrEqual(min(drift, 86_400 - drift), 450,
                                     "local anchor drifted \(drift)s at now=\(now)")
        }
    }

    func testSeedOffersTheClashPairAndTwoDayTabs() {
        let now = Date(timeIntervalSince1970: 1_782_345_678)
        let pack = FestivalLineupSeed.pack(now: now)
        XCTAssertEqual(FestivalSchedule.dayTabs(for: pack).count, 2)

        // Star Overtone + Electric Fern (19:00–20:30 vs 19:15–20:45) → both clash.
        let overtone = pack.allSets.first { $0.artist == "Overtone" }!
        let fern = pack.allSets.first { $0.artist == "Electric Fern" }!
        let clashing = FestivalSchedule.clashingSetIDs(in: pack, starred: [overtone.id, fern.id])
        XCTAssertEqual(clashing, [overtone.id, fern.id])
        // Starring the back-to-back pair instead is clean.
        let jade = pack.allSets.first { $0.artist == "Jade Groove" }!
        XCTAssertTrue(FestivalSchedule.clashingSetIDs(in: pack,
                                                      starred: [overtone.id, jade.id]).isEmpty)
    }
}
