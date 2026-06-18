import Foundation
import SwiftData

/// Why a backup file can't be read/restored. User-facing copy via `errorDescription`.
enum SnappetBackupError: LocalizedError, Equatable {
    case notABackup
    case unsupportedVersion(Int)
    case damaged

    var errorDescription: String? {
        switch self {
        case .notABackup:
            return "This file isn't a Snappet backup."
        case .unsupportedVersion(let v):
            return "This backup uses format \(v); this version of Snappet reads format "
                + "\(SnappetBackup.formatVersion). Re-export it from the app that made it."
        case .damaged:
            return "This backup file is damaged or incomplete."
        }
    }
}

/// The Snappet suite backup codec (issue #68): ONE versioned JSON document holding every row
/// of every `SnappetSchema` model, so the whole on-device store can be written to Files and
/// restored later (replace-everything, the Android #84 shared semantics).
///
/// iOS design note — explicit rows, not SQLite-level dumps: the Android backup reads tables
/// schema-agnostically, but SwiftData doesn't expose its storage, so each `@Model` gets a
/// `Codable & Hashable` **Row** mirror of its *stored* properties (raw enum strings stay raw —
/// no value is laundered through an enum and lost). The drift hazard that creates is fenced by
/// `coveredModels`: a unit test fails the build's test run whenever `SnappetSchema.models`
/// gains a model the codec doesn't cover.
///
/// Purity split: `encode`/`decode` are pure data↔data (unit-tested without a store);
/// `snapshot(of:)`/`restore(_:into:)` are the thin SwiftData edge (unit-tested against an
/// in-memory container).
///
/// Format choices (also see decisions.md 2026-06-10):
/// - `Date`s use the encoder default (`deferredToDate`, seconds since the reference date as a
///   `Double`) — the only representation that round-trips a `Date` **exactly**; ISO-8601 would
///   truncate sub-second precision and break restore fidelity.
/// - Compact JSON (`sortedKeys`, no pretty-print): workout/Kilter HR series are kept at FULL
///   fidelity (a backup must restore what was there — downsampling would corrupt the source of
///   truth), so compactness is the lever that keeps an HR-heavy backup small enough to drop
///   into an iCloud Drive folder (~100 bytes/sample ⇒ a few hundred KB per hour-long session).
enum SnappetBackup {
    static let kind = "snappet.backup"
    static let formatVersion = 1

    /// Every model this codec covers. MUST stay in lockstep with `SnappetSchema.models` —
    /// `SnappetBackupTests.testCodecCoversEverySchemaModel` is the tripwire.
    static let coveredModels: [any PersistentModel.Type] = [
        UsageRecord.self,
        PomodoroSession.self,
        Habit.self, HabitCompletion.self,
        JournalEntry.self,
        ExpenseGroup.self, ExpenseRecord.self,
        BudgetCategory.self, BudgetTransaction.self,
        Routine.self, WorkoutSession.self, CustomExercise.self, SessionMedia.self,
        TimedExerciseCatalog.self,
        StudioProject.self,
        TipCalculation.self,
        KilterLogEntry.self, KilterSession.self, KilterFavorite.self, KilterCreatedClimb.self,
        KilterPlan.self,
    ]

    // MARK: - The envelope

    /// The whole store as one Codable value. One array per `@Model`; arrays are sorted by a
    /// stable per-row key so the same store always encodes to the same bytes (diffable, and
    /// re-export-equality is testable). `Sendable` (explicitly, with the rows) because
    /// `BackupView` decodes a picked file OFF the main actor and hands the result back.
    struct File: Codable, Hashable, Sendable {
        var kind: String = SnappetBackup.kind
        var formatVersion: Int = SnappetBackup.formatVersion
        var exportedAt: Date = .now

