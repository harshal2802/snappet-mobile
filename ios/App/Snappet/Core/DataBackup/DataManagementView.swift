import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Suite-level data management sheet: full backup/restore + per-module text exports.
///
/// Presented from `WorkoutSettingsView`'s "Your data" section (and any module settings
/// that chooses to adopt it). All I/O is user-initiated — no data leaves the device
/// without an explicit tap on "Back up my data" or a module export button.
struct DataManagementView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app

    @State private var backupState: BackupState = .idle
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingRestoreConfirm = false
    @State private var pendingRestoreData: Data? = nil

    // Per-module export share sheet state
    @State private var shareItems: [Any] = []
    @State private var showingShareSheet = false

    var body: some View {
        Form {
            suiteBackupSection
            perModuleExportSection
            feedbackSection
            notesSection
        }
        .navigationTitle("Data Management")
        .navigationBarTitleDisplayMode(.large)
        .fileExporter(
            isPresented: $showingExporter,
            document: backupState.bundleData.map { SnappetBackupDocument(data: $0) },
            contentType: .json,
            defaultFilename: backupState.bundleFilename ?? "snappet-backup"
        ) { result in
            switch result {
            case .success:
                backupState = backupState.reset()
            case .failure(let error):
                backupState = backupState.failed(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                handleImport(url: url)
            case .failure(let error):
                backupState = backupState.failed(error.localizedDescription)
            }
        }
        .confirmationDialog(
            "Restore from backup?",
            isPresented: $showingRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let data = pendingRestoreData { performRestore(data: data) }
            }
            Button("Cancel", role: .cancel) { pendingRestoreData = nil }
        } message: {
            Text("This will replace all current data with the backup. This cannot be undone.")
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { backupState = .idle }
        } message: {
            if case .failed(let msg) = backupState { Text(msg) }
        }
    }

    // MARK: - Sections

    private var suiteBackupSection: some View {
        Section {
            Button {
                prepareBackup()
            } label: {
                Label("Back up my data", systemImage: "arrow.up.doc")
            }
            .disabled(backupState.isBusy)
            .accessibilityIdentifier("backupMyData")

            if case .restored(let count) = backupState {
                Label("\(count) records restored", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Button {
                showingImporter = true
            } label: {
                Label("Restore from backup", systemImage: "arrow.down.doc")
            }
            .disabled(backupState.isBusy)
            .accessibilityIdentifier("restoreFromBackup")

            if backupState.isBusy {
                ProgressView(backupState == .preparingBundle ? "Preparing…" : "Restoring…")
            }
        } header: {
            Text("Full backup")
        } footer: {
            Text("Backs up all your data to a JSON file in Files. Excludes video clips and studio projects (those reference media stored on this device only).")
        }
    }

    private var perModuleExportSection: some View {
        Section {
            Button {
                exportJournalMarkdown()
            } label: {
                Label("Export Journal", systemImage: "doc.text")
            }
            .disabled(backupState.isBusy)
            .accessibilityIdentifier("exportJournal")

            Button {
                exportExpenseCSV()
            } label: {
                Label("Export Expenses & Budget", systemImage: "tablecells")
            }
            .disabled(backupState.isBusy)
            .accessibilityIdentifier("exportExpenses")

            Button {
                exportWorkoutJSON()
            } label: {
                Label("Export Workout History", systemImage: "figure.strengthtraining.traditional")
            }
            .disabled(backupState.isBusy)
            .accessibilityIdentifier("exportWorkouts")
        } header: {
            Text("Export by module")
        } footer: {
            Text("Exports a single module to a readable file (Markdown, CSV, or JSON) via the share sheet.")
        }
    }

    private var feedbackSection: some View {
        Section {
            Button {
                exportFeedback()
            } label: {
                Label("Export highlight feedback", systemImage: "waveform.path.ecg")
            }
            .disabled(backupState.isBusy)
            .accessibilityIdentifier("exportFeedback")
        } header: {
            Text("AI training data")
        } footer: {
            Text("On-device highlight feedback recorded while reviewing reels. Exportable with your consent — stays on-device until you share it.")
        }
    }

    private var notesSection: some View {
        Section {
        } footer: {
            Text("All exports and backups are saved to Files or shared via the system share sheet. Nothing is transmitted over the network.")
        }
    }

    // MARK: - Backup

    private func prepareBackup() {
        backupState = backupState.beginningPreparation()
        Task { @MainActor in
            do {
                let bundle = try fetchBundle()
                let data = try SnappetExporter.bundleJSON(bundle)
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                let filename = "snappet-backup-\(df.string(from: .now))"
                backupState = backupState.bundleReady(data: data, filename: filename)
                showingExporter = true
            } catch {
                backupState = backupState.failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Restore

    private func handleImport(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            backupState = backupState.failed("Couldn't read the backup file.")
            return
        }
        pendingRestoreData = data
        showingRestoreConfirm = true
    }

    private func performRestore(data: Data) {
        backupState = backupState.beginningRestore()
        Task { @MainActor in
            do {
                let bundle = try SnappetRestorer.restoreBundle(from: data)
                let count = try applyBundle(bundle)
                backupState = backupState.restoreSucceeded(recordCount: count)
            } catch {
                backupState = backupState.failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Per-module exports

    private func exportJournalMarkdown() {
        Task { @MainActor in
            let entries = (try? context.fetch(FetchDescriptor<JournalEntry>())) ?? []
            let snaps = entries.map {
                JournalEntrySnapshot(title: $0.title, body: $0.body,
                                     createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                                     tags: $0.tags)
            }
            let md = SnappetExporter.journalMarkdown(snaps)
            shareText(md, filename: "snappet-journal.md")
        }
    }

    private func exportExpenseCSV() {
        Task { @MainActor in
            let groups = (try? context.fetch(FetchDescriptor<ExpenseGroup>())) ?? []
            let records = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []
            let groupSnaps = groups.map {
                ExpenseGroupSnapshot(id: $0.id, name: $0.name,
                                     participants: $0.participants, createdAt: $0.createdAt)
            }
            let recordSnaps = records.map { r -> ExpenseRecordSnapshot in
                let items = r.items.map {
                    ReceiptItemSnapshot(id: $0.id, name: $0.name,
                                        price: $0.price, assignees: $0.assignees)
                }
                return ExpenseRecordSnapshot(
                    groupID: r.groupID, title: r.title, amount: r.amount,
                    payer: r.payer, participants: r.participants, date: r.date,
                    isSettlement: r.isSettlement, items: items,
                    taxAmount: r.taxAmount, discountAmount: r.discountAmount)
            }

            let cats = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
            let txns = (try? context.fetch(FetchDescriptor<BudgetTransaction>())) ?? []
            let catSnaps = cats.map {
                BudgetCategorySnapshot(id: $0.id, name: $0.name,
                                        monthlyLimit: $0.monthlyLimit, createdAt: $0.createdAt)
            }
            let txnSnaps = txns.map {
                BudgetTransactionSnapshot(categoryID: $0.categoryID, amount: $0.amount,
                                           note: $0.note, date: $0.date)
            }

            let expCSV = SnappetExporter.expenseCSV(groups: groupSnaps, records: recordSnaps)
            let budCSV = SnappetExporter.budgetCSV(categories: catSnaps, transactions: txnSnaps)
            let combined = "# Expenses\n\n" + expCSV + "\n\n# Budget\n\n" + budCSV
            shareText(combined, filename: "snappet-finance.csv")
        }
    }

    private func exportWorkoutJSON() {
        Task { @MainActor in
            let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
            let snaps = sessions.map { workoutSessionSnapshot($0) }
            guard let data = try? SnappetExporter.workoutSessionsJSON(snaps) else { return }
            let str = String(data: data, encoding: .utf8) ?? ""
            shareText(str, filename: "snappet-workouts.json")
        }
    }

    private func exportFeedback() {
        Task { @MainActor in
            let events = app.feedback.exportAll()
            guard !events.isEmpty else {
                backupState = backupState.failed("No highlight feedback recorded yet.")
                return
            }
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            let lines = events.compactMap { try? enc.encode($0) }
                              .compactMap { String(data: $0, encoding: .utf8) }
                              .joined(separator: "\n")
            shareText(lines, filename: "snappet-highlight-feedback.jsonl")
        }
    }

    // MARK: - Bundle fetch (SwiftData → snapshots)

    @MainActor
    private func fetchBundle() throws -> SnappetBackupBundle {
        let usageRecords = try context.fetch(FetchDescriptor<UsageRecord>()).map {
            UsageRecordSnapshot(module: $0.module, action: $0.action,
                                summary: $0.summary, metric: $0.metric, timestamp: $0.timestamp)
        }
        let pomodoro = try context.fetch(FetchDescriptor<PomodoroSession>()).map {
            PomodoroSessionSnapshot(minutes: $0.minutes, completedAt: $0.completedAt)
        }
        let habits = try context.fetch(FetchDescriptor<Habit>()).map {
            HabitSnapshot(id: $0.id, name: $0.name, symbol: $0.symbol, createdAt: $0.createdAt)
        }
        let habitCompletions = try context.fetch(FetchDescriptor<HabitCompletion>()).map {
            HabitCompletionSnapshot(habitID: $0.habitID, day: $0.day)
        }
        let journalEntries = try context.fetch(FetchDescriptor<JournalEntry>()).map {
            JournalEntrySnapshot(title: $0.title, body: $0.body,
                                 createdAt: $0.createdAt, updatedAt: $0.updatedAt, tags: $0.tags)
        }
        let expenseGroups = try context.fetch(FetchDescriptor<ExpenseGroup>()).map {
            ExpenseGroupSnapshot(id: $0.id, name: $0.name,
                                 participants: $0.participants, createdAt: $0.createdAt)
        }
        let expenseRecords = try context.fetch(FetchDescriptor<ExpenseRecord>()).map { r -> ExpenseRecordSnapshot in
            let items = r.items.map {
                ReceiptItemSnapshot(id: $0.id, name: $0.name, price: $0.price, assignees: $0.assignees)
            }
            return ExpenseRecordSnapshot(
                groupID: r.groupID, title: r.title, amount: r.amount, payer: r.payer,
                participants: r.participants, date: r.date, isSettlement: r.isSettlement,
                items: items, taxAmount: r.taxAmount, discountAmount: r.discountAmount)
        }
        let budgetCategories = try context.fetch(FetchDescriptor<BudgetCategory>()).map {
            BudgetCategorySnapshot(id: $0.id, name: $0.name,
                                    monthlyLimit: $0.monthlyLimit, createdAt: $0.createdAt)
        }
        let budgetTransactions = try context.fetch(FetchDescriptor<BudgetTransaction>()).map {
            BudgetTransactionSnapshot(categoryID: $0.categoryID, amount: $0.amount,
                                       note: $0.note, date: $0.date)
        }
        let routines = try context.fetch(FetchDescriptor<Routine>()).map { r -> RoutineSnapshot in
            let exs = r.exercises.map {
                RoutineExerciseSnapshot(id: $0.id, exerciseId: $0.exerciseId, sets: $0.sets,
                                         reps: $0.reps, restSeconds: $0.restSeconds,
                                         weight: $0.weight, weightUnit: $0.weightUnit?.rawValue,
                                         notes: $0.notes, displayName: $0.displayName)
            }
            return RoutineSnapshot(id: r.id, name: r.name, exercises: exs,
                                    createdAt: r.createdAt, updatedAt: r.updatedAt,
                                    isStarter: r.isStarter, starterKey: r.starterKey,
                                    sportRaw: r.sportRaw, levelRaw: r.levelRaw,
                                    tags: r.tags, detail: r.detail,
                                    sourceLabel: r.sourceLabel, sourceURL: r.sourceURL)
        }
        let workoutSessions = try context.fetch(FetchDescriptor<WorkoutSession>()).map {
            workoutSessionSnapshot($0)
        }
        let customExercises = try context.fetch(FetchDescriptor<CustomExercise>()).map {
            CustomExerciseSnapshot(id: $0.id, name: $0.name, categoryRaw: $0.categoryRaw,
                                    levelRaw: $0.levelRaw, forceRaw: $0.forceRaw,
                                    mechanicRaw: $0.mechanicRaw, equipmentRaw: $0.equipmentRaw,
                                    primaryMuscles: $0.primaryMuscles,
                                    secondaryMuscles: $0.secondaryMuscles,
                                    instructions: $0.instructions, createdAt: $0.createdAt)
        }
        let tipCalculations = try context.fetch(FetchDescriptor<TipCalculation>()).map {
            TipCalculationSnapshot(bill: $0.bill, tipPct: $0.tipPct, people: $0.people,
                                    tipAmount: $0.tipAmount, total: $0.total, date: $0.date)
        }
        let kilterLogEntries = try context.fetch(FetchDescriptor<KilterLogEntry>()).map {
            KilterLogEntrySnapshot(climbUUID: $0.climbUUID, climbName: $0.climbName,
                                    angle: $0.angle, difficulty: $0.difficulty,
                                    gradeLabel: $0.gradeLabel, statusRaw: $0.statusRaw,
                                    attempts: $0.attempts, date: $0.date,
                                    sessionId: $0.sessionId, startedAt: $0.startedAt,
                                    endedAt: $0.endedAt,
                                    attemptTimestamps: $0.attemptTimestamps, note: $0.note)
        }
        let kilterSessions = try context.fetch(FetchDescriptor<KilterSession>()).map { s -> KilterSessionSnapshot in
            let hr = s.hrSeries.map { HRPointSnapshot(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
            return KilterSessionSnapshot(id: s.id, startedAt: s.startedAt, endedAt: s.endedAt,
                                          angle: s.angle, source: s.source, hrSeries: hr,
                                          maxHR: s.maxHR, restHR: s.restHR,
                                          metricsSourceRaw: s.metricsSourceRaw,
                                          kcalEstimate: s.kcalEstimate)
        }
        let kilterFavorites = try context.fetch(FetchDescriptor<KilterFavorite>()).map {
            KilterFavoriteSnapshot(climbUUID: $0.climbUUID, addedAt: $0.addedAt)
        }
        let kilterCreatedClimbs = try context.fetch(FetchDescriptor<KilterCreatedClimb>()).map {
            KilterCreatedClimbSnapshot(uuid: $0.uuid, name: $0.name,
                                        setterUsername: $0.setterUsername, layoutId: $0.layoutId,
                                        sizeId: $0.sizeId, angle: $0.angle, frames: $0.frames,
                                        edgeLeft: $0.edgeLeft, edgeRight: $0.edgeRight,
                                        edgeBottom: $0.edgeBottom, edgeTop: $0.edgeTop,
                                        isNoMatch: $0.isNoMatch, predictedGrade: $0.predictedGrade,
                                        source: $0.source, modelId: $0.modelId,
                                        createdAt: $0.createdAt)
        }

        return SnappetBackupBundle(
            schemaVersion: SnappetBackupBundle.currentSchemaVersion,
            exportedAt: .now,
            usageRecords: usageRecords,
            pomodoroSessions: pomodoro,
            habits: habits,
            habitCompletions: habitCompletions,
            journalEntries: journalEntries,
            expenseGroups: expenseGroups,
            expenseRecords: expenseRecords,
            budgetCategories: budgetCategories,
            budgetTransactions: budgetTransactions,
            routines: routines,
            workoutSessions: workoutSessions,
            customExercises: customExercises,
            tipCalculations: tipCalculations,
            kilterLogEntries: kilterLogEntries,
            kilterSessions: kilterSessions,
            kilterFavorites: kilterFavorites,
            kilterCreatedClimbs: kilterCreatedClimbs
        )
    }

    // MARK: - Bundle apply (snapshots → SwiftData)

    @MainActor
    @discardableResult
    private func applyBundle(_ bundle: SnappetBackupBundle) throws -> Int {
        // Delete existing rows for all included model types.
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
        try context.delete(model: TipCalculation.self)
        try context.delete(model: KilterLogEntry.self)
        try context.delete(model: KilterSession.self)
        try context.delete(model: KilterFavorite.self)
        try context.delete(model: KilterCreatedClimb.self)

        for s in bundle.usageRecords {
            context.insert(UsageRecord(module: s.module, action: s.action,
                                        summary: s.summary, metric: s.metric, timestamp: s.timestamp))
        }
        for s in bundle.pomodoroSessions {
            context.insert(PomodoroSession(minutes: s.minutes, completedAt: s.completedAt))
        }
        for s in bundle.habits {
            context.insert(Habit(id: s.id, name: s.name, symbol: s.symbol, createdAt: s.createdAt))
        }
        for s in bundle.habitCompletions {
            context.insert(HabitCompletion(habitID: s.habitID, day: s.day))
        }
        for s in bundle.journalEntries {
            context.insert(JournalEntry(title: s.title, body: s.body,
                                         createdAt: s.createdAt, updatedAt: s.updatedAt,
                                         tags: s.tags))
        }
        for s in bundle.expenseGroups {
            context.insert(ExpenseGroup(id: s.id, name: s.name,
                                         participants: s.participants, createdAt: s.createdAt))
        }
        for s in bundle.expenseRecords {
            let items = s.items.map {
                ReceiptItem(id: $0.id, name: $0.name, price: $0.price, assignees: $0.assignees)
            }
            context.insert(ExpenseRecord(groupID: s.groupID, title: s.title, amount: s.amount,
                                          payer: s.payer, participants: s.participants, date: s.date,
                                          isSettlement: s.isSettlement, items: items,
                                          taxAmount: s.taxAmount, discountAmount: s.discountAmount))
        }
        for s in bundle.budgetCategories {
            context.insert(BudgetCategory(id: s.id, name: s.name,
                                           monthlyLimit: s.monthlyLimit, createdAt: s.createdAt))
        }
        for s in bundle.budgetTransactions {
            context.insert(BudgetTransaction(categoryID: s.categoryID, amount: s.amount,
                                              note: s.note, date: s.date))
        }
        for s in bundle.routines {
            let exs = s.exercises.map {
                RoutineExercise(id: $0.id, exerciseId: $0.exerciseId, sets: $0.sets,
                                reps: $0.reps, restSeconds: $0.restSeconds,
                                weight: $0.weight,
                                weightUnit: $0.weightUnit.flatMap(WeightUnit.init),
                                notes: $0.notes, displayName: $0.displayName)
            }
            let r = Routine(id: s.id, name: s.name, exercises: exs,
                             createdAt: s.createdAt, updatedAt: s.updatedAt,
                             isStarter: s.isStarter, starterKey: s.starterKey,
                             sport: s.sportRaw.flatMap(SportTag.init),
                             level: s.levelRaw.flatMap(RoutineLevel.init),
                             tags: s.tags, detail: s.detail,
                             sourceLabel: s.sourceLabel, sourceURL: s.sourceURL)
            context.insert(r)
        }
        for s in bundle.workoutSessions {
            context.insert(workoutSessionModel(s))
        }
        for s in bundle.customExercises {
            let ce = CustomExercise(id: s.id, name: s.name,
                                     category: ExerciseCategory(rawValue: s.categoryRaw) ?? .strength,
                                     level: ExerciseLevel(rawValue: s.levelRaw) ?? .beginner,
                                     force: s.forceRaw.flatMap(Force.init),
                                     mechanic: s.mechanicRaw.flatMap(Mechanic.init),
                                     equipment: s.equipmentRaw.flatMap(Equipment.init),
                                     primaryMuscles: s.primaryMuscles.compactMap(Muscle.init),
                                     secondaryMuscles: s.secondaryMuscles.compactMap(Muscle.init),
                                     instructions: s.instructions, createdAt: s.createdAt)
            context.insert(ce)
        }
        for s in bundle.tipCalculations {
            context.insert(TipCalculation(bill: s.bill, tipPct: s.tipPct, people: s.people,
                                           tipAmount: s.tipAmount, total: s.total, date: s.date))
        }
        for s in bundle.kilterLogEntries {
            context.insert(KilterLogEntry(
                climbUUID: s.climbUUID, climbName: s.climbName, angle: s.angle,
                difficulty: s.difficulty, gradeLabel: s.gradeLabel,
                status: KilterAscentStatus(rawValue: s.statusRaw) ?? .attempt,
                attempts: s.attempts, date: s.date, sessionId: s.sessionId,
                startedAt: s.startedAt, endedAt: s.endedAt,
                attemptTimestamps: s.attemptTimestamps, note: s.note))
        }
        for s in bundle.kilterSessions {
            let hr = s.hrSeries.map { HRPoint(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
            let ks = KilterSession(id: s.id, startedAt: s.startedAt, endedAt: s.endedAt,
                                    angle: s.angle, source: s.source, hrSeries: hr,
                                    maxHR: s.maxHR, restHR: s.restHR,
                                    metricsSourceRaw: s.metricsSourceRaw,
                                    kcalEstimate: s.kcalEstimate)
            context.insert(ks)
        }
        for s in bundle.kilterFavorites {
            context.insert(KilterFavorite(climbUUID: s.climbUUID, addedAt: s.addedAt))
        }
        for s in bundle.kilterCreatedClimbs {
            context.insert(KilterCreatedClimb(
                uuid: s.uuid, name: s.name, setterUsername: s.setterUsername,
                layoutId: s.layoutId, sizeId: s.sizeId, angle: s.angle, frames: s.frames,
                edgeLeft: s.edgeLeft, edgeRight: s.edgeRight,
                edgeBottom: s.edgeBottom, edgeTop: s.edgeTop,
                isNoMatch: s.isNoMatch, predictedGrade: s.predictedGrade,
                source: s.source, modelId: s.modelId, createdAt: s.createdAt))
        }
        try context.save()
        return bundle.totalRecordCount
    }

    // MARK: - Model ↔ snapshot helpers

    private func workoutSessionSnapshot(_ ws: WorkoutSession) -> WorkoutSessionSnapshot {
        let exs = ws.exercises.map { e -> SessionExerciseSnapshot in
            let sets = e.sets.map {
                SetLogSnapshot(actualReps: $0.actualReps, actualWeight: $0.actualWeight,
                               weightUnit: $0.weightUnit?.rawValue, completedAt: $0.completedAt,
                               durationSec: $0.durationSec, climbGradeLabel: $0.climbGradeLabel,
                               climbStatusRaw: $0.climbStatusRaw, climbAttempts: $0.climbAttempts)
            }
            return SessionExerciseSnapshot(
                id: e.id, exerciseId: e.exerciseId, targetSets: e.targetSets,
                targetReps: e.targetReps, targetRestSeconds: e.targetRestSeconds,
                targetWeight: e.targetWeight, targetWeightUnit: e.targetWeightUnit?.rawValue,
                sets: sets, skipped: e.skipped, displayName: e.displayName, kindRaw: e.kindRaw)
        }
        let hr = ws.hrSeries.map { HRPointSnapshot(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
        return WorkoutSessionSnapshot(
            id: ws.id, routineID: ws.routineID, routineName: ws.routineName,
            startedAt: ws.startedAt, completedAt: ws.completedAt, exercises: exs,
            hrSeries: hr, maxHR: ws.maxHR, restHR: ws.restHR,
            metricsSourceRaw: ws.metricsSourceRaw, kcalEstimate: ws.kcalEstimate)
    }

    private func workoutSessionModel(_ s: WorkoutSessionSnapshot) -> WorkoutSession {
        let exs = s.exercises.map { e -> SessionExercise in
            let sets = e.sets.map {
                SetLog(actualReps: $0.actualReps, actualWeight: $0.actualWeight,
                       weightUnit: $0.weightUnit.flatMap(WeightUnit.init),
                       completedAt: $0.completedAt, durationSec: $0.durationSec,
                       climbGradeLabel: $0.climbGradeLabel, climbStatusRaw: $0.climbStatusRaw,
                       climbAttempts: $0.climbAttempts)
            }
            return SessionExercise(
                id: e.id, exerciseId: e.exerciseId, targetSets: e.targetSets,
                targetReps: e.targetReps, targetRestSeconds: e.targetRestSeconds,
                targetWeight: e.targetWeight,
                targetWeightUnit: e.targetWeightUnit.flatMap(WeightUnit.init),
                sets: sets, skipped: e.skipped, displayName: e.displayName, kindRaw: e.kindRaw)
        }
        let hr = s.hrSeries.map { HRPoint(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
        return WorkoutSession(
            id: s.id, routineID: s.routineID, routineName: s.routineName,
            startedAt: s.startedAt, completedAt: s.completedAt, exercises: exs,
            hrSeries: hr, maxHR: s.maxHR, restHR: s.restHR,
            metricsSourceRaw: s.metricsSourceRaw, kcalEstimate: s.kcalEstimate)
    }

    // MARK: - Share sheet helper

    private func shareText(_ text: String, filename: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? text.write(to: tmp, atomically: true, encoding: .utf8)
        shareItems = [tmp]
        showingShareSheet = true
    }

    // MARK: - Error binding

    private var errorBinding: Binding<Bool> {
        Binding(get: {
            if case .failed = backupState { return true }
            return false
        }, set: { _ in })
    }
}

// MARK: - FileDocument wrapper for .fileExporter

/// Thin `FileDocument` wrapper around a pre-serialized JSON `Data` blob so `.fileExporter`
/// can write it without re-encoding.
struct SnappetBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
