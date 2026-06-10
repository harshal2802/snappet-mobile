import CoreGraphics
import Foundation
import SwiftData

/// Platform service that fetches all `@Model` objects from the shared `ModelContext`, delegates
/// serialization/format conversion to the pure `SnappetBackupEngine`, and writes/reads the result
/// via the file system.
///
/// This is the only layer that imports `SwiftData` for backup/export. Everything below it
/// (`SnappetBackupEngine`, the DTO types) is platform-free and unit-testable.
@MainActor
final class SnappetDataService {

    // MARK: - Full-suite backup

    /// Serialize every model in the store to a versioned JSON blob ready for `fileExporter`.
    func backup(context: ModelContext) throws -> Data {
        let bundle = SnappetBackup(
            exportedAt: .now,
            usageRecords: fetch(UsageRecord.self, context: context).map(\.dto),
            pomodoroSessions: fetch(PomodoroSession.self, context: context).map(\.dto),
            habits: fetch(Habit.self, context: context).map(\.dto),
            habitCompletions: fetch(HabitCompletion.self, context: context).map(\.dto),
            journalEntries: fetch(JournalEntry.self, context: context).map(\.dto),
            expenseGroups: fetch(ExpenseGroup.self, context: context).map(\.dto),
            expenseRecords: fetch(ExpenseRecord.self, context: context).map(\.dto),
            budgetCategories: fetch(BudgetCategory.self, context: context).map(\.dto),
            budgetTransactions: fetch(BudgetTransaction.self, context: context).map(\.dto),
            routines: fetch(Routine.self, context: context).map(\.dto),
            workoutSessions: fetch(WorkoutSession.self, context: context).map(\.dto),
            customExercises: fetch(CustomExercise.self, context: context).map(\.dto),
            sessionMedia: fetch(SessionMedia.self, context: context).map(\.dto),
            clipEdits: fetch(ClipEdit.self, context: context).map(\.dto),
            studioProjects: fetch(StudioProject.self, context: context).map(\.dto),
            tipCalculations: fetch(TipCalculation.self, context: context).map(\.dto),
            kilterLogEntries: fetch(KilterLogEntry.self, context: context).map(\.dto),
            kilterSessions: fetch(KilterSession.self, context: context).map(\.dto),
            kilterFavorites: fetch(KilterFavorite.self, context: context).map(\.dto),
            kilterCreatedClimbs: fetch(KilterCreatedClimb.self, context: context).map(\.dto)
        )
        return try SnappetBackupEngine.serialize(bundle)
    }

