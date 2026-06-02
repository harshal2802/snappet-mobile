package com.snappet.mobile.core

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachMoney
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Receipt
import androidx.compose.material.icons.filled.Terrain
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.PieChart
import com.snappet.mobile.ui.theme.SnappetAccents

/**
 * The full suite. Two central edits wire in a mini-app (mirrors iOS): append its entry here
 * and add its `@Entity` types to [SnappetDatabase]. The App Library and the smoke test both
 * iterate this list. `content` is each feature's root composable.
 *
 * Each module's `tint` comes from [SnappetAccents.forModule] (the Pulse curated accent palette),
 * keyed by the module id below.
 */
object ModuleRegistry {
    val all: List<AppModule> = listOf(
        AppModule(
            id = "workout", title = "Workout Reels",
            subtitle = "HR-ranked highlight reels",
            icon = Icons.Filled.Movie, tint = SnappetAccents.forModule("workout"),
            category = ModuleCategory.FITNESS,
        ) { onExit -> com.snappet.mobile.feature.reel.ReelRoot(onExit) },
        AppModule(
            id = "workout-log", title = "Workout Tracker",
            subtitle = "Routines, sets & history",
            icon = Icons.Filled.FitnessCenter, tint = SnappetAccents.forModule("workout-log"),
            category = ModuleCategory.FITNESS,
        ) { onExit -> com.snappet.mobile.feature.workout.WorkoutRoot(onExit) },
        AppModule(
            id = "kilter", title = "Kilter Board",
            subtitle = "Browse & log board climbs",
            icon = Icons.Filled.Terrain, tint = Color(0xFFF76808),
            category = ModuleCategory.FITNESS,
        ) { onExit -> com.snappet.mobile.feature.kilter.KilterRoot(onExit) },
        AppModule(
            id = "pomodoro", title = "Pomodoro",
            subtitle = "Focus timer & history",
            icon = Icons.Filled.Timer, tint = SnappetAccents.forModule("pomodoro"),
            category = ModuleCategory.PRODUCTIVITY,
        ) { onExit -> com.snappet.mobile.feature.pomodoro.PomodoroRoot(onExit) },
        AppModule(
            id = "habit", title = "Habits",
            subtitle = "Streaks & completion",
            icon = Icons.Filled.CheckCircle, tint = SnappetAccents.forModule("habit"),
            category = ModuleCategory.PRODUCTIVITY,
        ) { onExit -> com.snappet.mobile.feature.habit.HabitRoot(onExit) },
        AppModule(
            id = "journal", title = "Journal",
            subtitle = "Tagged daily entries",
            icon = Icons.Filled.Book, tint = SnappetAccents.forModule("journal"),
            category = ModuleCategory.PRODUCTIVITY,
        ) { onExit -> com.snappet.mobile.feature.journal.JournalRoot(onExit) },
        AppModule(
            id = "tip", title = "Tip Calculator",
            subtitle = "Split & round up",
            icon = Icons.Filled.AttachMoney, tint = SnappetAccents.forModule("tip"),
            category = ModuleCategory.FINANCE,
        ) { onExit -> com.snappet.mobile.feature.tip.TipRoot(onExit) },
        AppModule(
            id = "expense", title = "Split Expenses",
            subtitle = "Groups & settle-up",
            icon = Icons.Filled.Receipt, tint = SnappetAccents.forModule("expense"),
            category = ModuleCategory.FINANCE,
        ) { onExit -> com.snappet.mobile.feature.expense.ExpenseRoot(onExit) },
        AppModule(
            id = "budget", title = "Budget",
            subtitle = "Categories & trends",
            icon = Icons.Filled.PieChart, tint = SnappetAccents.forModule("budget"),
            category = ModuleCategory.FINANCE,
        ) { onExit -> com.snappet.mobile.feature.budget.BudgetRoot(onExit) },
    )

    fun byId(id: String): AppModule? = all.firstOrNull { it.id == id }
}
