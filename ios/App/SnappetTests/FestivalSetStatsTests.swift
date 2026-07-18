import XCTest
@testable import Snappet

/// Set-detail + recap derivations (festival prompt 03, pure): HR slicing under a set's window via
/// `HRWindowSlicer`, the peak/average/danced stats, chart-session selection, and the recap hero +
/// ♥-ranked artist rows — all over the Glastonbury fixture.
final class FestivalSetStatsTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()

    private func set(_ artist: String) -> FestivalSet {
        FestivalFixtures.set(named: artist, in: pack)
    }

    /// A dance session covering Saturday evening (19:30–00:00 local) at 1 sample/min:
    /// 100 bpm baseline, 171 mid-Fred-again.., 150 mid-Little-Simz.
    private func saturdaySession(id: UUID = UUID()) -> FestivalSessionSnapshot {
        let start = FestivalFixtures.date("2026-06-27T19:30")
        let end = FestivalFixtures.date("2026-06-28T00:00")
        let fred = set("Fred again.."), simz = set("Little Simz")
        var series: [HRPoint] = []
        var t: Double = 0
        let duration = end.timeIntervalSince(start)
        while t <= duration {
            let instant = start.addingTimeInterval(t)
            var bpm = 100.0
            for (window, peak) in [(fred.window, 171.0), (simz.window, 150.0)] {
                let f = instant.timeIntervalSince(window.start) / window.duration
                if f >= 0, f <= 1 { bpm = max(bpm, 100 + (peak - 100) * sin(f * .pi)) }
            }
            series.append(HRPoint(t: t, bpm: bpm.rounded()))
            t += 60
        }
        return FestivalSessionSnapshot(id: id, startedAt: start, endedAt: end,
                                       hrSeries: series, maxHR: 190, restHR: 55)
    }

    // MARK: - Slicing

    func testHRSliceCoversTheSetWindowRebased() {
        let fred = set("Fred again..")
        let session = saturdaySession()
        let slice = FestivalSetStats.hrSlice(for: fred, session: session)
        XCTAssertGreaterThanOrEqual(slice.count, 2)
        XCTAssertEqual(slice.first?.t, 0)
        XCTAssertEqual(slice.last!.t, fred.window.duration, accuracy: 0.001,
                       "the slice is rebased to seconds-into-the-set")
        XCTAssertEqual(FestivalSetStats.peak(of: slice)!.bpm, 171, accuracy: 1)
    }

    func testHRSliceClampsToTheSessionsOwnCoverage() {
        // Session ends 30 min into Overmono (23:30–01:00) — the slice charts what was recorded.
        let overmono = set("Overmono")
        let session = saturdaySession()
        let slice = FestivalSetStats.hrSlice(for: overmono, session: session)
        XCTAssertGreaterThanOrEqual(slice.count, 2)
        XCTAssertEqual(slice.last!.t, 30 * 60, accuracy: 61,
                       "the window is session-coverage-clamped, not 90 min of flat clamp line")
    }

    func testHRSliceIsEmptyWhenTheSessionNeverOverlapped() {
        let sunday = set("Four Tet")
        XCTAssertTrue(FestivalSetStats.hrSlice(for: sunday, session: saturdaySession()).isEmpty)
    }

    // MARK: - Stats

    func testPeakCalloutNamesTheDropFestivalLocal() {
        let fred = set("Fred again..")
        let session = saturdaySession()
        let slice = FestivalSetStats.hrSlice(for: fred, session: session)
        let callout = FestivalSetStats.peakCallout(slice: slice, sliceStart: fred.start,
                                                   utcOffsetSeconds: pack.utcOffsetSeconds)
        // The synthetic curve peaks mid-set (~23:00 festival-local; rounding makes a small 171
        // plateau, so assert the hour): a wrong-timezone mapping would print 21:xx or the device
        // zone's hour instead.
        XCTAssertNotNil(callout)
        XCTAssertTrue(callout!.hasPrefix("peak 171 ♥ at 22:5") || callout!.hasPrefix("peak 171 ♥ at 23:0"),
                      "got \(callout!)")
    }

    func testAverageAndDancedMath() {
        XCTAssertNil(FestivalSetStats.average(of: []))
        XCTAssertEqual(FestivalSetStats.average(of: [HRPoint(t: 0, bpm: 100),
                                                     HRPoint(t: 60, bpm: 140)]), 120)

        let fred = set("Fred again..")
        let attendance = [
            FestivalAttendanceSnapshot(setID: fred.id, sessionID: UUID(),
                                       startedAt: fred.start,
                                       endedAt: fred.start.addingTimeInterval(40 * 60)),
            FestivalAttendanceSnapshot(setID: fred.id, sessionID: UUID(),
                                       startedAt: fred.start.addingTimeInterval(60 * 60),
                                       endedAt: fred.start.addingTimeInterval(72 * 60)),
        ]
        XCTAssertEqual(FestivalSetStats.dancedSeconds(for: fred.id, attendance: attendance),
                       52 * 60, "stretches sum")
        XCTAssertEqual(FestivalSetStats.dancedLabel(52 * 60), "52 min")
        XCTAssertEqual(FestivalSetStats.dancedLabel(88 * 60), "1:28")
    }

    func testChartSessionPrefersTheClaimedSession() {
        let fred = set("Fred again..")
        let claimed = saturdaySession()
        let other = saturdaySession()
        let attendance = [FestivalAttendanceSnapshot(setID: fred.id, sessionID: claimed.id,
                                                     startedAt: fred.start, endedAt: fred.end)]
        let picked = FestivalSetStats.chartSession(for: fred, sessions: [other, claimed],
                                                   attendance: attendance)
        XCTAssertEqual(picked?.id, claimed.id)
        // No claim → longest-overlap fallback still charts something.
        XCTAssertNotNil(FestivalSetStats.chartSession(for: fred, sessions: [other],
                                                      attendance: []))
    }

    // MARK: - Recap (frame 11)

    func testRecapHeroAndArtistRanking() {
        let fred = set("Fred again.."), simz = set("Little Simz")
        let session = saturdaySession()
        let attendance = [
            FestivalAttendanceSnapshot(setID: simz.id, sessionID: session.id,
                                       startedAt: simz.start, endedAt: simz.end),      // 75 min
            FestivalAttendanceSnapshot(setID: fred.id, sessionID: session.id,
                                       startedAt: fred.start,
                                       endedAt: fred.start.addingTimeInterval(88 * 60)), // 88 min
        ]
        let tags = [
            FestivalTagSnapshot(mediaID: UUID(), setID: fred.id, artist: fred.artist,
                                stage: fred.stage, isAuto: true),
            FestivalTagSnapshot(mediaID: UUID(), setID: fred.id, artist: fred.artist,
                                stage: fred.stage, isAuto: false),
            FestivalTagSnapshot(mediaID: UUID(), setID: simz.id, artist: simz.artist,
                                stage: simz.stage, isAuto: true),
        ]
        let (hero, artists) = FestivalRecap.build(pack: pack, sessions: [session],
                                                  attendance: attendance, tags: tags)

        XCTAssertEqual(hero.nights, 1, "both sets are Saturday — one night, rollover-aware")
        XCTAssertEqual(hero.setsSeen, 2)
        XCTAssertEqual(hero.clipCount, 3)
        XCTAssertEqual(hero.peakBpm, 171)
        XCTAssertEqual(hero.dancedSeconds, Double((75 + 88) * 60), accuracy: 1)
        XCTAssertEqual(hero.nightsLine, "1 night on the floor")
        XCTAssertEqual(hero.dancedStat, "2:43")

        // Fred (♥171) outranks Simz (♥150) — ranked by YOUR heart rate, not clip count.
        XCTAssertEqual(artists.map(\.artist), ["Fred again..", "Little Simz"])
        XCTAssertEqual(artists[0].peakBpm, 171)
        XCTAssertEqual(artists[0].clipCount, 2)
        XCTAssertEqual(artists[0].dayLabel, "Sat")
        XCTAssertEqual(artists[1].peakBpm, 150)
    }

    func testRecapCountsATaggedButNeverClaimedSet() {
        // Clips prove you were there even if you never pressed "I'm here".
        let simz = set("Little Simz")
        let session = saturdaySession()
        let tags = [FestivalTagSnapshot(mediaID: UUID(), setID: simz.id, artist: simz.artist,
                                        stage: simz.stage, isAuto: true)]
        let (hero, artists) = FestivalRecap.build(pack: pack, sessions: [session],
                                                  attendance: [], tags: tags)
        XCTAssertEqual(hero.setsSeen, 1)
        XCTAssertEqual(hero.dancedSeconds, 0)
        XCTAssertEqual(artists.first?.artist, "Little Simz")
        XCTAssertEqual(artists.first?.peakBpm, 150, "the HR ranking still charts from coverage")
    }

    func testRecapIgnoresTagsForSetsMissingFromThePack() {
        let (hero, artists) = FestivalRecap.build(
            pack: pack, sessions: [], attendance: [],
            tags: [FestivalTagSnapshot(mediaID: UUID(), setID: UUID(), artist: "Ghost",
                                       stage: "Nowhere", isAuto: true)])
        XCTAssertEqual(hero.setsSeen, 0)
        XCTAssertTrue(artists.isEmpty)
    }
}
