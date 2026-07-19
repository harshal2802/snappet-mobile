import Foundation
@testable import Snappet

/// The shared fixture for the festival prompt-01 suites: a Glastonbury-shaped pack — 2 days × 3 stages,
/// BST (+01:00), with sets arranged to exercise every `FestivalSetMatcher.Reason` case (mirrors
/// wireframe frame 4's Saturday):
///
/// **SAT 2026-06-27** (all times festival-local, +01:00)
/// - Pyramid Stage:  Little Simz 20:00–21:15 · Fred again.. 22:15–23:45   ← 1 h gap between them
/// - West Holts:     Overmono 23:30–01:00 · Jayda G 01:00–02:30           ← adjacent + past midnight
/// - Arcadia:        Eric Prydz 23:00–00:30                               ← overlaps BOTH of the above
/// **SUN 2026-06-28**
/// - Pyramid Stage:  Olivia Dean 19:00–20:00
/// - West Holts:     Four Tet 22:00–23:30
/// - Arcadia:        Peggy Gou 23:00–00:30
enum FestivalFixtures {
    /// BST — Glastonbury's offset in late June.
    static let utcOffsetSeconds = 3600

    static func glastonbury() -> FestivalPack {
        FestivalPack(
            id: "glastonbury-2026",
            name: "Glastonbury 2026",
            location: "Worthy Farm, Pilton",
            startDate: "2026-06-27",
            endDate: "2026-06-28",
            utcOffsetSeconds: utcOffsetSeconds,
            days: [
                FestivalDay(date: "2026-06-27", stages: [
                    FestivalStage(name: "Pyramid Stage", sets: [
                        set("Little Simz", "2026-06-27T20:00", "2026-06-27T21:15"),
                        set("Fred again..", "2026-06-27T22:15", "2026-06-27T23:45"),
                    ]),
                    FestivalStage(name: "West Holts", sets: [
                        set("Overmono", "2026-06-27T23:30", "2026-06-28T01:00"),
                        set("Jayda G", "2026-06-28T01:00", "2026-06-28T02:30"),
                    ]),
                    FestivalStage(name: "Arcadia", sets: [
                        set("Eric Prydz", "2026-06-27T23:00", "2026-06-28T00:30"),
                    ]),
                ]),
                FestivalDay(date: "2026-06-28", stages: [
                    FestivalStage(name: "Pyramid Stage", sets: [
                        set("Olivia Dean", "2026-06-28T19:00", "2026-06-28T20:00"),
                    ]),
                    FestivalStage(name: "West Holts", sets: [
                        set("Four Tet", "2026-06-28T22:00", "2026-06-28T23:30"),
                    ]),
                    FestivalStage(name: "Arcadia", sets: [
                        set("Peggy Gou", "2026-06-28T23:00", "2026-06-29T00:30"),
                    ]),
                ]),
            ])
    }

    static func set(_ artist: String, _ start: String, _ end: String) -> FestivalSet {
        FestivalSet(artist: artist, start: date(start), end: date(end))
    }

    /// A deliberately large but VALID pack (festival prompt 05): enough sets that its payload blob
    /// blows past `SharedLineup.scannableURLByteCap`, so the share falls back to an install-link QR.
    /// Sets are packed back-to-back within each day's window (06:00→06:00), non-overlapping per stage.
    static func bigFestival(days: Int, stagesPerDay: Int, setsPerStage: Int) -> FestivalPack {
        let offset = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offset)!
        let base = cal.date(from: DateComponents(year: 2026, month: 6, day: 27))!

        func dayString(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }

        var dayModels: [FestivalDay] = []
        for dayIndex in 0..<days {
            let dayDate = cal.date(byAdding: .day, value: dayIndex, to: base)!
            let dayStart = cal.date(byAdding: .hour, value: 7, to: dayDate)!   // 07:00, inside the window
            var stages: [FestivalStage] = []
            for stageIndex in 0..<stagesPerDay {
                var sets: [FestivalSet] = []
                for setIndex in 0..<setsPerStage {
                    let start = dayStart.addingTimeInterval(Double(setIndex) * 12 * 60)
                    let end = start.addingTimeInterval(12 * 60)
                    sets.append(FestivalSet(artist: "Artist \(dayIndex)-\(stageIndex)-\(setIndex)",
                                            start: start, end: end))
                }
                stages.append(FestivalStage(name: "Stage \(stageIndex)", sets: sets))
            }
            dayModels.append(FestivalDay(date: dayString(dayDate), stages: stages))
        }

        return FestivalPack(id: "mega-fest-2026", name: "Mega Fest 2026", location: "Big Field",
                            startDate: dayString(base),
                            endDate: dayString(cal.date(byAdding: .day, value: days - 1, to: base)!),
                            utcOffsetSeconds: offset, days: dayModels)
    }

    /// `"2026-06-27T22:15"` in festival-local time (+01:00) → absolute `Date`.
    static func date(_ local: String, offsetSeconds: Int = utcOffsetSeconds) -> Date {
        let sign = offsetSeconds < 0 ? "-" : "+"
        let a = abs(offsetSeconds)
        let iso = local + String(format: ":00%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
        guard let d = FestivalPack.parseISO(iso) else {
            fatalError("bad fixture date: \(iso)")
        }
        return d
    }

    /// The fixture set with this artist (fixture artists are unique).
    static func set(named artist: String, in pack: FestivalPack) -> FestivalSet {
        pack.allSets.first { $0.artist == artist }!
    }
}
