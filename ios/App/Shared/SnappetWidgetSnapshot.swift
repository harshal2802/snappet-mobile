import Foundation

/// The read-only **Today** snapshot the home-screen widgets render (#81 Phase 1).
///
/// We deliberately do NOT let the widget query SwiftData. The app builds this small, versioned
/// value from the same rows the Home/Habit screens use (`WidgetSnapshotBuilder`, reusing
/// `TodayDigest` + `HabitMilestones.streak`), writes it to the App-Group container
/// (`WidgetSnapshotStore`), and nudges WidgetKit to reload. The widget reads only this — so it is
/// completely isolated from the frequently-bumped `SnappetSchema`, needs no store-location
/// migration, and has no cross-process SQLite locking. See `decisions.md` (2026-06-15).
///
/// Compiled into BOTH the app and the `SnappetWidgets` extension via the `Shared/` source path, so
/// producer and renderer share one contract (the `PomodoroActivityAttributes` pattern).
struct SnappetWidgetSnapshot: Codable, Sendable, Equatable {
    /// The contract version this binary writes/understands. Bump only on an INCOMPATIBLE change;
    /// additive fields stay readable by older binaries via the defaulting decoder below. A reader
    /// rejects a snapshot whose `version` is higher than `currentVersion` (it can't be trusted).
    static let currentVersion = 1

    var version: Int
    /// When the app built this snapshot — lets the widget show honest "as of" staleness if needed.
    var generatedAt: Date
    /// Start-of-day the "today" facts were computed for. The widget compares this to its own
    /// `Calendar.startOfDay(for: .now)`; a snapshot built before midnight is stale → the widget can
    /// render a neutral state instead of yesterday's "all done".
    var dayStart: Date

    /// One habit as the widget needs it: stable id (for the Phase-2 check-off intent), label, glyph,
    /// and whether it's already checked off for `dayStart`.
    struct HabitItem: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var symbol: String
        var doneToday: Bool

        init(id: UUID, name: String, symbol: String, doneToday: Bool) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.doneToday = doneToday
        }

        // Defaulting decode: a snapshot written by an older app build that lacks a field must not
        // crash the widget (the repo's migration-safe Codable discipline, OverlayItem precedent).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "checkmark.circle"
            doneToday = try c.decodeIfPresent(Bool.self, forKey: .doneToday) ?? false
        }
    }

    var habits: [HabitItem]
    /// The suite-engagement "day streak" the Home dashboard shows: consecutive days ending today
    /// with at least one logged action. Built via `TodayDigest.activityStreak` — the same derivation
    /// `HomeDashboardView` reads — so the widget and Home can't show different numbers. 0 when today
    /// has no activity (the strict "ending today" rule).
    var dayStreak: Int
    /// Completed focus minutes today (`TodayDigest.focusToday`). 0 when none yet.
    var focusMinutesToday: Int

    /// Habits not yet checked off today — the widget's headline number.
    var habitsRemaining: Int { habits.lazy.filter { !$0.doneToday }.count }
    var habitsTotal: Int { habits.count }
    var allHabitsDone: Bool { !habits.isEmpty && habitsRemaining == 0 }

    init(version: Int = SnappetWidgetSnapshot.currentVersion,
         generatedAt: Date, dayStart: Date,
         habits: [HabitItem], dayStreak: Int, focusMinutesToday: Int) {
        self.version = version
        self.generatedAt = generatedAt
        self.dayStart = dayStart
        self.habits = habits
        self.dayStreak = dayStreak
        self.focusMinutesToday = focusMinutesToday
    }

    // Defaulting decode (see HabitItem) — tolerant of older writers' missing keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? SnappetWidgetSnapshot.currentVersion
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        dayStart = try c.decodeIfPresent(Date.self, forKey: .dayStart) ?? .distantPast
        habits = try c.decodeIfPresent([HabitItem].self, forKey: .habits) ?? []
        dayStreak = try c.decodeIfPresent(Int.self, forKey: .dayStreak) ?? 0
        focusMinutesToday = try c.decodeIfPresent(Int.self, forKey: .focusMinutesToday) ?? 0
    }

    /// An empty "no data yet" snapshot — what a fresh widget shows before the app has ever written one.
    static func empty(now: Date = Date(), calendar: Calendar = .current) -> SnappetWidgetSnapshot {
        SnappetWidgetSnapshot(generatedAt: now, dayStart: calendar.startOfDay(for: now),
                              habits: [], dayStreak: 0, focusMinutesToday: 0)
    }
}
