import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backup bundle (top-level Codable document)

/// Versioned JSON document containing every SwiftData model in the on-device store.
/// `schemaVersion: 0` is the initial schema; restore code must check this before importing.
struct SnappetBackupBundle: Codable {
    var schemaVersion: Int = 0
    var createdAt: Date
    var appVersion: String

    var usageRecords: [UsageRecordBackup]
    var pomodoroSessions: [PomodoroSessionBackup]
    var habits: [HabitBackup]
    var habitCompletions: [HabitCompletionBackup]
    var journalEntries: [JournalEntryBackup]
    var expenseGroups: [ExpenseGroupBackup]
    var expenseRecords: [ExpenseRecordBackup]
    var budgetCategories: [BudgetCategoryBackup]
    var budgetTransactions: [BudgetTransactionBackup]
    var routines: [RoutineBackup]
    var workoutSessions: [WorkoutSessionBackup]
    var customExercises: [CustomExerciseBackup]
    var sessionMedia: [SessionMediaBackup]
    var clipEdits: [ClipEditBackup]
    var studioProjects: [StudioProjectBackup]
    var tipCalculations: [TipCalculationBackup]
    var kilterLogEntries: [KilterLogEntryBackup]
    var kilterSessions: [KilterSessionBackup]
    var kilterFavorites: [KilterFavoriteBackup]
    var kilterCreatedClimbs: [KilterCreatedClimbBackup]
}

// MARK: - DTO types (one per @Model)

struct UsageRecordBackup: Codable, Sendable {
    var module: String
    var action: String
    var summary: String
    var metric: Double?
    var timestamp: Date
}

struct PomodoroSessionBackup: Codable, Sendable {
    var minutes: Int
    var completedAt: Date
}

struct HabitBackup: Codable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var createdAt: Date
}

struct HabitCompletionBackup: Codable, Sendable {
    var habitID: UUID
    var day: Date
}

struct JournalEntryBackup: Codable, Sendable {
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
}

struct ExpenseGroupBackup: Codable, Sendable {
    var id: UUID
    var name: String
    var participants: [String]
    var createdAt: Date
}

struct ExpenseRecordBackup: Codable, Sendable {
    var groupID: UUID
    var title: String
    var amount: Double
    var payer: String
    var participants: [String]
    var date: Date
    var isSettlement: Bool
    var items: [ReceiptItem]
    var taxAmount: Double
    var discountAmount: Double
}

struct BudgetCategoryBackup: Codable, Sendable {
    var id: UUID
    var name: String
    var monthlyLimit: Double
    var createdAt: Date
}

struct BudgetTransactionBackup: Codable, Sendable {
    var categoryID: UUID
    var amount: Double
    var note: String
    var date: Date
}

