package com.snappet.mobile.core

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.snappet.mobile.feature.budget.BudgetCategory
import com.snappet.mobile.feature.budget.BudgetDao
import com.snappet.mobile.feature.budget.BudgetTransaction
import com.snappet.mobile.feature.expense.ExpenseDao
import com.snappet.mobile.feature.expense.ExpenseGroup
import com.snappet.mobile.feature.expense.ExpenseRecord
import com.snappet.mobile.feature.habit.Habit
import com.snappet.mobile.feature.habit.HabitCompletion
import com.snappet.mobile.feature.habit.HabitDao
import com.snappet.mobile.feature.journal.JournalDao
import com.snappet.mobile.feature.journal.JournalEntry
import com.snappet.mobile.feature.kilter.KilterCreatedClimb
import com.snappet.mobile.feature.kilter.KilterDao
import com.snappet.mobile.feature.kilter.KilterFavorite
import com.snappet.mobile.feature.kilter.KilterLitEvent
import com.snappet.mobile.feature.kilter.KilterLogEntry
import com.snappet.mobile.feature.kilter.KilterPlanEntity
import com.snappet.mobile.feature.kilter.KilterSession
import com.snappet.mobile.feature.pomodoro.PomodoroDao
import com.snappet.mobile.feature.pomodoro.PomodoroSession
import com.snappet.mobile.feature.tip.TipCalculation
import com.snappet.mobile.feature.tip.TipDao
import com.snappet.mobile.feature.workout.WorkoutCustomExercise
import com.snappet.mobile.feature.workout.WorkoutDao
import com.snappet.mobile.feature.workout.WorkoutRoutine
import com.snappet.mobile.feature.workout.WorkoutSession

/**
 * The single shared on-device store (Room). Mini-apps that need their own history add
 * their `@Entity` types to this list and an accessor below — one central place so the
 * container schema stays consistent (mirrors the iOS `SnappetSchema.models`). Keep
 * `UsageRecord` first.
 *
 * **Schema changes are MIGRATIONS now, never wipes** (issue #84): `exportSchema = true`
 * commits each version's JSON to `app/schemas/`, and the next version bump must ship an
 * `autoMigrations` entry (or a hand-written `Migration`) — the old
 * `fallbackToDestructiveMigration()` silently destroyed every module's history on any
 * version bump and is gone from the build path entirely.
 */
@Database(
    entities = [
        UsageRecord::class,
        PomodoroSession::class,
        Habit::class, HabitCompletion::class,
        JournalEntry::class,
        TipCalculation::class,
        ExpenseGroup::class, ExpenseRecord::class,
        BudgetCategory::class, BudgetTransaction::class,
        WorkoutRoutine::class, WorkoutSession::class, WorkoutCustomExercise::class,
        KilterLogEntry::class, KilterSession::class, KilterFavorite::class, KilterCreatedClimb::class,
        KilterPlanEntity::class, KilterLitEvent::class,
    ],
    version = 7,
    exportSchema = true,
    // ── v4 → v5 (issue #92): three NULLABLE HR columns added to `kilter_session`
    //    (avgHr, maxHr, hrSampleCount). Purely additive → a no-SQL Room AutoMigration; no existing
    //    row is touched and nothing can be lost. This is ONE self-contained column-set so the
    //    reviewer can trivially renumber it to v5→v6 when reconciling with Wave 2's independent v5
    //    bump (workout columns) at merge time — see the comment on KilterSession.
    // v5 → v6 (Kilter planned-session): one additive table `kilter_plan` (KilterPlanEntity) — a no-SQL
    // Room AutoMigration; no existing row is touched and nothing can be lost.
    // v6 → v7 (Kilter Wave B P4+P5): BOTH additive in ONE migration — three NULLABLE columns on
    //    `kilter_session` (title, notes, layoutId) AND a new additive table `kilter_lit_event`
    //    (KilterLitEvent). Both are pure additions → a single no-SQL Room AutoMigration covers them;
    //    no existing row is touched and nothing can be lost.
    autoMigrations = [
        AutoMigration(from = 4, to = 5),
        AutoMigration(from = 5, to = 6),
        AutoMigration(from = 6, to = 7),
    ],
)
abstract class SnappetDatabase : RoomDatabase() {
    abstract fun usageDao(): UsageDao
    abstract fun pomodoroDao(): PomodoroDao
    abstract fun habitDao(): HabitDao
    abstract fun journalDao(): JournalDao
    abstract fun tipDao(): TipDao
    abstract fun expenseDao(): ExpenseDao
    abstract fun budgetDao(): BudgetDao
    abstract fun workoutDao(): WorkoutDao
    abstract fun kilterDao(): KilterDao

    companion object {
        fun build(context: Context): SnappetDatabase =
            Room.databaseBuilder(context, SnappetDatabase::class.java, "snappet.db")
                // No destructive fallback FROM v4 ONWARD: a missing migration must fail
                // loudly in development, not silently erase user data in production.
                // Pre-baseline versions (1–3) keep the old wipe-on-upgrade behavior —
                // their schemas were never exported, so correct migrations can't be
                // authored retroactively, and a crash loop would brick those installs.
                .fallbackToDestructiveMigrationFrom(1, 2, 3)
                .build()

        /** Fresh, isolated in-memory store used by UI tests (mirrors iOS `-uiTestFreshStore`). */
        fun buildInMemory(context: Context): SnappetDatabase =
            Room.inMemoryDatabaseBuilder(context, SnappetDatabase::class.java)
                .allowMainThreadQueries()
                .build()
    }
}
