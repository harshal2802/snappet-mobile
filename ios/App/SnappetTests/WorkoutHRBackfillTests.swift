import XCTest
@testable import Snappet

/// Unit tests for the **pure** Apple Health HR back-fill decision (prompt 203) plus the racket edges of the
/// session detail's set editing and per-set display. No device.
final class WorkoutHRBackfillTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(endedAgo: Double = 3600, source: String? = nil, imported: Bool = false,
                           series: [HRPoint] = [], active: Bool = false) -> WorkoutHRBackfill.Candidate {
        let end = now.addingTimeInterval(-endedAgo)
        return .init(startedAt: end.addingTimeInterval(-3600), completedAt: active ? nil : end,
                     metricsSourceRaw: source, isImportedFromHealth: imported, hrSeries: series)
    }

    func testWantsPhoneOnlyAndSparseWatchSessions() {
        XCTAssertTrue(WorkoutHRBackfill.wants(candidate(), now: now))                       // no HR at all (Fitbit user)
        let sparse = stride(from: 0.0, to: 3600, by: 15).map { HRPoint(t: $0, bpm: 120) }   // watch relay ~1/15 s
        XCTAssertTrue(WorkoutHRBackfill.wants(candidate(source: "appleWatch", series: sparse), now: now))
    }

    func testSkips() {
        let dense = stride(from: 0.0, to: 600, by: 1).map { HRPoint(t: $0, bpm: 120) }
        XCTAssertFalse(WorkoutHRBackfill.wants(candidate(series: dense), now: now))          // already dense
        XCTAssertFalse(WorkoutHRBackfill.wants(candidate(source: "ble"), now: now))          // BLE carries RR
        XCTAssertFalse(WorkoutHRBackfill.wants(candidate(imported: true), now: now))         // importer read it
        XCTAssertFalse(WorkoutHRBackfill.wants(candidate(active: true), now: now))           // still running
        XCTAssertFalse(WorkoutHRBackfill.wants(candidate(endedAgo: 4 * 86_400), now: now))   // too old
    }

    func testMergeOnlyWhenHealthAddsSamples() {
        let health = [HRPoint(t: 0, bpm: 100), HRPoint(t: 5, bpm: 110)]
        XCTAssertEqual(WorkoutHRBackfill.merged(stored: [], health: health), health)
        XCTAssertNil(WorkoutHRBackfill.merged(stored: health, health: []))
        XCTAssertNil(WorkoutHRBackfill.merged(stored: health, health: [HRPoint(t: 1, bpm: 99)]))
    }

    // MARK: - Racket set editing / display

    private func matchUnit(_ a: Int, _ b: Int) -> SetLog {
        var s = SetLog(completedAt: now); s.scoreFor = a; s.scoreAgainst = b
        return s
    }

    func testEditingAMatchScore() {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: [matchUnit(11, 9)], kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        let key = SessionSetEditing.Key(exerciseID: ex.id, setIndex: 0)
        var drafts = SessionSetEditing.drafts(for: [ex], unit: .kg)
        XCTAssertEqual(drafts[key]?.scoreFor, "11")
        XCTAssertEqual(drafts[key]?.scoreAgainst, "9")
        drafts[key]?.scoreAgainst = "13"
        drafts[key]?.scoreFor = "11"
        let out = SessionSetEditing.apply(drafts: drafts, to: [ex], unit: .kg)
        XCTAssertEqual(out[0].sets[0].scoreAgainst, 13)
        XCTAssertEqual(out[0].racketState.lost, 1)                 // the result re-derives from the edit
    }

    func testDisplaySummaryForRacketSets() {
        XCTAssertEqual(SetMeasure.displaySummary(matchUnit(12, 10), discipline: .racket, kind: .duration,
                                                 unit: .kg, distanceUnit: .km), "12–10")
        var block = SetLog(completedAt: now, durationSec: 180); block.drillMade = 38; block.drillTried = 50
        XCTAssertEqual(SetMeasure.displaySummary(block, discipline: .racket, kind: .duration,
                                                 unit: .kg, distanceUnit: .km), "38/50 76% 3:00")
    }

    func testClipPostStatsForAMatch() {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: [matchUnit(11, 7), matchUnit(11, 8), matchUnit(11, 2)],
                                 displayName: "Table tennis match", kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketEvent = "City Open"
        let st = ClipPostStats.make(ex, title: RacketStats.postTitle(ex), key: nil, priorBestKg: nil, unit: .kg)!
        XCTAssertEqual(st.line, "City Open · Table tennis · 11–7  11–8  11–2")
        XCTAssertEqual(st.effortNoun, "Game")
        XCTAssertEqual(st.setDetail[1], "11–8")
        XCTAssertEqual(st.activityTitle, "Table tennis match")
    }
}