struct RoutineBackup: Codable, Sendable {
    var id: UUID
    var name: String
    var exercises: [RoutineExercise]
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

struct WorkoutSessionBackup: Codable, Sendable {
    var id: UUID
    var routineID: UUID?
    var routineName: String
    var startedAt: Date
    var completedAt: Date?
    var exercises: [SessionExercise]
    var hrSeries: [HRPoint]
    var maxHR: Double?
    var restHR: Double?
    var metricsSourceRaw: String?
    var kcalEstimate: Double?
}

struct CustomExerciseBackup: Codable, Sendable {
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

struct SessionMediaBackup: Codable, Sendable {
    var id: UUID
    var sessionID: UUID
    var localIdentifier: String
    var kindRaw: String
    var offsetSec: Double
    var durationSec: Double?
    var addedManually: Bool
    var createdAt: Date
    var assignedExerciseID: UUID?
    var assignedSetIndex: Int?
    var assignmentSourceRaw: String
    var assignedClimbUUID: String?
}

struct ClipEditBackup: Codable, Sendable {
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
    var textOverlays: [TextOverlay]
    var mutedOriginalAudio: Bool
    var musicTrackName: String?
    var hrOverlay: HROverlayConfig?
    var createdAt: Date
    var updatedAt: Date
}

struct StudioProjectBackup: Codable, Sendable {
    var id: UUID
    var sessionID: UUID
    var title: String
    var aspectRaw: String
    var backgroundRaw: String
    var clips: [TimelineClip]
    var transitions: [StudioTransition]
    var overlays: [OverlayItem]
    var audioTracks: [AudioTrack]
    var hrOverlay: HROverlayConfig?
    var baseFrame: StudioFrameRect?
    var createdAt: Date
    var updatedAt: Date
}

struct TipCalculationBackup: Codable, Sendable {
    var bill: Double
    var tipPct: Double
    var people: Int
    var tipAmount: Double
    var total: Double
    var date: Date
}

struct KilterLogEntryBackup: Codable, Sendable {
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

struct KilterSessionBackup: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var angle: Int
    var source: String
    var hrSeries: [HRPoint]
    var maxHR: Double?
    var restHR: Double?
    var metricsSourceRaw: String?
    var kcalEstimate: Double?
}

struct KilterFavoriteBackup: Codable, Sendable {
    var climbUUID: String
    var addedAt: Date
}

struct KilterCreatedClimbBackup: Codable, Sendable {
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

// MARK: - Export document (FileDocument for .fileExporter)

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data, .plainText, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case serializationFailed(String)
    case unsupportedSchemaVersion(Int)
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .serializationFailed(let reason): return "Backup failed: \(reason)"
        case .unsupportedSchemaVersion(let v): return "Backup schema version \(v) is not supported by this version of Snappet."
        case .emptyFile: return "The selected file appears to be empty or unreadable."
        }
    }
}

// MARK: - Service

/// Pure serialization/restore logic for the on-device data store.
/// All methods that touch `ModelContext` must be called from the main actor (SwiftData requirement).
/// Export/format helpers are pure and actor-independent.
enum DataBackupService {

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Full backup (serialize)