    /// Restore a previously saved backup into `context`. Existing rows are **kept**; this is
    /// an additive import — duplicate detection is best-effort (UUID equality for typed models).
    func restore(_ data: Data, into context: ModelContext) throws {
        let bundle = try SnappetBackupEngine.deserialize(data)

        // For models without a stable UUID we always insert; for those with UUIDs we
        // skip rows that already exist in the store.
        let existingRoutineIDs = Set(fetch(Routine.self, context: context).map(\.id))
        let existingSessionIDs = Set(fetch(WorkoutSession.self, context: context).map(\.id))
        let existingHabitIDs   = Set(fetch(Habit.self, context: context).map(\.id))
        let existingGroupIDs   = Set(fetch(ExpenseGroup.self, context: context).map(\.id))
        let existingBudgetCatIDs = Set(fetch(BudgetCategory.self, context: context).map(\.id))
        let existingKilterSessionIDs = Set(fetch(KilterSession.self, context: context).map(\.id))
        let existingCreatedClimbUUIDs = Set(fetch(KilterCreatedClimb.self, context: context).map(\.uuid))
        let existingFavoriteUUIDs = Set(fetch(KilterFavorite.self, context: context).map(\.climbUUID))

        // Always-insert (no unique key / dedup not meaningful for these)
        for dto in bundle.usageRecords { context.insert(dto.model) }
        for dto in bundle.pomodoroSessions { context.insert(dto.model) }
        for dto in bundle.habitCompletions { context.insert(dto.model) }
        for dto in bundle.journalEntries { context.insert(dto.model) }
        for dto in bundle.expenseRecords { context.insert(dto.model) }
        for dto in bundle.budgetTransactions { context.insert(dto.model) }
        for dto in bundle.tipCalculations { context.insert(dto.model) }
        for dto in bundle.kilterLogEntries { context.insert(dto.model) }
        for dto in bundle.sessionMedia { context.insert(dto.model) }
        for dto in bundle.clipEdits { context.insert(dto.model) }
        for dto in bundle.studioProjects { context.insert(dto.model) }

        // Deduped by UUID
        for dto in bundle.habits where !existingHabitIDs.contains(dto.id) {
            context.insert(dto.model)
        }
        for dto in bundle.expenseGroups where !existingGroupIDs.contains(dto.id) {
            context.insert(dto.model)
        }
        for dto in bundle.budgetCategories where !existingBudgetCatIDs.contains(dto.id) {
            context.insert(dto.model)
        }
        for dto in bundle.routines where !existingRoutineIDs.contains(dto.id) {
            context.insert(dto.model)
        }
        for dto in bundle.workoutSessions where !existingSessionIDs.contains(dto.id) {
            context.insert(dto.model)
        }
        for dto in bundle.customExercises {
            // CustomExercise.id is a prefixed String
            context.insert(dto.model)
        }
        for dto in bundle.kilterSessions where !existingKilterSessionIDs.contains(dto.id) {
            context.insert(dto.model)
        }
        for dto in bundle.kilterFavorites where !existingFavoriteUUIDs.contains(dto.climbUUID) {
            context.insert(dto.model)
        }
        for dto in bundle.kilterCreatedClimbs where !existingCreatedClimbUUIDs.contains(dto.uuid) {
            context.insert(dto.model)
        }

        try context.save()
    }

    // MARK: - Per-module exports

    func exportJournalMarkdown(context: ModelContext) -> String {
        let entries = fetch(JournalEntry.self, context: context).map(\.dto)
        return SnappetBackupEngine.journalMarkdown(entries)
    }

    func exportBudgetCSV(context: ModelContext) -> String {
        let cats = fetch(BudgetCategory.self, context: context).map(\.dto)
        let txns = fetch(BudgetTransaction.self, context: context).map(\.dto)
        return SnappetBackupEngine.budgetCSV(categories: cats, transactions: txns)
    }

    func exportExpenseCSV(context: ModelContext) -> String {
        let groups = fetch(ExpenseGroup.self, context: context).map(\.dto)
        let records = fetch(ExpenseRecord.self, context: context).map(\.dto)
        return SnappetBackupEngine.expenseCSV(groups: groups, records: records)
    }

    func exportWorkoutHistoryJSON(context: ModelContext) throws -> Data {
        let sessions = fetch(WorkoutSession.self, context: context).map(\.dto)
        return try SnappetBackupEngine.workoutHistoryJSON(sessions)
    }

    // MARK: - Private helpers

    private func fetch<T: PersistentModel>(_ type: T.Type, context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }
}

// MARK: - DTO adapters (model → DTO and DTO → model)

// These extensions live here (in the service layer) so the DTOs themselves stay platform-free
// (no SwiftData import) and `SnappetBackupEngine` stays testable without a device.

extension UsageRecord {
    var dto: UsageRecordDTO { UsageRecordDTO(module: module, action: action, summary: summary, metric: metric, timestamp: timestamp) }
}
extension UsageRecordDTO {
    var model: UsageRecord { UsageRecord(module: module, action: action, summary: summary, metric: metric, timestamp: timestamp) }
}

extension PomodoroSession {
    var dto: PomodoroSessionDTO { PomodoroSessionDTO(minutes: minutes, completedAt: completedAt) }
}
extension PomodoroSessionDTO {
    var model: PomodoroSession { PomodoroSession(minutes: minutes, completedAt: completedAt) }
}

extension Habit {
    var dto: HabitDTO { HabitDTO(id: id, name: name, symbol: symbol, createdAt: createdAt) }
}
extension HabitDTO {
    var model: Habit { Habit(id: id, name: name, symbol: symbol, createdAt: createdAt) }
}

