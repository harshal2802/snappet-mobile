import Foundation

// MARK: - Versioned backup bundle

/// The root of a portable Snappet backup. Contains plain Codable snapshots of every
/// `@Model` type that can meaningfully move between devices.
///
/// **Excluded**: `SessionMedia`, `ClipEdit`, and `StudioProject` — they embed
/// `PHAsset.localIdentifier` values that are device-local and cannot round-trip.
struct SnappetBackupBundle: Codable, Sendable {
    /// Incremented when the shape of any snapshot type changes in a breaking way.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    // Core
    let usageRecords: [UsageRecordSnapshot]
    // Pomodoro
    let pomodoroSessions: [PomodoroSessionSnapshot]
    // Habits
    let habits: [HabitSnapshot]
    let habitCompletions: [HabitCompletionSnapshot]
    // Journal
    let journalEntries: [JournalEntrySnapshot]
    // Expenses
    let expenseGroups: [ExpenseGroupSnapshot]
    let expenseRecords: [ExpenseRecordSnapshot]
    // Budget
    let budgetCategories: [BudgetCategorySnapshot]
    let budgetTransactions: [BudgetTransactionSnapshot]
    // Workout Tracker
    let routines: [RoutineSnapshot]
    let workoutSessions: [WorkoutSessionSnapshot]
    let customExercises: [CustomExerciseSnapshot]
    // Tip
    let tipCalculations: [TipCalculationSnapshot]
    // Kilter
    let kilterLogEntries: [KilterLogEntrySnapshot]
    let kilterSessions: [KilterSessionSnapshot]
    let kilterFavorites: [KilterFavoriteSnapshot]
    let kilterCreatedClimbs: [KilterCreatedClimbSnapshot]

    var totalRecordCount: Int {
        usageRecords.count + pomodoroSessions.count + habits.count + habitCompletions.count +
        journalEntries.count + expenseGroups.count + expenseRecords.count +
        budgetCategories.count + budgetTransactions.count + routines.count +
        workoutSessions.count + customExercises.count + tipCalculations.count +
        kilterLogEntries.count + kilterSessions.count + kilterFavorites.count +
        kilterCreatedClimbs.count
    }
}

// MARK: - Snapshot value types (one per @Model)

struct UsageRecordSnapshot: Codable, Sendable {
    var module: String
    var action: String
    var summary: String
    var metric: Double?
    var timestamp: Date
}

struct PomodoroSessionSnapshot: Codable, Sendable {
    var minutes: Int
    var completedAt: Date
}

struct HabitSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var createdAt: Date
}

struct HabitCompletionSnapshot: Codable, Sendable {
    var habitID: UUID
    var day: Date
}

struct JournalEntrySnapshot: Codable, Sendable {
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
}

struct ExpenseGroupSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var participants: [String]
    var createdAt: Date
}

struct ExpenseRecordSnapshot: Codable, Sendable {
    var groupID: UUID
    var title: String
    var amount: Double
    var payer: String
    var participants: [String]
    var date: Date
    var isSettlement: Bool
    var items: [ReceiptItemSnapshot]
    var taxAmount: Double
    var discountAmount: Double
}

struct ReceiptItemSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var price: Double
    var assignees: [String]
}

struct BudgetCategorySnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var monthlyLimit: Double
    var createdAt: Date
}

struct BudgetTransactionSnapshot: Codable, Sendable {
    var categoryID: UUID
    var amount: Double
    var note: String
    var date: Date
}

struct RoutineSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var exercises: [RoutineExerciseSnapshot]
    var createdAt: Date
    var updatedAt: Date
    var isStarter: Bool
    var starterKey: String?
    var sportRaw: String?
    var levelRaw: String?
    var tags: [String]
    var detail: String?
    var sourceLabel: String?
    var sourceURL: String?
}

struct RoutineExerciseSnapshot: Codable, Sendable {
    var id: UUID
    var exerciseId: String
    var sets: Int
    var reps: String
    var restSeconds: Int
    var weight: Double?
    var weightUnit: String?
    var notes: String?
    var displayName: String?
}

struct WorkoutSessionSnapshot: Codable, Sendable {
    var id: UUID
    var routineID: UUID?
    var routineName: String
    var startedAt: Date
    var completedAt: Date?
    var exercises: [SessionExerciseSnapshot]
    var hrSeries: [HRPointSnapshot]
    var maxHR: Double?
    var restHR: Double?
    var metricsSourceRaw: String?
    var kcalEstimate: Double?
}

struct SessionExerciseSnapshot: Codable, Sendable {
    var id: UUID
    var exerciseId: String
    var targetSets: Int
    var targetReps: String
    var targetRestSeconds: Int
    var targetWeight: Double?
    var targetWeightUnit: String?
    var sets: [SetLogSnapshot]
    var skipped: Bool
    var displayName: String?
    var kindRaw: String?
}

struct SetLogSnapshot: Codable, Sendable {
    var actualReps: Int?
    var actualWeight: Double?
    var weightUnit: String?
    var completedAt: Date?
    var durationSec: Double?
    var climbGradeLabel: String?
    var climbStatusRaw: String?
    var climbAttempts: Int?
}

struct HRPointSnapshot: Codable, Sendable {
    var t: Double
    var bpm: Double
    var rrIntervalsMs: [Double]?
}

struct CustomExerciseSnapshot: Codable, Sendable {
    var id: String
    var name: String
    var categoryRaw: String
    var levelRaw: String
    var forceRaw: String?
    var mechanicRaw: String?
    var equipmentRaw: String?
    var primaryMuscles: [String]
    var secondaryMuscles: [String]
    var instructions: [String]
    var createdAt: Date
}

struct TipCalculationSnapshot: Codable, Sendable {
    var bill: Double
    var tipPct: Double
    var people: Int
    var tipAmount: Double
    var total: Double
    var date: Date
}

struct KilterLogEntrySnapshot: Codable, Sendable {
    var climbUUID: String
    var climbName: String
    var angle: Int
    var difficulty: Double
    var gradeLabel: String
    var statusRaw: String
    var attempts: Int
    var date: Date
    var sessionId: UUID?
    var startedAt: Date?
    var endedAt: Date?
    var attemptTimestamps: [Date]
    var note: String?
}

struct KilterSessionSnapshot: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var angle: Int
    var source: String
    var hrSeries: [HRPointSnapshot]
    var maxHR: Double?
    var restHR: Double?
    var metricsSourceRaw: String?
    var kcalEstimate: Double?
}

struct KilterFavoriteSnapshot: Codable, Sendable {
    var climbUUID: String
    var addedAt: Date
}

struct KilterCreatedClimbSnapshot: Codable, Sendable {
    var uuid: String
    var name: String
    var setterUsername: String
    var layoutId: Int
    var sizeId: Int
    var angle: Int
    var frames: String
    var edgeLeft: Int
    var edgeRight: Int
    var edgeBottom: Int
    var edgeTop: Int
    var isNoMatch: Bool
    var predictedGrade: Double?
    var source: String
    var modelId: String?
    var createdAt: Date
}