        var usageRecords: [UsageRecordRow] = []
        var pomodoroSessions: [PomodoroSessionRow] = []
        var habits: [HabitRow] = []
        var habitCompletions: [HabitCompletionRow] = []
        var journalEntries: [JournalEntryRow] = []
        var expenseGroups: [ExpenseGroupRow] = []
        var expenseRecords: [ExpenseRecordRow] = []
        var budgetCategories: [BudgetCategoryRow] = []
        var budgetTransactions: [BudgetTransactionRow] = []
        var routines: [RoutineRow] = []
        var workoutSessions: [WorkoutSessionRow] = []
        var customExercises: [CustomExerciseRow] = []
        var sessionMedia: [SessionMediaRow] = []
        var timedExerciseCatalog: [TimedExerciseCatalogRow] = []
        var studioProjects: [StudioProjectRow] = []
        var tipCalculations: [TipCalculationRow] = []
        var kilterLogEntries: [KilterLogEntryRow] = []
        var kilterSessions: [KilterSessionRow] = []
        var kilterFavorites: [KilterFavoriteRow] = []
        var kilterCreatedClimbs: [KilterCreatedClimbRow] = []
        var kilterPlans: [KilterPlanRow] = []

        /// Total rows across every model — for "Backed up N records" / restore confirmation copy.
        ///
        /// Summed imperatively into an explicitly-typed `Int` accumulator — deliberately NOT a 20-term
        /// `+` chain, and NOT a 20-element array literal + `reduce(0, +)`. Both of those forms overflow
        /// Swift's expression type-checker budget ("unable to type-check this expression in reasonable
        /// time") on a *clean* build, on different toolchains (the `+` chain on Xcode 26.3, the array
        /// literal on 26.5 — neither shape survives both). A plain running total is trivial for the
        /// type-checker everywhere. Keep it imperative — do not "simplify" it back into one expression.
        var recordCount: Int {
            var n = 0
            n += usageRecords.count
            n += pomodoroSessions.count
            n += habits.count
            n += habitCompletions.count
            n += journalEntries.count
            n += expenseGroups.count
            n += expenseRecords.count
            n += budgetCategories.count
            n += budgetTransactions.count
            n += routines.count
            n += workoutSessions.count
            n += customExercises.count
            n += sessionMedia.count
            n += timedExerciseCatalog.count
            n += studioProjects.count
            n += tipCalculations.count
            n += kilterLogEntries.count
            n += kilterSessions.count
            n += kilterFavorites.count
            n += kilterCreatedClimbs.count
            n += kilterPlans.count
            return n
        }
    }

    // MARK: - Pure codec (data ↔ data)

    static func encode(_ file: File) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    /// Strict same-version decode (#84 shared decision): a wrong-version file is rejected with
    /// a clear error — never best-effort-restored. ONE full-document parse in the happy path:
    /// the old sentinel-probe-then-decode paid the whole JSON parse TWICE (`JSONDecoder` parses
    /// the entire document even for a two-key probe), which a multi-MB HR-heavy backup turned
    /// into a visible stall (#68 review fix 7). The cheap probe now runs only to *classify a
    /// failure* — garbage/foreign JSON still gets the friendly `.notABackup`, a wrong version
    /// `.unsupportedVersion`, and a shape-broken same-version file `.damaged`.
    static func decode(_ data: Data) throws -> File {
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            guard file.kind == kind else { throw SnappetBackupError.notABackup }
            guard file.formatVersion == formatVersion else {
                throw SnappetBackupError.unsupportedVersion(file.formatVersion)
            }
            return file
        }
        struct Probe: Decodable {
            var kind: String?
            var formatVersion: Int?
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              probe.kind == kind, let version = probe.formatVersion else {
            throw SnappetBackupError.notABackup
        }
        guard version == formatVersion else { throw SnappetBackupError.unsupportedVersion(version) }
        throw SnappetBackupError.damaged
    }

    // MARK: - The SwiftData edge