extension HabitCompletion {
    var dto: HabitCompletionDTO { HabitCompletionDTO(habitID: habitID, day: day) }
}
extension HabitCompletionDTO {
    var model: HabitCompletion { HabitCompletion(habitID: habitID, day: day) }
}

extension JournalEntry {
    var dto: JournalEntryDTO { JournalEntryDTO(title: title, body: body, createdAt: createdAt, updatedAt: updatedAt, tags: tags) }
}
extension JournalEntryDTO {
    var model: JournalEntry { JournalEntry(title: title, body: body, createdAt: createdAt, updatedAt: updatedAt, tags: tags) }
}

extension ExpenseGroup {
    var dto: ExpenseGroupDTO { ExpenseGroupDTO(id: id, name: name, participants: participants, createdAt: createdAt) }
}
extension ExpenseGroupDTO {
    var model: ExpenseGroup { ExpenseGroup(id: id, name: name, participants: participants, createdAt: createdAt) }
}

extension ReceiptItem {
    var dto: ReceiptItemDTO { ReceiptItemDTO(id: id, name: name, price: price, assignees: assignees) }
}

extension ExpenseRecord {
    var dto: ExpenseRecordDTO {
        ExpenseRecordDTO(
            groupID: groupID, title: title, amount: amount, payer: payer,
            participants: participants, date: date, isSettlement: isSettlement,
            items: items.map(\.dto), taxAmount: taxAmount, discountAmount: discountAmount
        )
    }
}
extension ExpenseRecordDTO {
    var model: ExpenseRecord {
        ExpenseRecord(
            groupID: groupID, title: title, amount: amount, payer: payer,
            participants: participants, date: date, isSettlement: isSettlement,
            items: items.map { ReceiptItem(id: $0.id, name: $0.name, price: $0.price, assignees: $0.assignees) },
            taxAmount: taxAmount, discountAmount: discountAmount
        )
    }
}

extension BudgetCategory {
    var dto: BudgetCategoryDTO { BudgetCategoryDTO(id: id, name: name, monthlyLimit: monthlyLimit, createdAt: createdAt) }
}
extension BudgetCategoryDTO {
    var model: BudgetCategory { BudgetCategory(id: id, name: name, monthlyLimit: monthlyLimit, createdAt: createdAt) }
}

extension BudgetTransaction {
    var dto: BudgetTransactionDTO { BudgetTransactionDTO(categoryID: categoryID, amount: amount, note: note, date: date) }
}
extension BudgetTransactionDTO {
    var model: BudgetTransaction { BudgetTransaction(categoryID: categoryID, amount: amount, note: note, date: date) }
}

extension RoutineExercise {
    var dto: RoutineExerciseDTO {
        RoutineExerciseDTO(id: id, exerciseId: exerciseId, sets: sets, reps: reps, restSeconds: restSeconds,
                           weight: weight, weightUnit: weightUnit?.rawValue, notes: notes, displayName: displayName)
    }
}

extension Routine {
    var dto: RoutineDTO {
        RoutineDTO(id: id, name: name, exercises: exercises.map(\.dto), createdAt: createdAt, updatedAt: updatedAt,
                   isStarter: isStarter, starterKey: starterKey, sportRaw: sportRaw, levelRaw: levelRaw,
                   tags: tags, detail: detail, sourceLabel: sourceLabel, sourceURL: sourceURL)
    }
}
extension RoutineDTO {
    var model: Routine {
        let r = Routine(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt,
                        isStarter: isStarter, starterKey: starterKey, tags: tags, detail: detail,
                        sourceLabel: sourceLabel, sourceURL: sourceURL)
        r.sportRaw = sportRaw
        r.levelRaw = levelRaw
        r.exercises = exercises.map { d in
            RoutineExercise(id: d.id, exerciseId: d.exerciseId, sets: d.sets, reps: d.reps,
                            restSeconds: d.restSeconds, weight: d.weight,
                            weightUnit: d.weightUnit.flatMap(WeightUnit.init),
                            notes: d.notes, displayName: d.displayName)
        }
        return r
    }
}

