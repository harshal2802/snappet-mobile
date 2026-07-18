import Foundation
import SwiftData

/// Test-only PLAN seeding for the festival-prompt-04 UI walkthrough (the `FestivalLineupSeed`
/// sibling). Launching with `-uiTestSeedFestivalPlan` (which IMPLIES a fresh in-memory store, wired
/// in `SnappetApp`) installs the same now-anchored lineup as the lineup seed AND lays down a plan
/// with history, so the For-You sheet has something real to rank:
///
///   • a **star** on an upcoming set (`Jade Groove`) → a future reminder + a non-empty plan,
///   • a **past dance session** (a month ago) with synthetic HR and a closed `FestivalAttendance`
///     for `Overtone` — an artist who ALSO plays this festival — so the recommender surfaces
///     `Overtone` with a `.heardBefore` (HR-history) reason.
///
/// Everything installs through the real decode/validate/row path, so the seed can never persist a
/// shape production wouldn't. Pure builders are unit-tested (`FestivalPlanSeedTests`).
enum FestivalPlanSeed {
    static let argument = "-uiTestSeedFestivalPlan"

    /// The artist we both danced to in the past AND who plays this festival — the `.heardBefore` hook.
    static let historyArtist = "Overtone"
    /// The upcoming set we pre-star, so a future reminder + a plan exist.
    static let starredArtist = "Jade Groove"

    static func seedIfRequested(into context: ModelContext, now: Date = .now) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        // 1 — install this weekend's lineup (identical to the lineup seed, so set ids line up).
        let pack = FestivalLineupSeed.pack(now: now)
        guard let data = try? pack.fpackData(),
              let validated = try? FestivalPackValidator.validate(pack) else { return }
        context.insert(FestivalLineup(packID: pack.id, name: pack.name, location: pack.location,
                                      startDate: pack.startDate, endDate: pack.endDate,
                                      utcOffsetSeconds: pack.utcOffsetSeconds,
                                      stageCount: validated.stageCount, setCount: validated.setCount,
                                      sourceLabel: "UI-test seed", fpackData: data))

        // 2 — pre-star an upcoming set (a real future reminder target).
        if let starred = pack.allSets.first(where: { $0.artist == starredArtist }) {
            context.insert(FestivalStar(packID: pack.id, setID: starred.id))
        }

        // 3 — a past festival with a logged dance session, so `Overtone` has HR history.
        seedPastHistory(into: context, now: now)
        try? context.save()
    }

    /// A minimal decodable "past festival" lineup + a finished dance session with HR + a closed
    /// attendance for `historyArtist`, so `FestivalHistoryService` finds a real per-artist peak.
    static func seedPastHistory(into context: ModelContext, now: Date) {
        let pastStart = now.addingTimeInterval(-30 * 24 * 3600)   // a month ago

        // A tiny, valid pack for the past festival (so its row decodes and names the reason line).
        let pastPack = FestivalPack(
            id: "past-neon-nights", name: "Neon Nights '25", location: "Old Grounds",
            startDate: FestivalPlanSeed.dateString(pastStart, offset: 0),
            endDate: FestivalPlanSeed.dateString(pastStart, offset: 0),
            utcOffsetSeconds: 0,
            days: [FestivalDay(date: FestivalPlanSeed.dateString(pastStart, offset: 0),
                               stages: [FestivalStage(name: "Main", sets: [
                                    FestivalSet(artist: historyArtist,
                                                start: pastStart, end: pastStart.addingTimeInterval(3600))
                               ])])])
        if let pastData = try? pastPack.fpackData(),
           let pastValidated = try? FestivalPackValidator.validate(pastPack) {
            context.insert(FestivalLineup(packID: pastPack.id, name: pastPack.name,
                                          location: pastPack.location, startDate: pastPack.startDate,
                                          endDate: pastPack.endDate,
                                          utcOffsetSeconds: pastPack.utcOffsetSeconds,
                                          stageCount: pastValidated.stageCount,
                                          setCount: pastValidated.setCount,
                                          sourceLabel: "UI-test seed", fpackData: pastData))
        }

        // The dance session that carried the HR (synthetic curve peaking ~171).
        let session = WorkoutSession(routineID: nil, routineName: pastPack.name,
                                     startedAt: pastStart, exercises: [])
        session.completedAt = pastStart.addingTimeInterval(3600)
        session.hrSeries = hrCurve()
        context.insert(session)

        // The closed attendance stretch — exactly the shape "I'm here" produces.
        context.insert(FestivalAttendance(packID: pastPack.id,
                                          setID: pastPack.allSets.first?.id ?? UUID(),
                                          artist: historyArtist, stage: "Main",
                                          sessionID: session.id,
                                          startedAt: pastStart.addingTimeInterval(120),
                                          endedAt: pastStart.addingTimeInterval(1800)))
    }

    /// A 30-minute HR curve (t in seconds from session start), ramping 150 → 171 → 150 — so the
    /// attendance window (120…1800 s) captures a 171 peak.
    static func hrCurve() -> [HRPoint] {
        stride(from: 0, through: 1800, by: 60).map { t in
            let phase = Double(t) / 1800.0                 // 0…1
            let bpm = 150 + 21 * sin(phase * .pi)          // peaks at the midpoint
            return HRPoint(t: Double(t), bpm: bpm.rounded())
        }
    }

    private static func dateString(_ date: Date, offset: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offset) ?? .init(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