    @MainActor
    static func serialize(context: ModelContext) throws -> Data {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        let usageRecords = (try? context.fetch(FetchDescriptor<UsageRecord>())) ?? []
        let pomodoroSessions = (try? context.fetch(FetchDescriptor<PomodoroSession>())) ?? []
        let habits = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        let habitCompletions = (try? context.fetch(FetchDescriptor<HabitCompletion>())) ?? []
        let journalEntries = (try? context.fetch(FetchDescriptor<JournalEntry>())) ?? []
        let expenseGroups = (try? context.fetch(FetchDescriptor<ExpenseGroup>())) ?? []
        let expenseRecords = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []
        let budgetCategories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        let budgetTransactions = (try? context.fetch(FetchDescriptor<BudgetTransaction>())) ?? []
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        let workoutSessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let customExercises = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let sessionMediaItems = (try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []
        let clipEdits = (try? context.fetch(FetchDescriptor<ClipEdit>())) ?? []
        let studioProjects = (try? context.fetch(FetchDescriptor<StudioProject>())) ?? []
        let tipCalculations = (try? context.fetch(FetchDescriptor<TipCalculation>())) ?? []
        let kilterLogEntries = (try? context.fetch(FetchDescriptor<KilterLogEntry>())) ?? []
        let kilterSessions = (try? context.fetch(FetchDescriptor<KilterSession>())) ?? []
        let kilterFavorites = (try? context.fetch(FetchDescriptor<KilterFavorite>())) ?? []
        let kilterCreatedClimbs = (try? context.fetch(FetchDescriptor<KilterCreatedClimb>())) ?? []

        let bundle = SnappetBackupBundle(
            createdAt: .now,
            appVersion: appVersion,
            usageRecords: usageRecords.map {
                UsageRecordBackup(module: $0.module, action: $0.action, summary: $0.summary,
                                  metric: $0.metric, timestamp: $0.timestamp)
            },
            pomodoroSessions: pomodoroSessions.map {
                PomodoroSessionBackup(minutes: $0.minutes, completedAt: $0.completedAt)
            },
            habits: habits.map {
                HabitBackup(id: $0.id, name: $0.name, symbol: $0.symbol, createdAt: $0.createdAt)
            },
            habitCompletions: habitCompletions.map {
                HabitCompletionBackup(habitID: $0.habitID, day: $0.day)
            },
            journalEntries: journalEntries.map {
                JournalEntryBackup(title: $0.title, body: $0.body,
                                   createdAt: $0.createdAt, updatedAt: $0.updatedAt, tags: $0.tags)
            },
            expenseGroups: expenseGroups.map {
                ExpenseGroupBackup(id: $0.id, name: $0.name,
                                   participants: $0.participants, createdAt: $0.createdAt)
            },
            expenseRecords: expenseRecords.map {
                ExpenseRecordBackup(groupID: $0.groupID, title: $0.title, amount: $0.amount,
                                    payer: $0.payer, participants: $0.participants, date: $0.date,
                                    isSettlement: $0.isSettlement, items: $0.items,
                                    taxAmount: $0.taxAmount, discountAmount: $0.discountAmount)
            },
            budgetCategories: budgetCategories.map {
                BudgetCategoryBackup(id: $0.id, name: $0.name,
                                     monthlyLimit: $0.monthlyLimit, createdAt: $0.createdAt)
            },
            budgetTransactions: budgetTransactions.map {
                BudgetTransactionBackup(categoryID: $0.categoryID, amount: $0.amount,
                                        note: $0.note, date: $0.date)
            },
            routines: routines.map {
                RoutineBackup(id: $0.id, name: $0.name, exercises: $0.exercises,
                              createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                              isStarter: $0.isStarter, starterKey: $0.starterKey,
                              sportRaw: $0.sportRaw, levelRaw: $0.levelRaw,
                              tags: $0.tags, detail: $0.detail,
                              sourceLabel: $0.sourceLabel, sourceURL: $0.sourceURL)
            },
            workoutSessions: workoutSessions.map {
                WorkoutSessionBackup(id: $0.id, routineID: $0.routineID,
                                     routineName: $0.routineName, startedAt: $0.startedAt,
                                     completedAt: $0.completedAt, exercises: $0.exercises,
                                     hrSeries: $0.hrSeries, maxHR: $0.maxHR, restHR: $0.restHR,
                                     metricsSourceRaw: $0.metricsSourceRaw, kcalEstimate: $0.kcalEstimate)
            },
            customExercises: customExercises.map {
                CustomExerciseBackup(id: $0.id, name: $0.name, categoryRaw: $0.categoryRaw,
                                     levelRaw: $0.levelRaw, forceRaw: $0.forceRaw,
                                     mechanicRaw: $0.mechanicRaw, equipmentRaw: $0.equipmentRaw,
                                     primaryMuscles: $0.primaryMuscles,
                                     secondaryMuscles: $0.secondaryMuscles,
                                     instructions: $0.instructions, createdAt: $0.createdAt)
            },
            sessionMedia: sessionMediaItems.map {
                SessionMediaBackup(id: $0.id, sessionID: $0.sessionID,
                                   localIdentifier: $0.localIdentifier, kindRaw: $0.kindRaw,
                                   offsetSec: $0.offsetSec, durationSec: $0.durationSec,
                                   addedManually: $0.addedManually, createdAt: $0.createdAt,
                                   assignedExerciseID: $0.assignedExerciseID,
                                   assignedSetIndex: $0.assignedSetIndex,
                                   assignmentSourceRaw: $0.assignmentSourceRaw,
                                   assignedClimbUUID: $0.assignedClimbUUID)
            },
            clipEdits: clipEdits.map {
                ClipEditBackup(id: $0.id, sessionMediaID: $0.sessionMediaID,
                               localIdentifier: $0.localIdentifier, trimStart: $0.trimStart,
                               trimEnd: $0.trimEnd, splitOrder: $0.splitOrder,
                               cropX: $0.cropX, cropY: $0.cropY,
                               cropWidth: $0.cropWidth, cropHeight: $0.cropHeight,
                               aspectRaw: $0.aspectRaw, speed: $0.speed,
                               textOverlays: $0.textOverlays, mutedOriginalAudio: $0.mutedOriginalAudio,
                               musicTrackName: $0.musicTrackName, hrOverlay: $0.hrOverlay,
                               createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            studioProjects: studioProjects.map {
                StudioProjectBackup(id: $0.id, sessionID: $0.sessionID, title: $0.title,
                                    aspectRaw: $0.aspectRaw, backgroundRaw: $0.backgroundRaw,
                                    clips: $0.clips, transitions: $0.transitions,
                                    overlays: $0.overlays, audioTracks: $0.audioTracks,
                                    hrOverlay: $0.hrOverlay, baseFrame: $0.baseFrame,
                                    createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            tipCalculations: tipCalculations.map {
                TipCalculationBackup(bill: $0.bill, tipPct: $0.tipPct, people: $0.people,
                                     tipAmount: $0.tipAmount, total: $0.total, date: $0.date)
            },
            kilterLogEntries: kilterLogEntries.map {
                KilterLogEntryBackup(climbUUID: $0.climbUUID, climbName: $0.climbName,
                                     angle: $0.angle, difficulty: $0.difficulty,
                                     gradeLabel: $0.gradeLabel, statusRaw: $0.statusRaw,
                                     attempts: $0.attempts, date: $0.date,
                                     sessionId: $0.sessionId, startedAt: $0.startedAt,
                                     endedAt: $0.endedAt,
                                     attemptTimestamps: $0.attemptTimestamps, note: $0.note)
            },
            kilterSessions: kilterSessions.map {
                KilterSessionBackup(id: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt,
                                    angle: $0.angle, source: $0.source, hrSeries: $0.hrSeries,
                                    maxHR: $0.maxHR, restHR: $0.restHR,
                                    metricsSourceRaw: $0.metricsSourceRaw,
                                    kcalEstimate: $0.kcalEstimate)
            },
            kilterFavorites: kilterFavorites.map {
                KilterFavoriteBackup(climbUUID: $0.climbUUID, addedAt: $0.addedAt)
            },
            kilterCreatedClimbs: kilterCreatedClimbs.map {
                KilterCreatedClimbBackup(uuid: $0.uuid, name: $0.name,
                                         setterUsername: $0.setterUsername, layoutId: $0.layoutId,
                                         sizeId: $0.sizeId, angle: $0.angle, frames: $0.frames,
                                         edgeLeft: $0.edgeLeft, edgeRight: $0.edgeRight,
                                         edgeBottom: $0.edgeBottom, edgeTop: $0.edgeTop,
                                         isNoMatch: $0.isNoMatch, predictedGrade: $0.predictedGrade,
                                         source: $0.source, modelId: $0.modelId,
                                         createdAt: $0.createdAt)
            }
        )

        do {
            return try makeEncoder().encode(bundle)
        } catch {
            throw BackupError.serializationFailed(error.localizedDescription)
        }
    }

    // MARK: - Full restore

    @MainActor
    static func restore(from data: Data, into context: ModelContext) throws {
        guard !data.isEmpty else { throw BackupError.emptyFile }
        let bundle: SnappetBackupBundle
        do {
            bundle = try makeDecoder().decode(SnappetBackupBundle.self, from: data)
        } catch {
            throw BackupError.serializationFailed(error.localizedDescription)
        }
        guard bundle.schemaVersion == 0 else {
            throw BackupError.unsupportedSchemaVersion(bundle.schemaVersion)
        }

        // Clear all existing data before restoring (restore = full replace).
        try context.delete(model: UsageRecord.self)
        try context.delete(model: PomodoroSession.self)
        try context.delete(model: Habit.self)
        try context.delete(model: HabitCompletion.self)
        try context.delete(model: JournalEntry.self)
        try context.delete(model: ExpenseGroup.self)
        try context.delete(model: ExpenseRecord.self)
        try context.delete(model: BudgetCategory.self)
        try context.delete(model: BudgetTransaction.self)
        try context.delete(model: Routine.self)
        try context.delete(model: WorkoutSession.self)
        try context.delete(model: CustomExercise.self)
        try context.delete(model: SessionMedia.self)
        try context.delete(model: ClipEdit.self)
        try context.delete(model: StudioProject.self)
        try context.delete(model: TipCalculation.self)
        try context.delete(model: KilterLogEntry.self)
        try context.delete(model: KilterSession.self)
        try context.delete(model: KilterFavorite.self)
        try context.delete(model: KilterCreatedClimb.self)

        for b in bundle.usageRecords {
            context.insert(UsageRecord(module: b.module, action: b.action, summary: b.summary,
                                       metric: b.metric, timestamp: b.timestamp))
        }
        for b in bundle.pomodoroSessions {
            context.insert(PomodoroSession(minutes: b.minutes, completedAt: b.completedAt))
        }
        for b in bundle.habits {
            context.insert(Habit(id: b.id, name: b.name, symbol: b.symbol, createdAt: b.createdAt))
        }
        for b in bundle.habitCompletions {
            context.insert(HabitCompletion(habitID: b.habitID, day: b.day))
        }
        for b in bundle.journalEntries {
            context.insert(JournalEntry(title: b.title, body: b.body,
                                        createdAt: b.createdAt, updatedAt: b.updatedAt, tags: b.tags))
        }
        for b in bundle.expenseGroups {
            context.insert(ExpenseGroup(id: b.id, name: b.name,
                                        participants: b.participants, createdAt: b.createdAt))
        }
        for b in bundle.expenseRecords {
            context.insert(ExpenseRecord(groupID: b.groupID, title: b.title, amount: b.amount,
                                         payer: b.payer, participants: b.participants, date: b.date,
                                         isSettlement: b.isSettlement, items: b.items,
                                         taxAmount: b.taxAmount, discountAmount: b.discountAmount))
        }
        for b in bundle.budgetCategories {
            context.insert(BudgetCategory(id: b.id, name: b.name,
                                          monthlyLimit: b.monthlyLimit, createdAt: b.createdAt))
        }
        for b in bundle.budgetTransactions {
            context.insert(BudgetTransaction(categoryID: b.categoryID, amount: b.amount,
                                             note: b.note, date: b.date))
        }
        for b in bundle.routines {
            let r = Routine(id: b.id, name: b.name, exercises: b.exercises,
                            createdAt: b.createdAt, updatedAt: b.updatedAt,
                            isStarter: b.isStarter, starterKey: b.starterKey,
                            tags: b.tags, detail: b.detail,
                            sourceLabel: b.sourceLabel, sourceURL: b.sourceURL)
            r.sportRaw = b.sportRaw
            r.levelRaw = b.levelRaw
            context.insert(r)
        }
        for b in bundle.workoutSessions {
            context.insert(WorkoutSession(id: b.id, routineID: b.routineID,
                                          routineName: b.routineName, startedAt: b.startedAt,
                                          completedAt: b.completedAt, exercises: b.exercises,
                                          hrSeries: b.hrSeries, maxHR: b.maxHR, restHR: b.restHR,
                                          metricsSourceRaw: b.metricsSourceRaw,
                                          kcalEstimate: b.kcalEstimate))
        }
        for b in bundle.customExercises {
            let ce = CustomExercise(id: b.id, name: b.name,
                                    category: ExerciseCategory(rawValue: b.categoryRaw) ?? .strength,
                                    level: ExerciseLevel(rawValue: b.levelRaw) ?? .beginner,
                                    force: b.forceRaw.flatMap(Force.init),
                                    mechanic: b.mechanicRaw.flatMap(Mechanic.init),
                                    equipment: b.equipmentRaw.flatMap(Equipment.init),
                                    primaryMuscles: b.primaryMuscles.compactMap(Muscle.init),
                                    secondaryMuscles: b.secondaryMuscles.compactMap(Muscle.init),
                                    instructions: b.instructions, createdAt: b.createdAt)
            context.insert(ce)
        }
        for b in bundle.sessionMedia {
            let sm = SessionMedia(id: b.id, sessionID: b.sessionID,
                                  localIdentifier: b.localIdentifier,
                                  kind: SessionMedia.Kind(rawValue: b.kindRaw) ?? .video,
                                  offsetSec: b.offsetSec, durationSec: b.durationSec,
                                  addedManually: b.addedManually,
                                  assignedExerciseID: b.assignedExerciseID,
                                  assignedSetIndex: b.assignedSetIndex,
                                  assignedClimbUUID: b.assignedClimbUUID,
                                  createdAt: b.createdAt)
            sm.assignmentSourceRaw = b.assignmentSourceRaw
            context.insert(sm)
        }
        for b in bundle.clipEdits {
            let ce = ClipEdit(id: b.id, sessionMediaID: b.sessionMediaID,
                              localIdentifier: b.localIdentifier,
                              trimStart: b.trimStart, trimEnd: b.trimEnd,
                              splitOrder: b.splitOrder,
                              cropRect: CGRect(x: b.cropX, y: b.cropY,
                                              width: b.cropWidth, height: b.cropHeight),
                              aspect: ClipEditGeometry.OutputAspect(rawValue: b.aspectRaw) ?? .portrait9x16,
                              speed: b.speed, textOverlays: b.textOverlays,
                              mutedOriginalAudio: b.mutedOriginalAudio,
                              musicTrackName: b.musicTrackName,
                              hrOverlay: b.hrOverlay, createdAt: b.createdAt)
            ce.updatedAt = b.updatedAt
            context.insert(ce)
        }
        for b in bundle.studioProjects {
            let sp = StudioProject(id: b.id, sessionID: b.sessionID, title: b.title,
                                   aspect: ClipEditGeometry.OutputAspect(rawValue: b.aspectRaw) ?? .portrait9x16,
                                   background: StudioBackground(rawValue: b.backgroundRaw) ?? .black,
                                   clips: b.clips, transitions: b.transitions,
                                   overlays: b.overlays, audioTracks: b.audioTracks,
                                   hrOverlay: b.hrOverlay, baseFrame: b.baseFrame,
                                   createdAt: b.createdAt)
            sp.updatedAt = b.updatedAt
            context.insert(sp)
        }
        for b in bundle.tipCalculations {
            context.insert(TipCalculation(bill: b.bill, tipPct: b.tipPct, people: b.people,
                                          tipAmount: b.tipAmount, total: b.total, date: b.date))
        }
        for b in bundle.kilterLogEntries {
            context.insert(KilterLogEntry(climbUUID: b.climbUUID, climbName: b.climbName,
                                          angle: b.angle, difficulty: b.difficulty,
                                          gradeLabel: b.gradeLabel,
                                          status: KilterAscentStatus(rawValue: b.statusRaw) ?? .attempt,
                                          attempts: b.attempts, date: b.date,
                                          sessionId: b.sessionId,
                                          startedAt: b.startedAt, endedAt: b.endedAt,
                                          attemptTimestamps: b.attemptTimestamps, note: b.note))
        }
        for b in bundle.kilterSessions {
            context.insert(KilterSession(id: b.id, startedAt: b.startedAt, endedAt: b.endedAt,
                                         angle: b.angle, source: b.source, hrSeries: b.hrSeries,
                                         maxHR: b.maxHR, restHR: b.restHR,
                                         metricsSourceRaw: b.metricsSourceRaw,
                                         kcalEstimate: b.kcalEstimate))
        }
        for b in bundle.kilterFavorites {
            context.insert(KilterFavorite(climbUUID: b.climbUUID, addedAt: b.addedAt))
        }
        for b in bundle.kilterCreatedClimbs {
            context.insert(KilterCreatedClimb(uuid: b.uuid, name: b.name,
                                              setterUsername: b.setterUsername,
                                              layoutId: b.layoutId, sizeId: b.sizeId,
                                              angle: b.angle, frames: b.frames,
                                              edgeLeft: b.edgeLeft, edgeRight: b.edgeRight,
                                              edgeBottom: b.edgeBottom, edgeTop: b.edgeTop,
                                              isNoMatch: b.isNoMatch,
                                              predictedGrade: b.predictedGrade,
                                              source: b.source, modelId: b.modelId,
                                              createdAt: b.createdAt))
        }

        try context.save()
    }

    // MARK: - Per-module exports (pure — no ModelContext, testable without a device)

    static func journalMarkdown(_ entries: [JournalEntry]) -> Data {
        var lines: [String] = []
        let df = ISO8601DateFormatter()
        for entry in entries.sorted(by: { $0.createdAt > $1.createdAt }) {
            if !entry.title.isEmpty { lines.append("# \(entry.title)") }
            lines.append("*\(df.string(from: entry.createdAt))*")
            if !entry.tags.isEmpty { lines.append("Tags: \(entry.tags.joined(separator: ", "))") }
            lines.append("")
            lines.append(entry.body)
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    static func budgetCSV(categories: [BudgetCategory], transactions: [BudgetTransaction]) -> Data {
        var lines = ["Categories"]
        lines.append("ID,Name,Monthly Limit,Created At")
        let df = ISO8601DateFormatter()
        for c in categories.sorted(by: { $0.name < $1.name }) {
            lines.append("\(c.id),\(csvEscape(c.name)),\(String(format: "%.2f", c.monthlyLimit)),\(df.string(from: c.createdAt))")
        }
        lines.append("")
        lines.append("Transactions")
        lines.append("Category ID,Amount,Note,Date")
        for t in transactions.sorted(by: { $0.date > $1.date }) {
            lines.append("\(t.categoryID),\(String(format: "%.2f", t.amount)),\(csvEscape(t.note)),\(df.string(from: t.date))")
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    static func expenseCSV(groups: [ExpenseGroup], records: [ExpenseRecord]) -> Data {
        var lines = ["Groups"]
        lines.append("ID,Name,Participants,Created At")
        let df = ISO8601DateFormatter()
        for g in groups.sorted(by: { $0.name < $1.name }) {
            lines.append("\(g.id),\(csvEscape(g.name)),\(csvEscape(g.participants.joined(separator: "|"))),\(df.string(from: g.createdAt))")
        }
        lines.append("")
        lines.append("Records")
        lines.append("Group ID,Title,Amount,Payer,Participants,Date,Is Settlement,Tax,Discount")
        for r in records.sorted(by: { $0.date > $1.date }) {
            lines.append(
                "\(r.groupID),\(csvEscape(r.title)),\(String(format: "%.2f", r.amount))," +
                "\(csvEscape(r.payer)),\(csvEscape(r.participants.joined(separator: "|")))," +
                "\(df.string(from: r.date)),\(r.isSettlement)," +
                "\(String(format: "%.2f", r.taxAmount)),\(String(format: "%.2f", r.discountAmount))"
            )
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    static func workoutJSON(_ sessions: [WorkoutSession]) throws -> Data {
        struct WorkoutExportRow: Codable {
            var id: UUID
            var routineName: String
            var startedAt: Date
            var completedAt: Date?
            var durationMinutes: Double?
            var completedSets: Int
            var completedExercises: Int
            var hrSeries: [HRPoint]
            var maxHR: Double?
            var kcalEstimate: Double?
        }
        let rows = sessions.sorted(by: { $0.startedAt > $1.startedAt }).map { s in
            WorkoutExportRow(
                id: s.id, routineName: s.routineName,
                startedAt: s.startedAt, completedAt: s.completedAt,
                durationMinutes: s.completedAt.map { $0.timeIntervalSince(s.startedAt) / 60 },
                completedSets: s.completedSetCount, completedExercises: s.completedExerciseCount,
                hrSeries: s.hrSeries, maxHR: s.maxHR, kcalEstimate: s.kcalEstimate
            )
        }
        return try makeEncoder().encode(rows)
    }

    // MARK: - Private helpers

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
