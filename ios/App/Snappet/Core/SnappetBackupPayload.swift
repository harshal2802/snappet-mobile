import Foundation

// MARK: - Bundle

/// Top-level backup envelope written by `SnappetBackupEngine.serialize` and read back by
/// `SnappetBackupEngine.deserialize`. Versioned so future migrations can detect old shapes.
///
/// **On PHAsset references**: `SessionMedia` and `ClipEdit` store Photos `localIdentifier`
/// strings. These are device-specific — they point to items in the local Photos library and
/// won't resolve on a different device. The data is preserved (so edits and assignments
/// are retained) but the underlying asset bytes travel with the device backup, not this file.
struct SnappetBackup: Codable, Sendable {
    /// Incremented when the payload shape changes in a non-additive way. Decoders should
    /// reject versions they don't understand; additive field additions require no version bump.
    var schemaVersion: Int = 1
    var exportedAt: Date

    // Core
    var usageRecords: [UsageRecordDTO] = []

    // Productivity
    var pomodoroSessions: [PomodoroSessionDTO] = []
    var habits: [HabitDTO] = []
    var habitCompletions: [HabitCompletionDTO] = []
    var journalEntries: [JournalEntryDTO] = []

    // Finance
    var expenseGroups: [ExpenseGroupDTO] = []
    var expenseRecords: [ExpenseRecordDTO] = []
    var budgetCategories: [BudgetCategoryDTO] = []
    var budgetTransactions: [BudgetTransactionDTO] = []

    // Fitness
    var routines: [RoutineDTO] = []
    var workoutSessions: [WorkoutSessionDTO] = []
    var customExercises: [CustomExerciseDTO] = []
    var sessionMedia: [SessionMediaDTO] = []
    var clipEdits: [ClipEditDTO] = []
    var studioProjects: [StudioProjectDTO] = []
    var tipCalculations: [TipCalculationDTO] = []

    // Kilter
    var kilterLogEntries: [KilterLogEntryDTO] = []
    var kilterSessions: [KilterSessionDTO] = []
    var kilterFavorites: [KilterFavoriteDTO] = []
    var kilterCreatedClimbs: [KilterCreatedClimbDTO] = []
}

// MARK: - Core DTOs

struct UsageRecordDTO: Codable, Sendable {
    var module: String
    var action: String
    var summary: String
    var metric: Double?
    var timestamp: Date
}

// MARK: - Productivity DTOs

struct PomodoroSessionDTO: Codable, Sendable {
    var minutes: Int
    var completedAt: Date
}

struct HabitDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var createdAt: Date
}

struct HabitCompletionDTO: Codable, Sendable {
    var habitID: UUID
    var day: Date
}

struct JournalEntryDTO: Codable, Sendable {
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
}

// MARK: - Finance DTOs

struct ExpenseGroupDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var participants: [String]
    var createdAt: Date
}

struct ReceiptItemDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var price: Double
    var assignees: [String]
}

struct ExpenseRecordDTO: Codable, Sendable {
    var groupID: UUID
    var title: String
    var amount: Double
    var payer: String
    var participants: [String]
    var date: Date
    var isSettlement: Bool
    var items: [ReceiptItemDTO]
    var taxAmount: Double
    var discountAmount: Double
}

struct BudgetCategoryDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var monthlyLimit: Double
    var createdAt: Date
}

struct BudgetTransactionDTO: Codable, Sendable {
    var categoryID: UUID
    var amount: Double
    var note: String
    var date: Date
}

// MARK: - Fitness DTOs

struct RoutineExerciseDTO: Codable, Sendable {
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

struct RoutineDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var exercises: [RoutineExerciseDTO]
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

struct SetLogDTO: Codable, Sendable {
    var actualReps: Int?
    var actualWeight: Double?
    var weightUnit: String?
    var completedAt: Date?
    var durationSec: Double?
    var climbGradeLabel: String?
    var climbStatusRaw: String?
    var climbAttempts: Int?
}

struct SessionExerciseDTO: Codable, Sendable {
    var id: UUID
    var exerciseId: String
    var targetSets: Int
    var targetReps: String
    var targetRestSeconds: Int
    var targetWeight: Double?
    var targetWeightUnit: String?
    var sets: [SetLogDTO]
    var skipped: Bool
    var displayName: String?
    var kindRaw: String?
}

struct HRPointDTO: Codable, Sendable {
    var t: Double
    var bpm: Double
    var rrIntervalsMs: [Double]?
}

struct WorkoutSessionDTO: Codable, Sendable {
    var id: UUID
    var routineID: UUID?
    var routineName: String
    var startedAt: Date
    var completedAt: Date?
    var exercises: [SessionExerciseDTO]
    var hrSeries: [HRPointDTO]
    var maxHR: Double?
    var restHR: Double?
    var metricsSourceRaw: String?
    var kcalEstimate: Double?
}

struct CustomExerciseDTO: Codable, Sendable {
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

/// Note: `localIdentifier` is a PHAsset identifier — device-specific.
struct SessionMediaDTO: Codable, Sendable {
    var id: UUID
    var sessionID: UUID
    var localIdentifier: String
    var kindRaw: String
    var offsetSec: Double
    var durationSec: Double?
    var addedManually: Bool
    var assignedExerciseID: UUID?
    var assignedSetIndex: Int?
    var assignmentSourceRaw: String
    var assignedClimbUUID: String?
    var createdAt: Date
}

/// Note: `localIdentifier` is a PHAsset identifier — device-specific.
struct ClipEditDTO: Codable, Sendable {
    var id: UUID
    var sessionMediaID: UUID
    var localIdentifier: String
    var trimStart: Double
    var trimEnd: Double?
    var splitOrder: Int
    var cropX: Double
    var cropY: Double
    var cropWidth: Double
    var cropHeight: Double
    var aspectRaw: String
    var speed: Double
    var textOverlaysJSON: Data
    var mutedOriginalAudio: Bool
    var musicTrackName: String?
    var hrOverlayJSON: Data?
    var createdAt: Date
    var updatedAt: Date
}

struct StudioProjectDTO: Codable, Sendable {
    var id: UUID
    var sessionID: UUID
    var title: String
    var aspectRaw: String
    var backgroundRaw: String
    var clipsJSON: Data
    var transitionsJSON: Data
    var overlaysJSON: Data
    var audioTracksJSON: Data
    var hrOverlayJSON: Data?
    var baseFrameJSON: Data?
    var createdAt: Date
    var updatedAt: Date
}

struct TipCalculationDTO: Codable, Sendable {
    var bill: Double
    var tipPct: Double
    var people: Int
    var tipAmount: Double
    var total: Double
    var date: Date
}

// MARK: - Kilter DTOs

struct KilterLogEntryDTO: Codable, Sendable {
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

struct KilterSessionDTO: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var angle: Int
    var source: String
    var hrSeries: [HRPointDTO]
    var maxHR: Double?
    var restHR: Double?
    var metricsSourceRaw: String?
    var kcalEstimate: Double?
}

struct KilterFavoriteDTO: Codable, Sendable {
    var climbUUID: String
    var addedAt: Date
}

struct KilterCreatedClimbDTO: Codable, Sendable {
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
