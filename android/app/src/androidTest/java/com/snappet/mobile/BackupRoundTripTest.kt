package com.snappet.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snappet.mobile.core.SnappetBackup
import com.snappet.mobile.core.SnappetBackupManager
import com.snappet.mobile.core.SnappetDatabase
import com.snappet.mobile.core.UsageRecord
import com.snappet.mobile.feature.habit.Habit
import com.snappet.mobile.feature.habit.HabitCompletion
import com.snappet.mobile.feature.journal.JournalEntry
import com.snappet.mobile.feature.pomodoro.PomodoroSession
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Issue #84's round-trip acceptance criterion: export → wipe → import → every module
 * reads identical data. Runs against an in-memory Room store on the device/emulator;
 * the JSON leg goes through the real codec so this covers exactly what a SAF file holds.
 */
@RunWith(AndroidJUnit4::class)
class BackupRoundTripTest {

    @Test
    fun exportWipeImportRestoresEveryModule() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val db = SnappetDatabase.buildInMemory(context)
        try {
            // Seed EVERY entity (all 19 — the AC says all module flows render identical
            // data), spanning the storage classes: text, ints, reals, bools, nulls.
            db.usageDao().insert(UsageRecord(module = "tip", action = "calc",
                summary = "Tipped", metric = 12.5, timestamp = 111))
            db.journalDao().insert(JournalEntry(title = "Morning", body = "Climbed.",
                tags = "climbing,trip", createdAt = 5, updatedAt = 6))
            db.pomodoroDao().insert(PomodoroSession(minutes = 25, completedAt = 7))
            db.habitDao().insertHabit(Habit(habitId = "h-1", name = "Stretch", createdAt = 1))
            db.habitDao().insertCompletion(HabitCompletion(habitId = "h-1", day = 2))
            db.tipDao().insert(com.snappet.mobile.feature.tip.TipCalculation(
                bill = 80.0, tipPct = 18.0, people = 2, tipAmount = 14.4, total = 94.4, createdAt = 8))
            db.expenseDao().insertGroup(com.snappet.mobile.feature.expense.ExpenseGroup(
                groupId = "g-1", name = "Trip", participantsRaw = "Alice,Bob", createdAt = 9))
            db.expenseDao().insertExpense(com.snappet.mobile.feature.expense.ExpenseRecord(
                groupId = "g-1", title = "Dinner", amount = 40.0, payer = "Alice",
                participantsRaw = "Alice,Bob", date = 10, isSettlement = false))
            db.budgetDao().insertCategory(com.snappet.mobile.feature.budget.BudgetCategory(
                categoryId = "c-1", name = "Food", monthlyLimit = 300.0, createdAt = 11))
            db.budgetDao().insertTransaction(com.snappet.mobile.feature.budget.BudgetTransaction(
                categoryId = "c-1", amount = 12.0, note = "lunch", date = 12))
            db.workoutDao().insertRoutine(com.snappet.mobile.feature.workout.WorkoutRoutine(
                routineId = "r-1", name = "Push day", createdAt = 13, updatedAt = 13))
            db.workoutDao().insertSession(com.snappet.mobile.feature.workout.WorkoutSession(
                routineId = "r-1", routineName = "Push day", startedAt = 14, finishedAt = 15))
            db.workoutDao().insertCustomExercise(com.snappet.mobile.feature.workout.WorkoutCustomExercise(
                exerciseId = "custom-x", name = "Pinch hang", createdAt = 16))
            db.kilterDao().insertLog(com.snappet.mobile.feature.kilter.KilterLogEntry(
                climbUuid = "k-1", climbName = "Crimp city", angle = 40, difficulty = 20.5,
                gradeLabel = "V5", status = "sent", attempts = 2, createdAt = 17, sessionId = "s-1"))
            db.kilterDao().insertSession(com.snappet.mobile.feature.kilter.KilterSession(
                id = "s-1", startedAt = 18, endedAt = 19, angle = 40, source = "manual",
                // P4 (v7) metadata columns — covers title/notes/layoutId across export→wipe→import.
                title = "Comp prep", notes = "Felt strong", layoutId = 1))
            db.kilterDao().addFavorite(com.snappet.mobile.feature.kilter.KilterFavorite(
                climbUuid = "k-1", addedAt = 20))
            // P5 (v7) new table — one lit-on-the-board event (the upsert dedupes per climb-per-session).
            db.kilterDao().upsertLitEvent(com.snappet.mobile.feature.kilter.KilterLitEvent(
                climbUuid = "k-1", climbName = "Crimp city", gradeLabel = "V5", angle = 40,
                layoutId = 1, sizeId = 7, litAt = 23, wasConnected = true, sessionId = "s-1"))
            db.kilterDao().upsertCreated(com.snappet.mobile.feature.kilter.KilterCreatedClimb(
                uuid = "created-1", name = "My proj", setterUsername = "me", layoutId = 1,
                sizeId = 7, angle = 40, frames = "p1r12p2r13", edgeLeft = 0, edgeRight = 10,
                edgeBottom = 0, edgeTop = 12, isNoMatch = false, predictedGrade = null,
                source = "manual", modelId = null, createdAt = 21))
            db.kilterDao().upsertPlan(com.snappet.mobile.feature.kilter.KilterPlanEntity(
                id = "plan-1", createdAt = 22, angle = 40, layoutId = 1, sessionId = "s-1",
                workingDifficulty = 20.5, workingGradeLabel = "V5", title = "Volume night",
                optionsTargetCount = 6, optionsPreferUnsent = false, optionsGradeOffset = 1,
                strategyRaw = "VOLUME",
                // Also exercises the JSON-in-a-TEXT-column itemsJson across the export→wipe→import leg.
                itemsJson = com.snappet.mobile.feature.kilter.KilterPlanItemsCodec.encode(listOf(
                    com.snappet.mobile.feature.kilter.KilterPlanItem(
                        id = "i-1", order = 0, goalRaw = "SEND", climbUuid = "k-1", climbName = "Crimp city",
                        setter = "me", gradeLabel = "V5", difficulty = 20.5, statusRaw = "SENT", completedAtMillis = 22)))))

            val manager = SnappetBackupManager(db)
            val exported = manager.exportPayload(nowMillis = 999)
            val json = SnappetBackup.encode(exported)        // the real SAF file content

            // Wipe: import an empty payload of the same schema version…
            val empty = exported.copy(tables = exported.tables.mapValues { emptyList() })
            manager.importPayload(empty)
            assertTrue(db.journalDao().allFlow().first().isEmpty())

            // …then restore from the JSON and compare what every module reads.
            manager.importPayload(SnappetBackup.decode(json))

            val journal = db.journalDao().allFlow().first()
            assertEquals(1, journal.size)
            assertEquals("Morning", journal[0].title)
            assertEquals(listOf("climbing", "trip"), journal[0].tagList)

            val pomodoro = db.pomodoroDao().allFlow().first()
            assertEquals(listOf(25), pomodoro.map { it.minutes })

            val habits = db.habitDao().habitsFlow().first()
            assertEquals(listOf("Stretch"), habits.map { it.name })

            // Every table round-tripped with its seeded row (none restored empty).
            for ((table, rows) in exported.tables) {
                assertTrue("table $table should have been seeded", rows.isNotEmpty())
            }

            // Re-export must equal the first export — proves import lost nothing,
            // across every entity and storage class.
            val reExported = manager.exportPayload(nowMillis = 999)
            assertEquals(exported.tables, reExported.tables)
        } finally {
            db.close()
        }
    }
}