    /// Read every model into one `File`. Rows are sorted in memory (not via `SortDescriptor`)
    /// so the ordering rule lives with the codec and the fetch stays trivial.
    static func snapshot(of context: ModelContext) throws -> File {
        func all<M: PersistentModel>(_ type: M.Type) throws -> [M] {
            try context.fetch(FetchDescriptor<M>())
        }
        var file = File()
        file.usageRecords = try all(UsageRecord.self).map(UsageRecordRow.init).sorted(by: rowKey)
        file.pomodoroSessions = try all(PomodoroSession.self).map(PomodoroSessionRow.init).sorted(by: rowKey)
        file.habits = try all(Habit.self).map(HabitRow.init).sorted(by: rowKey)
        file.habitCompletions = try all(HabitCompletion.self).map(HabitCompletionRow.init).sorted(by: rowKey)
        file.journalEntries = try all(JournalEntry.self).map(JournalEntryRow.init).sorted(by: rowKey)
        file.expenseGroups = try all(ExpenseGroup.self).map(ExpenseGroupRow.init).sorted(by: rowKey)
        file.expenseRecords = try all(ExpenseRecord.self).map(ExpenseRecordRow.init).sorted(by: rowKey)
        file.budgetCategories = try all(BudgetCategory.self).map(BudgetCategoryRow.init).sorted(by: rowKey)
        file.budgetTransactions = try all(BudgetTransaction.self).map(BudgetTransactionRow.init).sorted(by: rowKey)
        file.routines = try all(Routine.self).map(RoutineRow.init).sorted(by: rowKey)
        file.workoutSessions = try all(WorkoutSession.self).map(WorkoutSessionRow.init).sorted(by: rowKey)
        file.customExercises = try all(CustomExercise.self).map(CustomExerciseRow.init).sorted(by: rowKey)
        file.sessionMedia = try all(SessionMedia.self).map(SessionMediaRow.init).sorted(by: rowKey)
        file.timedExerciseCatalog = try all(TimedExerciseCatalog.self).map(TimedExerciseCatalogRow.init).sorted(by: rowKey)
        file.studioProjects = try all(StudioProject.self).map(StudioProjectRow.init).sorted(by: rowKey)
        file.tipCalculations = try all(TipCalculation.self).map(TipCalculationRow.init).sorted(by: rowKey)
        file.kilterLogEntries = try all(KilterLogEntry.self).map(KilterLogEntryRow.init).sorted(by: rowKey)
        file.kilterSessions = try all(KilterSession.self).map(KilterSessionRow.init).sorted(by: rowKey)
        file.kilterFavorites = try all(KilterFavorite.self).map(KilterFavoriteRow.init).sorted(by: rowKey)
        file.kilterCreatedClimbs = try all(KilterCreatedClimb.self).map(KilterCreatedClimbRow.init).sorted(by: rowKey)
        file.kilterPlans = try all(KilterPlan.self).map(KilterPlanRow.init).sorted(by: rowKey)
        return file
    }

    private static func rowKey<R: BackupRow>(_ a: R, _ b: R) -> Bool { a.sortKey < b.sortKey }

