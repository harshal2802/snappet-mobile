import Foundation

/// Pure onboarding state for the Festival mini-app's guided getting-started (festival prompt 07;
/// `docs/ux-research/festival/getting-started/wireframes.html`). Given plain inputs — two persisted
/// `@AppStorage` flags plus three values DERIVED from existing festival data — it computes the whole
/// surface decision: whether to show the 3-card value tour, the full setup checklist (the empty-state
/// replacement), or the collapsed schedule banner; each step's state (done / active-next / locked);
/// the completed count and progress fraction; and whether onboarding is finished (hide everything).
///
/// No SwiftUI, no SwiftData, no persistence — the festival "pure logic at a thin edge" rule
/// (prompts 01 / 03 / 04). The SwiftUI views are thin renderers over this value, and every
/// combination is unit-tested with no simulator (`FestivalGettingStartedTests`).
struct FestivalGettingStarted: Equatable {

    /// The three guided steps, in order. The raw value doubles as the stable 1-based badge number
    /// the checklist and banner render.
    enum Step: Int, CaseIterable, Equatable {
        case addLineup = 1
        case starSets
        case enableReminders
    }

    /// A step's rendered state: ticked, the live "do this next" row, or greyed until its turn.
    enum StepState: Equatable {
        case done
        case activeNext
        case locked
    }

    /// Which onboarding surface the checklist takes. The tour is decided separately (`showTour`).
    enum Checklist: Equatable {
        /// Replaces the blank "download a lineup" empty state (no lineup installed yet).
        case full
        /// Collapsed nudge (progress ring + next-step + ✕) riding above the day schedule.
        case banner
        /// Dismissed early, or every step complete — the plain empty state / plain schedule.
        case hidden
    }

    /// A single ★ already builds a plan — reminders, clash alerts, and For-You all key off one star
    /// (prompt 04) — so step 2 ticks on the first star. The wireframe copy's "a few" is
    /// encouragement, not a gate: onboarding is never blocking.
    static let starGoal = 1

    // MARK: Inputs (two persisted flags + three derived counts)

    /// `@AppStorage("festival.tourSeen")` — set once the value tour is finished or skipped.
    let tourSeen: Bool
    /// `@AppStorage("festival.gettingStartedDismissed")` — set by "I'll explore on my own" / the
    /// banner's ✕.
    let checklistDismissed: Bool
    /// Derived from the `@Query` of `FestivalLineup`.
    let lineupCount: Int
    /// Derived from the `@Query` of `FestivalStar`.
    let starCount: Int
    /// Derived from prompt 04's notion of reminders-on — notification authorization granted (the
    /// For-You sheet is where it's requested). Not a new stored flag.
    let remindersEnabled: Bool

    init(tourSeen: Bool, checklistDismissed: Bool,
         lineupCount: Int, starCount: Int, remindersEnabled: Bool) {
        self.tourSeen = tourSeen
        self.checklistDismissed = checklistDismissed
        self.lineupCount = lineupCount
        self.starCount = starCount
        self.remindersEnabled = remindersEnabled
    }

    // MARK: Per-step state

    /// Whether a step's real-world condition is met (derived purely from the inputs).
    func isDone(_ step: Step) -> Bool {
        switch step {
        case .addLineup: return lineupCount >= 1
        case .starSets: return starCount >= Self.starGoal
        case .enableReminders: return remindersEnabled
        }
    }

    /// The first step not yet done — the checklist's active row and the banner's nudge target.
    /// `nil` once every step is complete.
    var nextStep: Step? { Step.allCases.first { !isDone($0) } }

    /// A step is `done` when its condition is met, the `activeNext` when it's the first incomplete
    /// step, and `locked` otherwise — so 2–3 unlock as you go (wireframe frame 5).
    func state(_ step: Step) -> StepState {
        if isDone(step) { return .done }
        return step == nextStep ? .activeNext : .locked
    }

    // MARK: Progress

    var completedCount: Int { Step.allCases.filter(isDone).count }
    var progressFraction: Double { Double(completedCount) / Double(Step.allCases.count) }
    var isComplete: Bool { completedCount == Step.allCases.count }

    // MARK: Surface decisions

    /// The 20-second value tour shows once, the first time the module opens — UNLESS onboarding is
    /// already complete (a `SnappetBackup` restore / reinstall over finished data resets the flag but
    /// not the data), so an established user never sees a "getting started" tour again.
    var showTour: Bool { !tourSeen && !isComplete }

    /// Where the checklist lives right now: replacing the empty state, collapsed to the schedule
    /// banner, or gone (dismissed early or every step done).
    var checklist: Checklist {
        if checklistDismissed || isComplete { return .hidden }
        return lineupCount == 0 ? .full : .banner
    }

    /// Nothing left to show anywhere — the tour is done and the checklist is hidden.
    var isFinished: Bool { !showTour && checklist == .hidden }
}
