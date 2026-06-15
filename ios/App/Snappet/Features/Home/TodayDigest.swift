import Foundation

/// Pure derivations behind the Home tab's actionable **Today** section (#71). Each function turns
/// the same SwiftData rows the modules themselves query into one card's worth of facts — or `nil`
/// when the underlying data doesn't exist yet, which is exactly the card's render gate ("cards
/// render only when their data exists"). No SwiftUI, no SwiftData fetches, no clock/calendar reads
/// (callers pass `now` + `calendar`), so everything here is deterministic and unit-tested in
/// `SnappetTests` (`TodayDigestTests`) with no device.
enum TodayDigest {

    // MARK: - Habits

    struct HabitsToday: Equatable {
        var remaining: Int
        var total: Int
        var allDone: Bool { remaining == 0 }
    }

    /// Habits not yet checked off today. `nil` when the user has no habits (card hidden).
    /// Mirrors `HabitRootView.isDoneToday`: a completion counts when its `day` normalizes to
    /// today's start-of-day (normalized here too, defensively — the rows are stored normalized).
    static func habitsToday(habits: [Habit], completions: [HabitCompletion],
                            now: Date, calendar: Calendar) -> HabitsToday? {
        guard !habits.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        let doneToday = Set(completions.lazy
            .filter { calendar.startOfDay(for: $0.day) == today }
            .map(\.habitID))
        let remaining = habits.filter { !doneToday.contains($0.id) }.count
        return HabitsToday(remaining: remaining, total: habits.count)
    }

    // MARK: - Resume workout

    struct ResumeWorkout: Equatable {
        var sessionID: UUID
        var routineName: String
        var startedAt: Date
    }

    /// The open workout to resume — a session with `completedAt == nil`. The store invariant is
    /// "at most one active", but defend against drift: the most recently started wins, with a
    /// stable id tie-break. `nil` when nothing is in flight.
    static func resumeWorkout(sessions: [WorkoutSession]) -> ResumeWorkout? {
        let pick = sessions.lazy
            .filter { $0.completedAt == nil }
            .max { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        guard let pick else { return nil }
        return ResumeWorkout(sessionID: pick.id, routineName: pick.routineName,
                             startedAt: pick.startedAt)
    }

    // MARK: - Focus

    struct FocusToday: Equatable {
        var minutesToday: Int
        var blocksToday: Int
    }

    /// Completed focus minutes today. `nil` while the Pomodoro app has never logged a block —
    /// an unused module shouldn't advertise on Home; once it's in use, a 0-minute day still
    /// renders (that's the "start focus" nudge).
    static func focusToday(sessions: [PomodoroSession],
                           now: Date, calendar: Calendar) -> FocusToday? {
        guard !sessions.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        let todays = sessions.filter { calendar.startOfDay(for: $0.completedAt) == today }
        return FocusToday(minutesToday: todays.reduce(0) { $0 + $1.minutes },
                          blocksToday: todays.count)
    }

    // MARK: - Budget pace

    struct BudgetPace: Equatable {
        /// Month-to-date spend across live categories.
        var spent: Double
        /// Sum of every category's monthly limit.
        var monthlyBudget: Double
        /// The budget prorated to `now` — what on-pace spending would total by today.
        var expectedByNow: Double
        var onPace: Bool { spent <= expectedByNow }
    }

    /// Month-to-date spend vs the prorated total budget. `nil` until at least one category has a
    /// positive monthly limit (card hidden). Orphaned transactions (whose category was deleted)
    /// don't count, matching the Budget screens; `MonthScope` defines "this month" so the card and
    /// the module can't disagree about month boundaries.
    static func budgetPace(categories: [BudgetCategory], transactions: [BudgetTransaction],
                           now: Date, calendar: Calendar) -> BudgetPace? {
        let budget = categories.reduce(0.0) { $0 + max(0, $1.monthlyLimit) }
        guard budget > 0 else { return nil }
        let month = MonthScope(anchor: now, calendar: calendar)
        let liveIDs = Set(categories.map(\.id))
        let spent = transactions
            .filter { liveIDs.contains($0.categoryID) && month.contains($0.date) }
            .reduce(0.0) { $0 + $1.amount }
        let span = month.end.timeIntervalSince(month.start)
        let elapsed = span > 0 ? min(max(now.timeIntervalSince(month.start) / span, 0), 1) : 1
        return BudgetPace(spent: spent, monthlyBudget: budget, expectedByNow: budget * elapsed)
    }

    // MARK: - Kilter plan

    struct ClimbPlan: Equatable {
        var loggedClimbs: Int
        /// Human label for the detected working grade — `nil` on a cold start (no sends yet).
        var workingGradeLabel: String?
    }

    /// The "Plan tonight's session" hook. `nil` until the user has logged at least one climb;
    /// the working grade comes from the pure `KilterRecommender`, so this card and
    /// `KilterPlanView` can't disagree about what grade the plan anchors on.
    static func climbPlan(history: [KilterClimbLog], sendThreshold: Int = 2) -> ClimbPlan? {
        guard !history.isEmpty else { return nil }
        guard let working = KilterRecommender.workingDifficulty(history: history,
                                                                sendThreshold: sendThreshold)
        else { return ClimbPlan(loggedClimbs: history.count, workingGradeLabel: nil) }
        // Label the bucket from the user's own logs (sends first — the working grade is, by
        // construction, a grade they've sent, so this practically always resolves).
        let bucket = Int(working.rounded())
        let label = history.first {
            $0.isSend && Int($0.difficulty.rounded()) == bucket && !$0.gradeLabel.isEmpty
        }?.gradeLabel ?? history.first {
            Int($0.difficulty.rounded()) == bucket && !$0.gradeLabel.isEmpty
        }?.gradeLabel
        return ClimbPlan(loggedClimbs: history.count, workingGradeLabel: label)
    }

    // MARK: - Activity streak

    /// Consecutive days **ending today** with at least one logged action — the suite-engagement
    /// "day streak" the Home dashboard's `StatTile` shows. Counts strictly back from today: a day
    /// with no `UsageRecord` ends it (so today with none ⇒ 0; it does NOT stay alive until a full
    /// day is missed, unlike per-habit `HabitMilestones.streak`). Both `HomeDashboardView.streakText`
    /// and the home-screen widget snapshot (#81) read this, so the number can't diverge between them.
    static func activityStreak(records: [UsageRecord], now: Date, calendar: Calendar) -> Int {
        let days = Set(records.map { calendar.startOfDay(for: $0.timestamp) })
        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