    /// Replace **everything** in the store with the file's contents. The caller has already
    /// decoded (= fully validated) the file, so the only remaining failure is the store itself.
    /// Delete-all + insert-all + ONE `save()` keeps the swap a single transaction — unique-key
    /// overlap between old and new rows (e.g. the same `KilterFavorite.climbUUID`) resolves
    /// inside that save; a throw rolls the context back with the old data intact.
    ///
    /// ⚠️ Live `@Model` references: callers holding a row of any covered model (the
    /// AppModel-owned `KilterSessionManager.current`) must detach them BEFORE calling this —
    /// every existing row is deleted, and a later write through a stale reference traps.
    /// `BackupView.runRestore()` does (`detachForStoreRestore()`).
    static func restore(_ file: File, into context: ModelContext) throws {
        func deleteAll<M: PersistentModel>(_ type: M.Type) throws {
            for row in try context.fetch(FetchDescriptor<M>()) { context.delete(row) }
        }
        /// First-wins dedupe by a row's identity key. Duplicate ids are *legal JSON* a
        /// tampered/hand-duplicated backup can carry — they must never enter the store, where
        /// they'd corrupt FK joins and id-keyed lookups (`ModuleExports`' CSV dictionaries
        /// assume id uniqueness). Rows with no natural identity (UsageRecord, JournalEntry,
        /// HabitCompletion, …) insert as-is: duplicates there are valid data. Chosen over
        /// reject-at-decode — see decisions.md 2026-06-10 (#68 review fix 4).
        func uniqued<R, ID: Hashable>(_ rows: [R], by id: (R) -> ID) -> [R] {
            var seen = Set<ID>()
            return rows.filter { seen.insert(id($0)).inserted }
        }
        do {
            // Deletes are HAND-LISTED per model, beside their inserts — deliberately NOT a
            // loop over `coveredModels`. A future model wired into the schema + the tripwire
            // list but not into File/snapshot/restore then fails SAFE: its rows survive a
            // restore (and the recordCount tests catch the drift) instead of being silently
            // wiped with nothing re-inserted (#68 review fix 5).
            try deleteAll(UsageRecord.self)
            file.usageRecords.forEach { context.insert($0.make()) }
            try deleteAll(PomodoroSession.self)
            file.pomodoroSessions.forEach { context.insert($0.make()) }
            try deleteAll(Habit.self)
            uniqued(file.habits, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(HabitCompletion.self)
            file.habitCompletions.forEach { context.insert($0.make()) }
            try deleteAll(JournalEntry.self)
            file.journalEntries.forEach { context.insert($0.make()) }
            try deleteAll(ExpenseGroup.self)
            uniqued(file.expenseGroups, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(ExpenseRecord.self)
            file.expenseRecords.forEach { context.insert($0.make()) }
            try deleteAll(BudgetCategory.self)
            uniqued(file.budgetCategories, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(BudgetTransaction.self)
            file.budgetTransactions.forEach { context.insert($0.make()) }
            try deleteAll(Routine.self)
            uniqued(file.routines, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(WorkoutSession.self)
            uniqued(file.workoutSessions, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(CustomExercise.self)
            uniqued(file.customExercises, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(SessionMedia.self)
            uniqued(file.sessionMedia, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(TimedExerciseCatalog.self)
            uniqued(file.timedExerciseCatalog, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(StudioProject.self)
            uniqued(file.studioProjects, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(TipCalculation.self)
            file.tipCalculations.forEach { context.insert($0.make()) }
            try deleteAll(KilterLogEntry.self)
            file.kilterLogEntries.forEach { context.insert($0.make()) }
            try deleteAll(KilterSession.self)
            uniqued(file.kilterSessions, by: \.id).forEach { context.insert($0.make()) }
            try deleteAll(KilterFavorite.self)
            uniqued(file.kilterFavorites, by: \.climbUUID).forEach { context.insert($0.make()) }
            try deleteAll(KilterCreatedClimb.self)
            uniqued(file.kilterCreatedClimbs, by: \.uuid).forEach { context.insert($0.make()) }
            try deleteAll(KilterPlan.self)
            uniqued(file.kilterPlans, by: \.id).forEach { context.insert($0.make()) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

/// A snapshot row: Codable both ways + a stable in-file ordering key. `Sendable` so a
/// decoded `File` can cross from the off-main decode task back to the UI (every row is a
/// pure value mirror — stored properties only).
protocol BackupRow: Codable, Hashable, Sendable {
    var sortKey: String { get }
}

// MARK: - Rows (one per @Model — stored properties only, raw strings kept raw)

extension SnappetBackup {
    struct UsageRecordRow: BackupRow {
        var module: String
        var action: String
        var summary: String
        var metric: Double?
        var timestamp: Date

        init(_ m: UsageRecord) {
            module = m.module; action = m.action; summary = m.summary
            metric = m.metric; timestamp = m.timestamp
        }
        func make() -> UsageRecord {
            UsageRecord(module: module, action: action, summary: summary,
                        metric: metric, timestamp: timestamp)
        }
        var sortKey: String { "\(timestamp.timeIntervalSinceReferenceDate)|\(module)|\(action)|\(summary)" }
    }

    struct PomodoroSessionRow: BackupRow {
        var minutes: Int
        var completedAt: Date

        init(_ m: PomodoroSession) { minutes = m.minutes; completedAt = m.completedAt }
        func make() -> PomodoroSession { PomodoroSession(minutes: minutes, completedAt: completedAt) }
        var sortKey: String { "\(completedAt.timeIntervalSinceReferenceDate)|\(minutes)" }
    }

    struct HabitRow: BackupRow {
        var id: UUID
        var name: String
        var symbol: String
        var createdAt: Date

        init(_ m: Habit) { id = m.id; name = m.name; symbol = m.symbol; createdAt = m.createdAt }
        func make() -> Habit { Habit(id: id, name: name, symbol: symbol, createdAt: createdAt) }
        var sortKey: String { id.uuidString }
    }

    struct HabitCompletionRow: BackupRow {
        var habitID: UUID
        var day: Date

        init(_ m: HabitCompletion) { habitID = m.habitID; day = m.day }
        func make() -> HabitCompletion { HabitCompletion(habitID: habitID, day: day) }
        var sortKey: String { "\(habitID.uuidString)|\(day.timeIntervalSinceReferenceDate)" }
    }

    struct JournalEntryRow: BackupRow {
        var title: String
        var body: String
        var createdAt: Date
        var updatedAt: Date
        var tags: [String]

        init(_ m: JournalEntry) {
            title = m.title; body = m.body; createdAt = m.createdAt
            updatedAt = m.updatedAt; tags = m.tags
        }
        func make() -> JournalEntry {
            let entry = JournalEntry(title: title, body: body, createdAt: createdAt, updatedAt: updatedAt)
            entry.tags = tags   // verbatim — the init re-normalizes, a restore must not
            return entry
        }
        var sortKey: String { "\(createdAt.timeIntervalSinceReferenceDate)|\(title)" }
    }

    struct ExpenseGroupRow: BackupRow {
        var id: UUID
        var name: String
        var participants: [String]
        var createdAt: Date

        init(_ m: ExpenseGroup) {
            id = m.id; name = m.name; participants = m.participants; createdAt = m.createdAt
        }
        func make() -> ExpenseGroup {
            ExpenseGroup(id: id, name: name, participants: participants, createdAt: createdAt)
        }
        var sortKey: String { id.uuidString }
    }

    struct ExpenseRecordRow: BackupRow {
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

        init(_ m: ExpenseRecord) {
            groupID = m.groupID; title = m.title; amount = m.amount; payer = m.payer
            participants = m.participants; date = m.date; isSettlement = m.isSettlement
            items = m.items; taxAmount = m.taxAmount; discountAmount = m.discountAmount
        }
        func make() -> ExpenseRecord {
            ExpenseRecord(groupID: groupID, title: title, amount: amount, payer: payer,
                          participants: participants, date: date, isSettlement: isSettlement,
                          items: items, taxAmount: taxAmount, discountAmount: discountAmount)
        }
        var sortKey: String { "\(groupID.uuidString)|\(date.timeIntervalSinceReferenceDate)|\(title)" }
    }

    struct BudgetCategoryRow: BackupRow {
        var id: UUID
        var name: String
        var monthlyLimit: Double
        var createdAt: Date

        init(_ m: BudgetCategory) {
            id = m.id; name = m.name; monthlyLimit = m.monthlyLimit; createdAt = m.createdAt
        }
        func make() -> BudgetCategory {
            BudgetCategory(id: id, name: name, monthlyLimit: monthlyLimit, createdAt: createdAt)
        }
        var sortKey: String { id.uuidString }
    }

    struct BudgetTransactionRow: BackupRow {
        var categoryID: UUID
        var amount: Double
        var note: String
        var date: Date

        init(_ m: BudgetTransaction) {
            categoryID = m.categoryID; amount = m.amount; note = m.note; date = m.date
        }
        func make() -> BudgetTransaction {
            BudgetTransaction(categoryID: categoryID, amount: amount, note: note, date: date)
        }
        var sortKey: String { "\(categoryID.uuidString)|\(date.timeIntervalSinceReferenceDate)|\(note)" }
    }

    struct RoutineRow: BackupRow {
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

        init(_ m: Routine) {
            id = m.id; name = m.name; exercises = m.exercises
            createdAt = m.createdAt; updatedAt = m.updatedAt
            isStarter = m.isStarter; starterKey = m.starterKey
            sportRaw = m.sportRaw; levelRaw = m.levelRaw
            tags = m.tags; detail = m.detail
            sourceLabel = m.sourceLabel; sourceURL = m.sourceURL
        }
        func make() -> Routine {
            let r = Routine(id: id, name: name, exercises: exercises,
                            createdAt: createdAt, updatedAt: updatedAt,
                            isStarter: isStarter, starterKey: starterKey,
                            tags: tags, detail: detail,
                            sourceLabel: sourceLabel, sourceURL: sourceURL)
            // Raw, not via the enum init: an unrecognized stored value must survive verbatim.
            r.sportRaw = sportRaw
            r.levelRaw = levelRaw
            return r
        }
        var sortKey: String { id.uuidString }
    }

    struct WorkoutSessionRow: BackupRow {
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

        init(_ m: WorkoutSession) {
            id = m.id; routineID = m.routineID; routineName = m.routineName
            startedAt = m.startedAt; completedAt = m.completedAt
            exercises = m.exercises; hrSeries = m.hrSeries
            maxHR = m.maxHR; restHR = m.restHR
            metricsSourceRaw = m.metricsSourceRaw; kcalEstimate = m.kcalEstimate
        }
        func make() -> WorkoutSession {
            WorkoutSession(id: id, routineID: routineID, routineName: routineName,
                           startedAt: startedAt, completedAt: completedAt, exercises: exercises,
                           hrSeries: hrSeries, maxHR: maxHR, restHR: restHR,
                           metricsSourceRaw: metricsSourceRaw, kcalEstimate: kcalEstimate)
        }
        var sortKey: String { id.uuidString }
    }

    struct CustomExerciseRow: BackupRow {
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

        init(_ m: CustomExercise) {
            id = m.id; name = m.name; categoryRaw = m.categoryRaw; levelRaw = m.levelRaw
            forceRaw = m.forceRaw; mechanicRaw = m.mechanicRaw; equipmentRaw = m.equipmentRaw
            primaryMuscles = m.primaryMuscles; secondaryMuscles = m.secondaryMuscles
            instructions = m.instructions; createdAt = m.createdAt
        }
        func make() -> CustomExercise {
            let c = CustomExercise(id: id, name: name, instructions: instructions, createdAt: createdAt)
            // The init takes typed enums; write the stored raws directly so nothing is laundered.
            c.categoryRaw = categoryRaw
            c.levelRaw = levelRaw
            c.forceRaw = forceRaw
            c.mechanicRaw = mechanicRaw
            c.equipmentRaw = equipmentRaw
            c.primaryMuscles = primaryMuscles
            c.secondaryMuscles = secondaryMuscles
            return c
        }
        var sortKey: String { id }
    }

    struct SessionMediaRow: BackupRow {
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

        init(_ m: SessionMedia) {
            id = m.id; sessionID = m.sessionID; localIdentifier = m.localIdentifier
            kindRaw = m.kindRaw; offsetSec = m.offsetSec; durationSec = m.durationSec
            addedManually = m.addedManually
            assignedExerciseID = m.assignedExerciseID; assignedSetIndex = m.assignedSetIndex
            assignmentSourceRaw = m.assignmentSourceRaw; assignedClimbUUID = m.assignedClimbUUID
            createdAt = m.createdAt
        }
        func make() -> SessionMedia {
            let media = SessionMedia(id: id, sessionID: sessionID, localIdentifier: localIdentifier,
                                     kind: .photo, offsetSec: offsetSec, durationSec: durationSec,
                                     addedManually: addedManually,
                                     assignedExerciseID: assignedExerciseID,
                                     assignedSetIndex: assignedSetIndex,
                                     assignedClimbUUID: assignedClimbUUID,
                                     createdAt: createdAt)
            media.kindRaw = kindRaw
            media.assignmentSourceRaw = assignmentSourceRaw
            return media
        }
        var sortKey: String { id.uuidString }
    }

    struct TimedExerciseCatalogRow: BackupRow {
        var id: UUID
        var name: String
        var categoryRaw: String
        var specData: Data?
        var createdAt: Date
        var lastUsedAt: Date?

        init(_ m: TimedExerciseCatalog) {
            id = m.id; name = m.name; categoryRaw = m.categoryRaw
            specData = m.specData; createdAt = m.createdAt; lastUsedAt = m.lastUsedAt
        }
        func make() -> TimedExerciseCatalog {
            let c = TimedExerciseCatalog(id: id, name: name, createdAt: createdAt, lastUsedAt: lastUsedAt)
            // Raw, not via the enum/spec init: stored bytes survive verbatim (the raws-stay-raw rule).
            c.categoryRaw = categoryRaw
            c.specData = specData
            return c
        }
        var sortKey: String { id.uuidString }
    }

    struct StudioProjectRow: BackupRow {
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

        init(_ m: StudioProject) {
            id = m.id; sessionID = m.sessionID; title = m.title
            aspectRaw = m.aspectRaw; backgroundRaw = m.backgroundRaw
            clips = m.clips; transitions = m.transitions
            overlays = m.overlays; audioTracks = m.audioTracks
            hrOverlay = m.hrOverlay; baseFrame = m.baseFrame
            createdAt = m.createdAt; updatedAt = m.updatedAt
        }
        func make() -> StudioProject {
            let p = StudioProject(id: id, sessionID: sessionID, title: title,
                                  clips: clips, transitions: transitions,
                                  overlays: overlays, audioTracks: audioTracks,
                                  hrOverlay: hrOverlay, baseFrame: baseFrame,
                                  createdAt: createdAt)
            p.aspectRaw = aspectRaw
            p.backgroundRaw = backgroundRaw
            p.updatedAt = updatedAt   // the init pins it to createdAt
            return p
        }
        var sortKey: String { id.uuidString }
    }

    struct TipCalculationRow: BackupRow {
        var bill: Double
        var tipPct: Double
        var people: Int
        var tipAmount: Double
        var total: Double
        var date: Date

        init(_ m: TipCalculation) {
            bill = m.bill; tipPct = m.tipPct; people = m.people
            tipAmount = m.tipAmount; total = m.total; date = m.date
        }
        func make() -> TipCalculation {
            TipCalculation(bill: bill, tipPct: tipPct, people: people,
                           tipAmount: tipAmount, total: total, date: date)
        }
        var sortKey: String { "\(date.timeIntervalSinceReferenceDate)|\(bill)|\(people)" }
    }

    struct KilterLogEntryRow: BackupRow {
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

        init(_ m: KilterLogEntry) {
            climbUUID = m.climbUUID; climbName = m.climbName; angle = m.angle
            difficulty = m.difficulty; gradeLabel = m.gradeLabel; statusRaw = m.statusRaw
            attempts = m.attempts; date = m.date; sessionId = m.sessionId
            startedAt = m.startedAt; endedAt = m.endedAt
            attemptTimestamps = m.attemptTimestamps; note = m.note
        }
        func make() -> KilterLogEntry {
            let entry = KilterLogEntry(climbUUID: climbUUID, climbName: climbName, angle: angle,
                                       difficulty: difficulty, gradeLabel: gradeLabel,
                                       status: .attempt, attempts: attempts, date: date,
                                       sessionId: sessionId, startedAt: startedAt, endedAt: endedAt,
                                       attemptTimestamps: attemptTimestamps, note: note)
            entry.statusRaw = statusRaw   // raw, not via the enum — survive unknown values
            return entry
        }
        var sortKey: String { "\(date.timeIntervalSinceReferenceDate)|\(climbUUID)|\(angle)" }
    }

    struct KilterSessionRow: BackupRow {
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

        init(_ m: KilterSession) {
            id = m.id; startedAt = m.startedAt; endedAt = m.endedAt
            angle = m.angle; source = m.source; hrSeries = m.hrSeries
            maxHR = m.maxHR; restHR = m.restHR
            metricsSourceRaw = m.metricsSourceRaw; kcalEstimate = m.kcalEstimate
        }
        func make() -> KilterSession {
            KilterSession(id: id, startedAt: startedAt, endedAt: endedAt, angle: angle,
                          source: source, hrSeries: hrSeries, maxHR: maxHR, restHR: restHR,
                          metricsSourceRaw: metricsSourceRaw, kcalEstimate: kcalEstimate)
        }
        var sortKey: String { id.uuidString }
    }

    struct KilterPlanRow: BackupRow {
        var id: UUID
        var createdAt: Date
        var angle: Int
        var layoutId: Int
        var workingDifficulty: Double?
        var workingGradeLabel: String?
        var title: String?
        var sessionId: UUID?
        var completedAt: Date?
        var optionsTargetCount: Int
        var optionsSendThreshold: Int
        var optionsPreferUnsent: Bool
        var optionsGradeOffset: Int
        var strategyRaw: String?
        var items: [KilterPlanItem]

        init(_ m: KilterPlan) {
            id = m.id; createdAt = m.createdAt; angle = m.angle; layoutId = m.layoutId
            workingDifficulty = m.workingDifficulty; workingGradeLabel = m.workingGradeLabel
            title = m.title; sessionId = m.sessionId; completedAt = m.completedAt
            optionsTargetCount = m.optionsTargetCount; optionsSendThreshold = m.optionsSendThreshold
            optionsPreferUnsent = m.optionsPreferUnsent; optionsGradeOffset = m.optionsGradeOffset
            strategyRaw = m.strategyRaw
            items = m.items
        }
        func make() -> KilterPlan {
            KilterPlan(id: id, createdAt: createdAt, angle: angle, layoutId: layoutId,
                       workingDifficulty: workingDifficulty, workingGradeLabel: workingGradeLabel,
                       title: title, sessionId: sessionId, completedAt: completedAt,
                       optionsTargetCount: optionsTargetCount, optionsSendThreshold: optionsSendThreshold,
                       optionsPreferUnsent: optionsPreferUnsent, optionsGradeOffset: optionsGradeOffset,
                       strategyRaw: strategyRaw, items: items)
        }
        var sortKey: String { id.uuidString }
    }

    struct KilterFavoriteRow: BackupRow {
        var climbUUID: String
        var addedAt: Date

        init(_ m: KilterFavorite) { climbUUID = m.climbUUID; addedAt = m.addedAt }
        func make() -> KilterFavorite { KilterFavorite(climbUUID: climbUUID, addedAt: addedAt) }
        var sortKey: String { climbUUID }
    }

    struct KilterCreatedClimbRow: BackupRow {
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

        init(_ m: KilterCreatedClimb) {
            uuid = m.uuid; name = m.name; setterUsername = m.setterUsername
            layoutId = m.layoutId; sizeId = m.sizeId; angle = m.angle; frames = m.frames
            edgeLeft = m.edgeLeft; edgeRight = m.edgeRight
            edgeBottom = m.edgeBottom; edgeTop = m.edgeTop
            isNoMatch = m.isNoMatch; predictedGrade = m.predictedGrade
            source = m.source; modelId = m.modelId; createdAt = m.createdAt
        }
        func make() -> KilterCreatedClimb {
            KilterCreatedClimb(uuid: uuid, name: name, setterUsername: setterUsername,
                               layoutId: layoutId, sizeId: sizeId, angle: angle, frames: frames,
                               edgeLeft: edgeLeft, edgeRight: edgeRight,
                               edgeBottom: edgeBottom, edgeTop: edgeTop,
                               isNoMatch: isNoMatch, predictedGrade: predictedGrade,
                               source: source, modelId: modelId, createdAt: createdAt)
        }
        var sortKey: String { uuid }
    }
}
