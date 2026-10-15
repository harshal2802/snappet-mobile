import XCTest
@testable import Snappet

/// Unit tests for the **pure** `ActivityMediaIndex` cross-session join (activity progress P1, prompt 178)
/// — no SwiftData container, no Photos, no view.
final class ActivityMediaIndexTests: XCTestCase {

    // MARK: - Builders

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func set(_ reps: Int, _ kg: Double) -> SetLog {
        SetLog(actualReps: reps, actualWeight: kg, weightUnit: .kg, completedAt: t0)
    }

    private func bench(_ sets: [SetLog]) -> SessionExercise {
        SessionExercise(exerciseId: "bench", targetSets: sets.count, targetReps: "", targetRestSeconds: 0, sets: sets)
    }

    private func climb(_ name: String?, grade: String = "V5", statuses: [KilterAscentStatus]) -> SessionExercise {
        var ex = SessionExercise(exerciseId: "adhoc-\(SetKind.climbAttempt.rawValue)", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0,
                                 sets: statuses.map { SetLog(completedAt: t0, climbGradeLabel: grade, climbStatusRaw: $0.rawValue) },
                                 displayName: name, kindRaw: SetKind.climbAttempt.rawValue)
        ex.climbGradeLabel = grade
        return ex
    }

    private func session(_ exercises: [SessionExercise], daysAgo: Double, name: String = "Push Day",
                         hr: [HRPoint] = []) -> WorkoutSession {
        let start = t0.addingTimeInterval(-daysAgo * 86_400)
        return WorkoutSession(routineName: name, startedAt: start, completedAt: start.addingTimeInterval(3600),
                              exercises: exercises, hrSeries: hr)
    }

    private func clip(_ s: WorkoutSession, _ ex: SessionExercise?, set: Int? = nil, at offset: Double = 30,
                      kind: String = "video", duration: Double? = 10, reel: Bool = false) -> ActivityMediaInput {
        ActivityMediaInput(id: UUID(), sessionID: s.id, assignedExerciseID: ex?.id, assignedSetIndex: set,
                           kindRaw: kind, offsetSec: offset, durationSec: duration,
                           localIdentifier: UUID().uuidString, isReel: reel)
    }

    private let benchKey = ActivityKey(exerciseId: "bench", nameKey: "")

    // MARK: - Identity

    func testCatalogExerciseKeyIgnoresDisplayName() {
        var ex = bench([])
        ex.displayName = "My bench"
        XCTAssertEqual(ActivityKey.plain(ex), benchKey)
    }

    private func timed(_ name: String?) -> SessionExercise {
        SessionExercise(exerciseId: "adhoc-duration", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                        sets: [], displayName: name, kindRaw: SetKind.duration.rawValue)
    }

    func testAdhocKeyNormalizesName() {
        XCTAssertEqual(ActivityKey.plain(timed("  Max   Hangs ")), ActivityKey.plain(timed("max hangs")))
    }

    func testUnnamedAdhocHasNoIdentity() {
        XCTAssertNil(ActivityKey.plain(timed(nil)))
        XCTAssertNil(ActivityKey.plain(timed("   ")))
        XCTAssertNil(ActivityKey.plain(climb("Blue crimp", statuses: [])), "climbs only get keys from ActivityIdentity")
        XCTAssertNil(ActivityIdentity(sessions: []).key(for: climb(nil, statuses: [])), "a bare climb has no identity")
    }

    // MARK: - Grouping

    func testGroupsAcrossSessionsNewestFirstWithSetStamps() {
        let oldBench = bench([set(8, 50)])
        let old = session([oldBench], daysAgo: 30)
        let newBench = bench([set(8, 70), set(8, 75)])
        let new = session([newBench], daysAgo: 1)
        let media = [clip(old, oldBench, set: 0), clip(new, newBench, set: 1, at: 90), clip(new, newBench, set: 0, at: 20)]

        let groups = ActivityMediaIndex.groups(for: benchKey, history: [old, new], media: media,
                                               unit: .kg, distanceUnit: .km)
        XCTAssertEqual(groups.map(\.sessionID), [new.id, old.id])
        XCTAssertEqual(groups[0].clips.map(\.setIndex), [0, 1], "capture order inside a session")
        XCTAssertEqual(groups[0].clips.map(\.setSummary), ["70 kg × 8", "75 kg × 8"])
        XCTAssertEqual(groups[1].clips.first?.setSummary, "50 kg × 8")
    }

