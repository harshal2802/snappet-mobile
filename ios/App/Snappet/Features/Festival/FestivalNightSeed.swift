import Foundation
import SwiftData

/// Test-only "a night already happened" seeding for the festival prompt-03 UI tests (the
/// `RecapClipSeed` posture): launching with `-uiTestSeedFestivalNight` (which IMPLIES the prompt-02
/// lineup seed and therefore a fresh in-memory store) adds, on top of the seeded lineup, one
/// FINISHED dance `WorkoutSession` earlier "today" (festival-local 14:15–17:45) with a synthetic HR
/// curve peaking mid-set, two closed "I'm here" stretches, and three sentinel clips placed to
/// exercise every review state:
///
/// - clip A · 14:45, mid **Neon Harbor** (14:30–15:30)     → within-set, auto-tags silently
/// - clip B · 15:45, in the 15:30–16:00 gap                 → "between stages", needs you
/// - clip C · 16:45, **Static Bloom** × **Coral Circuit**   → "two sets live", needs you
///
/// Tags for the auto case are written by the REAL pure pipeline (`FestivalSetMatcher` →
/// `FestivalTagging.plan`) at seed time, so the Clips feed shows the festival post + 🎪 chip on
/// first launch with zero UI-side setup. Strictly arg-guarded; a production launch never runs it.
enum FestivalNightSeed {
    static let argument = "-uiTestSeedFestivalNight"

    /// Sentinel Photos identifiers (never resolvable — thumbnails degrade to placeholders, which
    /// is exactly what the simulator can render).
    static let clipAIdentifier = "uitest-festival://clip-a.mov"
    static let clipBIdentifier = "uitest-festival://clip-b.mov"
    static let clipCIdentifier = "uitest-festival://clip-c.mov"

    /// A fixed session id so the seed is idempotent.
    static let sessionID = UUID(uuidString: "FE57171A-DA2C-4E5D-A57E-0FE57171A001")!

