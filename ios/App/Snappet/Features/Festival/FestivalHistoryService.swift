import Foundation
import SwiftData

/// The thin SwiftData edge that feeds the pure `FestivalHRHistory` (festival prompt 04). Reads your
/// `FestivalAttendance` stretches (prompt 02) across EVERY installed lineup, slices each stretch's HR
/// out of the dance `WorkoutSession` it rode, and hands the recommender plain value `Sample`s. All
/// the aggregation/affinity math lives in `FestivalHRHistory` — this only fetches and adapts, so the
/// ranking stays testable without a store.
///
/// Cross-festival by design: an artist you danced hard to at one festival informs a suggestion at
/// another (keyed by normalized artist name). Re-derives per-artist HR from prompt-02 data rather
/// than depending on prompt 03's `FestivalSetStats`.
@MainActor
enum FestivalHistoryService {

    /// Your per-artist HR affinity from all logged attendance. `now` clamps a still-open stretch.
    static func history(context: ModelContext, now: Date = .now) -> FestivalHRHistory {
        let attendance = (try? context.fetch(FetchDescriptor<FestivalAttendance>())) ?? []
        let lineups = (try? context.fetch(FetchDescriptor<FestivalLineup>())) ?? []
        let nameByPack = Dictionary(lineups.map { ($0.packID, $0.name) },
                                    uniquingKeysWith: { a, _ in a })

        var samples: [FestivalHRHistory.Sample] = []
        for a in attendance {
            let end = a.endedAt ?? now
            guard end > a.startedAt, let session = session(id: a.sessionID, in: context) else { continue }
            let points = session.hrSeries.map { (t: $0.t, bpm: $0.bpm) }
            let window = DateInterval(start: a.startedAt, end: end)
            let festival = nameByPack[a.packID] ?? "a past festival"
            if let sample = FestivalHRHistory.sample(artist: a.artist, festivalName: festival,
                                                     window: window, sessionStart: session.startedAt,
                                                     hrPoints: points) {
                samples.append(sample)
            }
        }
        return FestivalHRHistory(samples: samples)
    }

    private static func session(id: UUID, in context: ModelContext) -> WorkoutSession? {
        (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.id == id })))?.first
    }
}
