import XCTest
@testable import Snappet

/// The prompt-03 night seed's contract: at ANY wall-clock time, the three seeded clips must land in
/// exactly the review states the XCUITests stand on — one silent auto tag (mid Neon Harbor), one
/// "between stages", one "two sets live" — and the synthetic curve must peak 171 inside Neon
/// Harbor's window (the recap ♥-ranking anchor). Swept like `FestivalLineupSeedTests`.
final class FestivalNightSeedTests: XCTestCase {

    private var sweptNows: [Date] {
        let base = Date(timeIntervalSince1970: 1_782_000_000)
        var nows = (0..<(7 * 24)).map { base.addingTimeInterval(Double($0) * 3600) }
        nows += [base.addingTimeInterval(37 * 60), base.addingTimeInterval(5 * 3600 + 59 * 60)]
        return nows
    }

    /// Rebuild the seed's clip stamps for a given `now` (the same festival-local placements the
    /// seed uses: 14:45 / 15:45 / 16:45 on day 1).
    private func seedWorld(now: Date) -> (pack: FestivalPack, stamps: [ClipStamp],
                                          hints: [FestivalSessionHint], ids: [UUID]) {
        let pack = FestivalLineupSeed.pack(now: now)
        let window = pack.days[0].window(utcOffsetSeconds: pack.utcOffsetSeconds)!
        func at(_ hour: Int, _ minute: Int) -> Date {
            window.start.addingTimeInterval(Double((hour - FestivalDay.rolloverHour) * 3600 + minute * 60))
        }
        let ids = [UUID(), UUID(), UUID()]
        let stamps = [
            ClipStamp(id: ids[0].uuidString, captureDate: at(14, 45), duration: 18),
            ClipStamp(id: ids[1].uuidString, captureDate: at(15, 45), duration: 12),
            ClipStamp(id: ids[2].uuidString, captureDate: at(16, 45), duration: 20),
        ]
        let neon = pack.allSets.first { $0.artist == "Neon Harbor" }!
        let bloom = pack.allSets.first { $0.artist == "Static Bloom" }!
        let hints = [
            FestivalSessionHint(setID: neon.id, interval: DateInterval(start: at(14, 30), end: at(15, 30))),
            FestivalSessionHint(setID: bloom.id, interval: DateInterval(start: at(16, 0), end: at(16, 40))),
        ]
        return (pack, stamps, hints, ids)
    }

    func testSeedClipsLandInTheThreeReviewStatesAtAnyWallClockTime() {
        for now in sweptNows {
            let world = seedWorld(now: now)
            let assignments = FestivalSetMatcher.assignments(for: world.stamps, in: world.pack,
                                                             hints: world.hints)
            let plan = FestivalTagging.plan(assignments: assignments, existing: [])

            XCTAssertEqual(plan.upserts.map(\.mediaID), [world.ids[0]],
                           "exactly clip A auto-tags at now=\(now)")
            XCTAssertEqual(plan.upserts.first?.set.artist, "Neon Harbor")
            XCTAssertEqual(Set(plan.reviewMediaIDs), [world.ids[1], world.ids[2]],
                           "clips B and C need the user at now=\(now)")

            let byID = Dictionary(uniqueKeysWithValues: assignments.map {
                (UUID(uuidString: $0.clipID)!, $0)
            })
            XCTAssertEqual(FestivalTagging.caption(for: byID[world.ids[1]]!.reason), "between stages")
            XCTAssertEqual(FestivalTagging.caption(for: byID[world.ids[2]]!.reason), "two sets live")
        }
    }

    func testSyntheticCurvePeaksInsideNeonHarbor() {
        let now = Date(timeIntervalSince1970: 1_782_345_678)
        let pack = FestivalLineupSeed.pack(now: now)
        let window = pack.days[0].window(utcOffsetSeconds: pack.utcOffsetSeconds)!
        let neon = pack.allSets.first { $0.artist == "Neon Harbor" }!
        let start = window.start.addingTimeInterval(Double((14 - FestivalDay.rolloverHour) * 3600 + 15 * 60))
        let series = FestivalNightSeed.hrSeries(
            sessionStart: start,
            peakWindows: [(neon.start, neon.end, 171)],
            duration: 3.5 * 3600)

        let top = series.max { $0.bpm < $1.bpm }!
        XCTAssertEqual(top.bpm, 171)
        let peakInstant = start.addingTimeInterval(top.t)
        XCTAssertTrue(neon.window.contains(peakInstant), "the drop lands inside the set")
        XCTAssertTrue(series.allSatisfy { $0.bpm >= 112 && $0.bpm <= 171 })
    }
}
