import XCTest
import SwiftData
@testable import Snappet

/// Progression P4 (prompt 152): the buddy widget's snapshot — the still it picks, the codec, and that
/// the app builds it from the same derivation Home uses.
@MainActor
final class BuddyWidgetSnapshotTests: XCTestCase {

    func testStillNamesCoverEveryStageAndMood() {
        XCTAssertEqual(BuddyWidgetSnapshot.imageName(stage: 3, form: 0.9, paused: false), "buddy-adult-fired")
        XCTAssertEqual(BuddyWidgetSnapshot.imageName(stage: 4, form: 0.5, paused: false), "buddy-legend-steady")
        XCTAssertEqual(BuddyWidgetSnapshot.imageName(stage: 2, form: 0.3, paused: false), "buddy-sprout-tired")
        XCTAssertEqual(BuddyWidgetSnapshot.imageName(stage: 1, form: 0.1, paused: false), "buddy-hatchling-sleepy")
        XCTAssertEqual(BuddyWidgetSnapshot.imageName(stage: 4, form: 0.9, paused: true), "buddy-legend-resting")
        XCTAssertEqual(BuddyWidgetSnapshot.imageName(stage: 9, form: 0.9, paused: false), "buddy-legend-fired", "clamped")
        // The mood bands match the buddy's own moods.
        for f in stride(from: 0.0, through: 1.0, by: 0.05) {
            let mood = BuddyLook(stage: .adult, form: f).mood
            let key = BuddyWidgetSnapshot.moodKey(form: f, paused: false)
            XCTAssertEqual(["Fired up": "fired", "Steady": "steady", "Tired": "tired", "Sleepy": "sleepy"][mood], key, "\(f)")
        }
    }

    func testAnUnhatchedBuddyIsAnEgg() {
        var s = BuddyWidgetSnapshot.placeholder
        s.hatched = false
        XCTAssertEqual(s.imageName, "buddy-egg-fired")
    }

    func testCodecRoundTripsAndRejectsTheFuture() throws {
        let s = BuddyWidgetSnapshot.placeholder
        XCTAssertEqual(BuddyWidgetStore.decode(try BuddyWidgetStore.encode(s)), s)
        var future = s
        future.version = BuddyWidgetSnapshot.currentVersion + 1
        XCTAssertNil(BuddyWidgetStore.decode(try BuddyWidgetStore.encode(future)))
        XCTAssertNil(BuddyWidgetStore.decode(Data("nope".utf8)))
    }

    func testTheAppBuildsItLikeHome() throws {
        let container = try ModelContainer(for: Schema(SnappetSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        RoutineHistorySeed.seed(into: container.mainContext, now: now)
        let sessions = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>())
        let routines = try container.mainContext.fetch(FetchDescriptor<Routine>())
        let w = WidgetSnapshotService.buddySnapshot(sessions: sessions, routines: routines, now: now)
        let home = ProgressionSnapshot.make(sessions: sessions, routines: routines, pauses: [], now: now)
        XCTAssertEqual(w.level, home.level.level)
        XCTAssertEqual(w.stageTitle, home.level.stage.title)
        XCTAssertEqual(w.streakWeeks, home.streak.weeks)
        XCTAssertEqual(w.mood, home.look.mood)
    }
}
