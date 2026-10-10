import XCTest
import HealthKit
@testable import Snappet

/// Prompt 170 — every post knows the ACTIVITY it was, so the activity chips are right: a Quick Session
/// climb and a climbing workout imported from Health are Climbing (the Climbs chip used to match Kilter
/// board sessions only), hangboard is Strength (user's call), a festival night is Festival.
final class ClipActivityTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func video(_ offset: Double, exercise: UUID? = nil, climb: String? = nil) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: 6, exerciseId: exercise,
                   setIndex: exercise == nil ? nil : 0, climbUUID: climb, localIdentifier: "a\(offset)-\(UUID())")
    }

    private func gym(_ title: String) -> ClipFeedSessionMeta {
        ClipFeedSessionMeta(id: UUID(), kind: .gym, title: title, startedAt: start)
    }

    // MARK: rules

    func testExerciseDisciplines() {
        XCTAssertEqual(ClipActivity.forExercise(.climb), .climbing)
        XCTAssertEqual(ClipActivity.forExercise(.strength), .strength)
        XCTAssertEqual(ClipActivity.forExercise(.timed), .strength)       // hangboard / holds / core
        XCTAssertEqual(ClipActivity.forExercise(.run), .cardio)
        XCTAssertEqual(ClipActivity.forExercise(.dance), .dance)
        XCTAssertEqual(ClipActivity.forExercise(.other), .general)
    }

    /// Drift guard: every label the importer can write (`HealthKitService.label`) maps to a real activity —
    /// only the generic "Workout" fallback is Other.
    func testEveryImportLabelMapsToAnActivity() {
        let types: [HKWorkoutActivityType] = [
            .running, .walking, .hiking, .cycling, .climbing, .swimming, .rowing, .elliptical,
            .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining,
            .highIntensityIntervalTraining, .yoga, .pilates, .cardioDance, .socialDance, .barre,
            .cooldown, .flexibility, .mixedCardio, .kickboxing, .boxing, .jumpRope, .stairs, .stepTraining,
        ]
        for t in types {
            let label = HealthKitService.label(t)
            XCTAssertNotEqual(ClipActivity.forImportLabel(label), .general, "\(label) has no activity")
        }
        XCTAssertEqual(ClipActivity.forImportLabel(HealthKitService.label(.climbing)), .climbing)
        XCTAssertEqual(ClipActivity.forImportLabel("Workout"), .general)
    }

    func testDominantPicksTheMostCommonThenChipOrder() {
        XCTAssertEqual(ClipActivity.dominant([.cardio, .strength, .strength]), .strength)
        XCTAssertEqual(ClipActivity.dominant([.cardio, .climbing]), .climbing)   // tie → chip order
        XCTAssertEqual(ClipActivity.dominant([]), .general)
    }

    // MARK: composer

    /// The user's bug: these three are all climbing, and only the Kilter one used to match "Climbs".
    func testClimbingFromBoardQuickSessionAndHealthImport() {
        let kilter = ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "Board", startedAt: start, angle: 40)
        let climbEx = UUID(), benchEx = UUID()
        let quick = gym("Bouldering")
        let imported = gym("Climbing")
        let posts = ClipFeedComposer.posts(
            sessions: [
                .init(meta: kilter, clips: [video(1, climb: "crux")]),
                .init(meta: quick, clips: [video(2, exercise: climbEx), video(3, exercise: benchEx)],
                      exerciseActivity: [climbEx.uuidString: .climbing, benchEx.uuidString: .strength],
                      sessionActivity: .climbing),
                .init(meta: imported, clips: [video(4)], sessionActivity: ClipActivity.forImportLabel("Climbing")),
            ],
            climbMeta: [:], exerciseName: { $0 == climbEx ? "Yellow V3" : "Bench" })
        func activity(_ title: String) -> ClipFeedPost.Discipline? { posts.first { $0.title == title }?.discipline }
        XCTAssertEqual(activity("crux") ?? posts.first { $0.kind == .kilter }?.discipline, .climbing)
        XCTAssertEqual(activity("Yellow V3"), .climbing)
        XCTAssertEqual(activity("Bench"), .strength)                       // a mixed session keeps per-exercise truth
        XCTAssertEqual(posts.first { $0.sessionID == imported.id }?.discipline, .climbing)

        var f = ClipFeedFilter(); f.activity = .climbing
        XCTAssertEqual(f.apply(posts, isFavorite: { _ in false }).count, 3, "board + Quick Session + import")
        f.activity = .strength
        XCTAssertEqual(f.apply(posts, isFavorite: { _ in false }).map(\.title), ["Bench"])
    }

    func testFestivalNightUntaggedClipsAndReelsAreFestival() {
        let night = gym("Lost Lands 2026")
        var reel = video(9); reel.reelTitle = "Lost Lands — Highlights"
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: night, clips: [video(1), reel], sessionActivity: .festival)],
            climbMeta: [:], exerciseName: { _ in "?" })
        XCTAssertEqual(Set(posts.map(\.discipline)), [.festival])
        XCTAssertEqual(Set(posts.map(\.sessionActivity)), [.festival])
    }

    func testChipsShowOnlyActivitiesPresentInChipOrder() {
        let posts = ClipFeedComposer.posts(
            sessions: [.init(meta: gym("Run"), clips: [video(1)], sessionActivity: .cardio),
                       .init(meta: ClipFeedSessionMeta(id: UUID(), kind: .kilter, title: "B", startedAt: start),
                             clips: [video(2)])],
            climbMeta: [:], exerciseName: { _ in "?" })
        XCTAssertEqual(ClipActivity.present(in: posts), [.climbing, .cardio])
    }
}