    @MainActor
    static func seedIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let sid = sessionID
        let existing = try? context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == sid }))
        guard (existing?.isEmpty ?? true) else { return }

        // The lineup seed (implied by SnappetApp) has already installed the pack — re-derive the
        // SAME now-anchored pack values it used.
        let pack = FestivalLineupSeed.pack()
        guard let day1 = pack.days.first,
              let window = day1.window(utcOffsetSeconds: pack.utcOffsetSeconds) else { return }
        /// Festival-local time on day 1 → absolute Date (window starts at the 06:00 rollover).
        func at(_ hour: Int, _ minute: Int) -> Date {
            window.start.addingTimeInterval(Double((hour - FestivalDay.rolloverHour) * 3600
                                                   + minute * 60))
        }
        func set(_ artist: String) -> FestivalSet? {
            pack.allSets.first { $0.artist == artist }
        }
        guard let neonHarbor = set("Neon Harbor"), let staticBloom = set("Static Bloom") else { return }

        let startedAt = at(14, 15), endedAt = at(17, 45)

        // The finished dance session — festival-owned shape (routineless, all `festival-set`
        // entities), with a curve that peaks 171 mid-Neon-Harbor.
        var neonEntity = SessionExercise(
            exerciseId: "festival-set", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [SetLog(completedAt: at(15, 30), durationSec: 3600)],
            displayName: "\(neonHarbor.artist) · \(neonHarbor.stage)",
            kindRaw: SetKind.duration.rawValue)
        neonEntity.disciplineRaw = WorkoutDiscipline.dance.rawValue
        var bloomEntity = SessionExercise(
            exerciseId: "festival-set", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [SetLog(completedAt: at(16, 40), durationSec: 2400)],
            displayName: "\(staticBloom.artist) · \(staticBloom.stage)",
            kindRaw: SetKind.duration.rawValue)
        bloomEntity.disciplineRaw = WorkoutDiscipline.dance.rawValue

        let session = WorkoutSession(id: sid, routineID: nil, routineName: pack.name,
                                     startedAt: startedAt, exercises: [neonEntity, bloomEntity])
        session.completedAt = endedAt
        session.hrSeries = hrSeries(sessionStart: startedAt,
                                    peakWindows: [
                                        (neonHarbor.start, neonHarbor.end, 171),
                                        (staticBloom.start, staticBloom.end, 155),
                                    ],
                                    duration: endedAt.timeIntervalSince(startedAt))
        session.maxHR = 190
        session.restHR = 55
        context.insert(session)

        // Two closed "I'm here" stretches — the matcher's hints AND the recap's danced time.
        context.insert(FestivalAttendance(packID: pack.id, setID: neonHarbor.id,
                                          artist: neonHarbor.artist, stage: neonHarbor.stage,
                                          sessionID: sid,
                                          startedAt: at(14, 30), endedAt: at(15, 30)))
        context.insert(FestivalAttendance(packID: pack.id, setID: staticBloom.id,
                                          artist: staticBloom.artist, stage: staticBloom.stage,
                                          sessionID: sid,
                                          startedAt: at(16, 0), endedAt: at(16, 40)))

        // The three clips (offsets are capture − session start; the #283 timeline).
        func media(_ identifier: String, capturedAt: Date, duration: Double) -> SessionMedia {
            SessionMedia(sessionID: sid, localIdentifier: identifier, kind: .video,
                         offsetSec: capturedAt.timeIntervalSince(startedAt),
                         durationSec: duration)
        }
        let clips = [
            media(clipAIdentifier, capturedAt: at(14, 45), duration: 18),
            media(clipBIdentifier, capturedAt: at(15, 45), duration: 12),
            media(clipCIdentifier, capturedAt: at(16, 45), duration: 20),
        ]
        clips.forEach { context.insert($0) }

        // Tags via the REAL pure pipeline — exactly what a `FestivalTagSync.refresh` pass writes,
        // minus the Photos edge (sentinels have no library).
        let snapshots = clips.map {
            FestivalTagging.MediaSnapshot(mediaID: $0.id, offsetSec: $0.offsetSec,
                                          durationSec: $0.durationSec, isReel: false)
        }
        let stamps = FestivalTagging.stamps(for: snapshots, sessionStart: startedAt)
        let hints = [
            FestivalSessionHint(setID: neonHarbor.id,
                                interval: DateInterval(start: at(14, 30), end: at(15, 30))),
            FestivalSessionHint(setID: staticBloom.id,
                                interval: DateInterval(start: at(16, 0), end: at(16, 40))),
        ]
        let assignments = FestivalSetMatcher.assignments(for: stamps, in: pack, hints: hints)
        let plan = FestivalTagging.plan(assignments: assignments, existing: [])
        for up in plan.upserts {
            context.insert(FestivalClipTag(packID: pack.id, setID: up.set.id,
                                           artist: up.set.artist, stage: up.set.stage,
                                           mediaID: up.mediaID, sessionID: sid,
                                           confidence: up.confidence, reason: up.reason,
                                           source: .auto))
        }
        try? context.save()
    }

    /// A deterministic curve: ~112 bpm baseline with a sine bump to `peak` inside each window —
    /// so the peak-at-the-drop callout and the recap's ♥ ranking are stable on every run.
    static func hrSeries(sessionStart: Date, peakWindows: [(start: Date, end: Date, peak: Double)],
                         duration: TimeInterval, sampleEverySec: Double = 5) -> [HRPoint] {
        guard duration > 0, sampleEverySec > 0 else { return [] }
        var points: [HRPoint] = []
        var t: Double = 0
        while t <= duration {
            let instant = sessionStart.addingTimeInterval(t)
            var bpm = 112.0
            for window in peakWindows {
                let span = window.end.timeIntervalSince(window.start)
                guard span > 0 else { continue }
                let f = instant.timeIntervalSince(window.start) / span
                if f >= 0, f <= 1 {
                    bpm = max(bpm, 112 + (window.peak - 112) * sin(f * .pi))
                }
            }
            points.append(HRPoint(t: t, bpm: bpm.rounded()))
            t += sampleEverySec
        }
        return points
    }
}