extension SetLog {
    var dto: SetLogDTO {
        SetLogDTO(actualReps: actualReps, actualWeight: actualWeight, weightUnit: weightUnit?.rawValue,
                  completedAt: completedAt, durationSec: durationSec, climbGradeLabel: climbGradeLabel,
                  climbStatusRaw: climbStatusRaw, climbAttempts: climbAttempts)
    }
}

extension SessionExercise {
    var dto: SessionExerciseDTO {
        SessionExerciseDTO(id: id, exerciseId: exerciseId, targetSets: targetSets, targetReps: targetReps,
                           targetRestSeconds: targetRestSeconds, targetWeight: targetWeight,
                           targetWeightUnit: targetWeightUnit?.rawValue, sets: sets.map(\.dto),
                           skipped: skipped, displayName: displayName, kindRaw: kindRaw)
    }
}

extension HRPoint {
    var dto: HRPointDTO { HRPointDTO(t: t, bpm: bpm, rrIntervalsMs: rrIntervalsMs) }
}

extension WorkoutSession {
    var dto: WorkoutSessionDTO {
        WorkoutSessionDTO(id: id, routineID: routineID, routineName: routineName, startedAt: startedAt,
                          completedAt: completedAt, exercises: exercises.map(\.dto),
                          hrSeries: hrSeries.map(\.dto), maxHR: maxHR, restHR: restHR,
                          metricsSourceRaw: metricsSourceRaw, kcalEstimate: kcalEstimate)
    }
}
extension WorkoutSessionDTO {
    var model: WorkoutSession {
        WorkoutSession(id: id, routineID: routineID, routineName: routineName, startedAt: startedAt,
                       completedAt: completedAt,
                       exercises: exercises.map { d in
                           SessionExercise(
                               id: d.id, exerciseId: d.exerciseId, targetSets: d.targetSets,
                               targetReps: d.targetReps, targetRestSeconds: d.targetRestSeconds,
                               targetWeight: d.targetWeight,
                               targetWeightUnit: d.targetWeightUnit.flatMap(WeightUnit.init),
                               sets: d.sets.map { s in
                                   SetLog(actualReps: s.actualReps, actualWeight: s.actualWeight,
                                          weightUnit: s.weightUnit.flatMap(WeightUnit.init),
                                          completedAt: s.completedAt, durationSec: s.durationSec,
                                          climbGradeLabel: s.climbGradeLabel,
                                          climbStatusRaw: s.climbStatusRaw,
                                          climbAttempts: s.climbAttempts)
                               },
                               skipped: d.skipped, displayName: d.displayName, kindRaw: d.kindRaw)
                       },
                       hrSeries: hrSeries.map { HRPoint(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) },
                       maxHR: maxHR, restHR: restHR, metricsSourceRaw: metricsSourceRaw, kcalEstimate: kcalEstimate)
    }
}

extension CustomExercise {
    var dto: CustomExerciseDTO {
        CustomExerciseDTO(id: id, name: name, categoryRaw: categoryRaw, levelRaw: levelRaw,
                          forceRaw: forceRaw, mechanicRaw: mechanicRaw, equipmentRaw: equipmentRaw,
                          primaryMuscles: primaryMuscles, secondaryMuscles: secondaryMuscles,
                          instructions: instructions, createdAt: createdAt)
    }
}
extension CustomExerciseDTO {
    var model: CustomExercise {
        CustomExercise(id: id, name: name,
                       category: ExerciseCategory(rawValue: categoryRaw) ?? .strength,
                       level: ExerciseLevel(rawValue: levelRaw) ?? .beginner,
                       force: forceRaw.flatMap(Force.init),
                       mechanic: mechanicRaw.flatMap(Mechanic.init),
                       equipment: equipmentRaw.flatMap(Equipment.init),
                       primaryMuscles: primaryMuscles.compactMap(Muscle.init),
                       secondaryMuscles: secondaryMuscles.compactMap(Muscle.init),
                       instructions: instructions, createdAt: createdAt)
    }
}