    func testExcludesLiveSessionReelsAndOtherExercises() {
        let b = bench([set(8, 60)])
        var squat = bench([set(5, 100)])
        squat.exerciseId = "squat"
        let past = session([b, squat], daysAgo: 3)
        let live = session([b], daysAgo: 0)
        let media = [clip(past, b, set: 0), clip(past, squat, set: 0), clip(past, b, reel: true), clip(live, b, set: 0)]

        let groups = ActivityMediaIndex.groups(for: benchKey, history: [past, live], media: media,
                                               excludingSession: live.id, unit: .kg, distanceUnit: .km)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].clips.count, 1)
        XCTAssertEqual(ActivityMediaIndex.counts(history: [past, live], media: media, excludingSession: live.id)[benchKey], 1)
    }

    func testExerciseLevelClipHasNoSetStampAndStaleIndexIsTolerated() {
        let b = bench([set(8, 60)])
        let s = session([b], daysAgo: 2)
        let groups = ActivityMediaIndex.groups(for: benchKey, history: [s],
                                               media: [clip(s, b, set: nil), clip(s, b, set: 7, at: 40)],
                                               unit: .kg, distanceUnit: .km)
        XCTAssertEqual(groups[0].clips.map(\.setSummary), [nil, nil])
        XCTAssertEqual(groups[0].clips.map(\.setIndex), [nil, nil])
    }

    func testNamedClimbMatchesAcrossSessionsWithGradeStamp() {
        let first = climb("Blue crimp", statuses: [.attempt])
        let s1 = session([first], daysAgo: 10, name: "Bouldering")
        let send = climb("blue crimp", statuses: [.attempt, .sent])
        let other = climb("Red slab", statuses: [.flash])
        let s2 = session([send, other], daysAgo: 1, name: "Bouldering")
        let media = [clip(s1, first, set: 0), clip(s2, send, set: 1), clip(s2, other, set: 0)]

        let key = ActivityIdentity(sessions: [s1, s2]).key(for: first)!
        let groups = ActivityMediaIndex.groups(for: key, history: [s1, s2], media: media, unit: .kg, distanceUnit: .km)
        XCTAssertEqual(groups.flatMap(\.clips).count, 2)
        XCTAssertEqual(groups[0].clips[0].setSummary, "V5 · Sent")
    }

    // MARK: - Untagged + HR

    func testUntaggedCountOnlyInSessionsWithTheActivity() {
        let b = bench([set(8, 60)])
        let withBench = session([b], daysAgo: 2)
        let without = session([climb("x", statuses: [])], daysAgo: 1)
        let media = [clip(withBench, nil), clip(withBench, nil), clip(without, nil), clip(withBench, nil, reel: true)]
        XCTAssertEqual(ActivityMediaIndex.untaggedCount(for: benchKey, history: [withBench, without], media: media), 2)
    }

    func testAverageBPMOverVideoWindowAndAroundPhoto() {
        let hr = [HRPoint(t: 5, bpm: 100), HRPoint(t: 30, bpm: 140), HRPoint(t: 35, bpm: 150), HRPoint(t: 60, bpm: 90)]
        let s = session([], daysAgo: 0)
        XCTAssertEqual(ActivityMediaIndex.averageBPM(for: clip(s, nil, at: 30, duration: 10), hrSeries: hr), 145)
        XCTAssertEqual(ActivityMediaIndex.averageBPM(for: clip(s, nil, at: 12, kind: "photo", duration: nil), hrSeries: hr), 100)
        XCTAssertNil(ActivityMediaIndex.averageBPM(for: clip(s, nil, at: 200), hrSeries: hr))
    }
}
