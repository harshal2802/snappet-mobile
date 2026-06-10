package com.snappet.mobile.core

import android.content.Context
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
import com.snappet.mobile.feature.kilter.KilterLogEntry
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
    ],
    version = 4,
    exportSchema = true,
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
                // No destructive fallback: a missing migration must fail loudly in
                // development, not silently erase the user's data in production.
                .build()

        /** Fresh, isolated in-memory store used by UI tests (mirrors iOS `-uiTestFreshStore`). */
        fun buildInMemory(context: Context): SnappetDatabase =
            Room.inMemoryDatabaseBuilder(context, SnappetDatabase::class.java)
                .allowMainThreadQueries()
                .build()
    }
}