extension SessionMedia {
    var dto: SessionMediaDTO {
        SessionMediaDTO(id: id, sessionID: sessionID, localIdentifier: localIdentifier, kindRaw: kindRaw,
                        offsetSec: offsetSec, durationSec: durationSec, addedManually: addedManually,
                        assignedExerciseID: assignedExerciseID, assignedSetIndex: assignedSetIndex,
                        assignmentSourceRaw: assignmentSourceRaw, assignedClimbUUID: assignedClimbUUID,
                        createdAt: createdAt)
    }
}
extension SessionMediaDTO {
    var model: SessionMedia {
        SessionMedia(id: id, sessionID: sessionID, localIdentifier: localIdentifier,
                     kind: SessionMedia.Kind(rawValue: kindRaw) ?? .video,
                     offsetSec: offsetSec, durationSec: durationSec, addedManually: addedManually,
                     assignedExerciseID: assignedExerciseID, assignedSetIndex: assignedSetIndex,
                     assignedClimbUUID: assignedClimbUUID,
                     source: MediaAssignmentSource(rawValue: assignmentSourceRaw) ?? .auto,
                     createdAt: createdAt)
    }
}

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

extension ClipEdit {
    var dto: ClipEditDTO {
        ClipEditDTO(
            id: id, sessionMediaID: sessionMediaID, localIdentifier: localIdentifier,
            trimStart: trimStart, trimEnd: trimEnd, splitOrder: splitOrder,
            cropX: cropX, cropY: cropY, cropWidth: cropWidth, cropHeight: cropHeight,
            aspectRaw: aspectRaw, speed: speed,
            textOverlaysJSON: (try? encoder.encode(textOverlays)) ?? Data(),
            mutedOriginalAudio: mutedOriginalAudio, musicTrackName: musicTrackName,
            hrOverlayJSON: try? encoder.encode(hrOverlay),
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
extension ClipEditDTO {
    var model: ClipEdit {
        let textOverlays = (try? decoder.decode([TextOverlay].self, from: textOverlaysJSON)) ?? []
        let hrOverlay = hrOverlayJSON.flatMap { try? decoder.decode(HROverlayConfig.self, from: $0) }
        let clip = ClipEdit(
            id: id, sessionMediaID: sessionMediaID, localIdentifier: localIdentifier,
            trimStart: trimStart, trimEnd: trimEnd, splitOrder: splitOrder,
            cropRect: CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight),
            aspect: ClipEditGeometry.OutputAspect(rawValue: aspectRaw) ?? .portrait9x16,
            speed: speed, textOverlays: textOverlays,
            mutedOriginalAudio: mutedOriginalAudio, musicTrackName: musicTrackName,
            hrOverlay: hrOverlay, createdAt: createdAt
        )
        clip.updatedAt = updatedAt
        return clip
    }
}

extension StudioProject {
    var dto: StudioProjectDTO {
        StudioProjectDTO(
            id: id, sessionID: sessionID, title: title, aspectRaw: aspectRaw, backgroundRaw: backgroundRaw,
            clipsJSON: (try? encoder.encode(clips)) ?? Data(),
            transitionsJSON: (try? encoder.encode(transitions)) ?? Data(),
            overlaysJSON: (try? encoder.encode(overlays)) ?? Data(),
            audioTracksJSON: (try? encoder.encode(audioTracks)) ?? Data(),
            hrOverlayJSON: try? encoder.encode(hrOverlay),
            baseFrameJSON: try? encoder.encode(baseFrame),
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
extension StudioProjectDTO {
    var model: StudioProject {
        let clips = (try? decoder.decode([TimelineClip].self, from: clipsJSON)) ?? []
        let transitions = (try? decoder.decode([StudioTransition].self, from: transitionsJSON)) ?? []
        let overlays = (try? decoder.decode([OverlayItem].self, from: overlaysJSON)) ?? []
        let audioTracks = (try? decoder.decode([AudioTrack].self, from: audioTracksJSON)) ?? []
        let hrOverlay = hrOverlayJSON.flatMap { try? decoder.decode(HROverlayConfig.self, from: $0) }
        let baseFrame = baseFrameJSON.flatMap { try? decoder.decode(StudioFrameRect.self, from: $0) }
        let p = StudioProject(id: id, sessionID: sessionID, title: title,
                              aspect: ClipEditGeometry.OutputAspect(rawValue: aspectRaw) ?? .portrait9x16,
                              background: StudioBackground(rawValue: backgroundRaw) ?? .black,
                              clips: clips, transitions: transitions, overlays: overlays,
                              audioTracks: audioTracks, hrOverlay: hrOverlay, baseFrame: baseFrame,
                              createdAt: createdAt)
        p.updatedAt = updatedAt
        return p
    }
}

extension TipCalculation {
    var dto: TipCalculationDTO {
        TipCalculationDTO(bill: bill, tipPct: tipPct, people: people, tipAmount: tipAmount, total: total, date: date)
    }
}
extension TipCalculationDTO {
    var model: TipCalculation {
        TipCalculation(bill: bill, tipPct: tipPct, people: people, tipAmount: tipAmount, total: total, date: date)
    }
}

extension KilterLogEntry {
    var dto: KilterLogEntryDTO {
        KilterLogEntryDTO(climbUUID: climbUUID, climbName: climbName, angle: angle, difficulty: difficulty,
                          gradeLabel: gradeLabel, statusRaw: statusRaw, attempts: attempts, date: date,
                          sessionId: sessionId, startedAt: startedAt, endedAt: endedAt,
                          attemptTimestamps: attemptTimestamps, note: note)
    }
}
extension KilterLogEntryDTO {
    var model: KilterLogEntry {
        KilterLogEntry(climbUUID: climbUUID, climbName: climbName, angle: angle, difficulty: difficulty,
                       gradeLabel: gradeLabel,
                       status: KilterAscentStatus(rawValue: statusRaw) ?? .attempt,
                       attempts: attempts, date: date, sessionId: sessionId,
                       startedAt: startedAt, endedAt: endedAt,
                       attemptTimestamps: attemptTimestamps, note: note)
    }
}

extension KilterSession {
    var dto: KilterSessionDTO {
        KilterSessionDTO(id: id, startedAt: startedAt, endedAt: endedAt, angle: angle, source: source,
                         hrSeries: hrSeries.map(\.dto), maxHR: maxHR, restHR: restHR,
                         metricsSourceRaw: metricsSourceRaw, kcalEstimate: kcalEstimate)
    }
}
extension KilterSessionDTO {
    var model: KilterSession {
        KilterSession(id: id, startedAt: startedAt, endedAt: endedAt, angle: angle, source: source,
                      hrSeries: hrSeries.map { HRPoint(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) },
                      maxHR: maxHR, restHR: restHR, metricsSourceRaw: metricsSourceRaw, kcalEstimate: kcalEstimate)
    }
}

extension KilterFavorite {
    var dto: KilterFavoriteDTO { KilterFavoriteDTO(climbUUID: climbUUID, addedAt: addedAt) }
}
extension KilterFavoriteDTO {
    var model: KilterFavorite { KilterFavorite(climbUUID: climbUUID, addedAt: addedAt) }
}

extension KilterCreatedClimb {
    var dto: KilterCreatedClimbDTO {
        KilterCreatedClimbDTO(uuid: uuid, name: name, setterUsername: setterUsername, layoutId: layoutId,
                              sizeId: sizeId, angle: angle, frames: frames,
                              edgeLeft: edgeLeft, edgeRight: edgeRight, edgeBottom: edgeBottom, edgeTop: edgeTop,
                              isNoMatch: isNoMatch, predictedGrade: predictedGrade, source: source,
                              modelId: modelId, createdAt: createdAt)
    }
}
extension KilterCreatedClimbDTO {
    var model: KilterCreatedClimb {
        KilterCreatedClimb(uuid: uuid, name: name, setterUsername: setterUsername, layoutId: layoutId,
                           sizeId: sizeId, angle: angle, frames: frames,
                           edgeLeft: edgeLeft, edgeRight: edgeRight, edgeBottom: edgeBottom, edgeTop: edgeTop,
                           isNoMatch: isNoMatch, predictedGrade: predictedGrade, source: source,
                           modelId: modelId, createdAt: createdAt)
    }
}
