import XCTest
@testable import Snappet

/// The pure getting-started state machine (festival prompt 07;
/// `docs/ux-research/festival/getting-started/wireframes.html`). Given the two persisted flags plus
/// the three derived counts, it decides the tour / checklist / banner surface, each step's state,
/// the progress, and whether onboarding is finished — every combination, no simulator.
final class FestivalGettingStartedTests: XCTestCase {

    private typealias GS = FestivalGettingStarted
    private typealias Step = FestivalGettingStarted.Step

    private func state(tour: Bool = false, dismissed: Bool = false,
                       lineups: Int = 0, stars: Int = 0, reminders: Bool = false) -> GS {
        GS(tourSeen: tour, checklistDismissed: dismissed,
           lineupCount: lineups, starCount: stars, remindersEnabled: reminders)
    }

    // MARK: - Fresh install

    func testFreshInstallShowsTheTourThenTheFullChecklist() {
        let s = state()   // tour unseen, nothing done
        XCTAssertTrue(s.showTour, "the first open shows the value tour")
        XCTAssertEqual(s.checklist, .full, "with no lineup the checklist replaces the empty state")
        XCTAssertFalse(s.isComplete)
        XCTAssertFalse(s.isFinished)
        XCTAssertEqual(s.completedCount, 0)
        XCTAssertEqual(s.progressFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(s.nextStep, .addLineup)
        XCTAssertEqual(s.state(.addLineup), .activeNext)
        XCTAssertEqual(s.state(.starSets), .locked)
        XCTAssertEqual(s.state(.enableReminders), .locked)
    }

    // MARK: - Tour skipped

    func testTourSkippedKeepsTheFullChecklistButHidesTheTour() {
        let s = state(tour: true)   // tour finished/skipped, still no lineup
        XCTAssertFalse(s.showTour, "once seen, the tour never shows again")
        XCTAssertEqual(s.checklist, .full)
        XCTAssertFalse(s.isFinished)
        XCTAssertEqual(s.nextStep, .addLineup)
    }

    // MARK: - Lineup but no stars → collapse to the banner

    func testLineupInstalledCollapsesToTheBannerWithStarAsNext() {
        let s = state(tour: true, lineups: 1)
        XCTAssertEqual(s.checklist, .banner, "a lineup collapses the checklist to the schedule banner")
        XCTAssertEqual(s.state(.addLineup), .done)
        XCTAssertEqual(s.state(.starSets), .activeNext)
        XCTAssertEqual(s.state(.enableReminders), .locked)
        XCTAssertEqual(s.nextStep, .starSets)
        XCTAssertEqual(s.completedCount, 1)
        XCTAssertEqual(s.progressFraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertFalse(s.isComplete)
    }

    func testStarredButRemindersOffLeavesRemindersAsNext() {
        let s = state(tour: true, lineups: 1, stars: 3)
        XCTAssertEqual(s.state(.addLineup), .done)
        XCTAssertEqual(s.state(.starSets), .done)
        XCTAssertEqual(s.state(.enableReminders), .activeNext)
        XCTAssertEqual(s.nextStep, .enableReminders)
        XCTAssertEqual(s.completedCount, 2)
        XCTAssertEqual(s.checklist, .banner)
    }

    func testStarGoalIsASingleStar() {
        XCTAssertEqual(FestivalGettingStarted.starGoal, 1, "one ★ already builds a plan")
        XCTAssertFalse(state(lineups: 1, stars: 0).isDone(.starSets))
        XCTAssertTrue(state(lineups: 1, stars: 1).isDone(.starSets))
    }

    // MARK: - All done

    func testAllStepsDoneHidesEverything() {
        let s = state(tour: true, lineups: 1, stars: 2, reminders: true)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.completedCount, 3)
        XCTAssertEqual(s.progressFraction, 1.0, accuracy: 0.0001)
        XCTAssertNil(s.nextStep)
        XCTAssertEqual(s.checklist, .hidden, "a complete onboarding shows no checklist or banner")
        XCTAssertFalse(s.showTour, "and never the tour")
        XCTAssertTrue(s.isFinished)
        for step in Step.allCases { XCTAssertEqual(s.state(step), .done) }
    }

    // MARK: - Dismissed early

    func testDismissedEarlyHidesTheChecklistButLeavesStepsIncomplete() {
        let s = state(tour: true, dismissed: true, lineups: 0)
        XCTAssertEqual(s.checklist, .hidden, "'I'll explore on my own' falls through to the plain empty state")
        XCTAssertFalse(s.isComplete)
        XCTAssertTrue(s.isFinished, "dismissed early is finished for surface purposes")
        XCTAssertEqual(s.nextStep, .addLineup, "the underlying steps are still incomplete")
    }

    func testBannerDismissedMidwayHidesTheBanner() {
        let s = state(tour: true, dismissed: true, lineups: 1, stars: 1)
        XCTAssertEqual(s.checklist, .hidden, "tapping the banner's ✕ retires it for good")
        XCTAssertFalse(s.isComplete)
    }

    // MARK: - Re-install after complete stays hidden

    func testReinstallOverFinishedDataNeverShowsOnboardingAgain() {
        // A backup restore / reinstall resets both @AppStorage flags to false, but the restored data
        // makes every step done — so the tour is suppressed and the checklist stays hidden.
        let s = state(tour: false, dismissed: false, lineups: 2, stars: 5, reminders: true)
        XCTAssertTrue(s.isComplete)
        XCTAssertFalse(s.showTour, "an established user with a full plan never re-sees the tour")
        XCTAssertEqual(s.checklist, .hidden)
        XCTAssertTrue(s.isFinished)
    }

    // MARK: - Edge: a later step done before an earlier one is still honest

    func testRemindersOnBeforeALineupMarksStepThreeDoneAndKeepsStepOneActive() {
        // Notification auth can be granted independently of any lineup; the state stays honest.
        let s = state(tour: true, lineups: 0, stars: 0, reminders: true)
        XCTAssertEqual(s.state(.addLineup), .activeNext)
        XCTAssertEqual(s.state(.starSets), .locked)
        XCTAssertEqual(s.state(.enableReminders), .done)
        XCTAssertEqual(s.nextStep, .addLineup)
        XCTAssertEqual(s.completedCount, 1)
        XCTAssertEqual(s.checklist, .full, "no lineup ⇒ still the full checklist")
        XCTAssertFalse(s.isComplete)
    }

    // MARK: - Steps enumerate in wireframe order with stable badge numbers

    func testStepsEnumerateInOrderWithOneBasedBadges() {
        XCTAssertEqual(Step.allCases, [.addLineup, .starSets, .enableReminders])
        XCTAssertEqual(Step.addLineup.rawValue, 1)
        XCTAssertEqual(Step.starSets.rawValue, 2)
        XCTAssertEqual(Step.enableReminders.rawValue, 3)
    }
}
