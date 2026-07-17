import Foundation
import SwiftData

/// Test-only lineup seeding for the Festival UI tests (the `RecapClipSeed` pattern): launching with
/// `-uiTestSeedFestivalLineup` (which IMPLIES a fresh in-memory store, wired in `SnappetApp`) installs
/// a synthetic two-day festival whose schedule is anchored to **now**, so the NOW pill, the "I'm
/// here" CTA, and the live sheet are all exercisable on the simulator at any wall-clock time.
///
/// The anchoring trick: instead of shifting set times to the device clock (which collides with the
/// 06:00 day-rollover validator near dawn), the pack's **UTC offset is chosen** so that festival-local
/// time at `now` is ~18:00 — mid-window with hours of slack on both sides. The pack carries its own
/// fixed offset by design (prompt 01), so this is a legal pack, not a special case. Pure builder →
/// unit-tested across arbitrary `now`s (`FestivalLineupSeedTests`).
enum FestivalLineupSeed {
    static let argument = "-uiTestSeedFestivalLineup"

    /// Festival-local anchor hour the seed schedules around.
    static let anchorHour = 18

    /// The UTC offset that puts festival-local time at `now` at ~`anchorHour`:00, wrapped into the
    /// validator's real-world range and rounded to 15 min (offsets like +7:23 don't exist). The
    /// rounding moves the local anchor by ≤ 7.5 min — the seed's sets leave ≥ 30 min of margin.
    static func utcOffset(anchoring now: Date) -> Int {
        let secondsOfDayUTC = Int(now.timeIntervalSince1970.rounded())
            .quotientAndRemainder(dividingBy: 86_400).remainder
        let positive = (secondsOfDayUTC % 86_400 + 86_400) % 86_400
        var offset = anchorHour * 3600 - positive
        while offset > 12 * 3600 { offset -= 86_400 }
        while offset < -12 * 3600 { offset += 86_400 }
        let rounded = Int((Double(offset) / 900).rounded()) * 900
        return min(12 * 3600, max(-12 * 3600, rounded))
    }

    /// The seeded pack: two poster days, three stages, with (relative to `now`) one finished set,
    /// one set live RIGHT NOW, an overlapping upcoming pair (star both → clash), and a next-day
    /// stage so the day tabs have somewhere to go. Fictional artists — the UI tests key on them.
    static func pack(now: Date = .now) -> FestivalPack {
        let offset = utcOffset(anchoring: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offset) ?? .init(secondsFromGMT: 0)!
        let day1 = cal.dateComponents([.year, .month, .day], from: now)
        let day1Date = String(format: "%04d-%02d-%02d", day1.year!, day1.month!, day1.day!)
        let day2Start = cal.date(byAdding: .day, value: 1,
                                 to: cal.date(from: day1)!)!
        let day2 = cal.dateComponents([.year, .month, .day], from: day2Start)
        let day2Date = String(format: "%04d-%02d-%02d", day2.year!, day2.month!, day2.day!)

        func at(_ day: DateComponents, _ hour: Int, _ minute: Int) -> Date {
            var c = day
            c.hour = hour
            c.minute = minute
            return cal.date(from: c)!
        }
        func set(_ artist: String, _ day: DateComponents,
                 _ start: (Int, Int), _ end: (Int, Int)) -> FestivalSet {
            FestivalSet(artist: artist, start: at(day, start.0, start.1), end: at(day, end.0, end.1))
        }

        return FestivalPack(
            id: "snappet-test-festival",
            name: "Snappet Test Festival",
            location: "Simulator Fields",
            startDate: day1Date,
            endDate: day2Date,
            utcOffsetSeconds: offset,
            days: [
                FestivalDay(date: day1Date, stages: [
                    FestivalStage(name: "Pyramid Stage", sets: [
                        set("Neon Harbor", day1, (14, 30), (15, 30)),     // finished
                        set("Fred Midnight", day1, (17, 30), (19, 10)),   // LIVE at ~18:00
                    ]),
                    FestivalStage(name: "West Holts", sets: [
                        set("Overtone", day1, (19, 0), (20, 30)),         // upcoming, in ~1 h
                        set("Jade Groove", day1, (20, 30), (22, 0)),
                    ]),
                    FestivalStage(name: "Arcadia", sets: [
                        set("Electric Fern", day1, (19, 15), (20, 45)),   // overlaps Overtone → clash
                    ]),
                ]),
                FestivalDay(date: day2Date, stages: [
                    FestivalStage(name: "Pyramid Stage", sets: [
                        set("Solar Ana", day2, (20, 0), (21, 30)),
                    ]),
                ]),
            ])
    }

    /// Strictly guarded — no-ops without the launch argument. Installs the seeded pack through the
    /// same decode/validate/row path the real installer uses, so the seed can never install a shape
    /// production wouldn't.
    static func seedIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let pack = pack()
        guard let data = try? pack.fpackData(),
              let validated = try? FestivalPackValidator.validate(pack) else { return }
        context.insert(FestivalLineup(packID: pack.id, name: pack.name, location: pack.location,
                                      startDate: pack.startDate, endDate: pack.endDate,
                                      utcOffsetSeconds: pack.utcOffsetSeconds,
                                      stageCount: validated.stageCount,
                                      setCount: validated.setCount,
                                      sourceLabel: "UI-test seed",
                                      fpackData: data))
        try? context.save()
    }
}
