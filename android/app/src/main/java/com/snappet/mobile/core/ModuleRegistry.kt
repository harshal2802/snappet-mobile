package com.snappet.mobile.core

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachMoney
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Receipt
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.PieChart
import androidx.compose.ui.graphics.Color

/**
 * The full suite. Two central edits wire in a mini-app (mirrors iOS): append its entry here
 * and add its `@Entity` types to [SnappetDatabase]. The App Library and the smoke test both
 * iterate this list. `content` is each feature's root composable.
 */
object ModuleRegistry {
    val all: List<AppModule> = listOf(
        AppModule(
            id = "workout", title = "Workout Reels",
            subtitle = "HR-ranked highlight reels",
            icon = Icons.Filled.Movie, tint = Color(0xFFE5484D),
            category = ModuleCategory.FITNESS,
        ) { onExit -> com.snappet.mobile.feature.reel.ReelRoot(onExit) },
        AppModule(
            id = "workout-log", title = "Workout Tracker",
            subtitle = "Routines, sets & history",
            icon = Icons.Filled.FitnessCenter, tint = Color(0xFFF76808),
            category = ModuleCategory.FITNESS,
        ) { onExit -> com.snappet.mobile.feature.workout.WorkoutRoot(onExit) },
        AppModule(
            id = "pomodoro", title = "Pomodoro",
            subtitle = "Focus timer & history",
            icon = Icons.Filled.Timer, tint = Color(0xFFE5484D),
            category = ModuleCategory.PRODUCTIVITY,
        ) { onExit -> com.snappet.mobile.feature.pomodoro.PomodoroRoot(onExit) },
        AppModule(
            id = "habit", title = "Habits",
            subtitle = "Streaks & completion",
            icon = Icons.Filled.CheckCircle, tint = Color(0xFF30A46C),
            category = ModuleCategory.PRODUCTIVITY,
        ) { onExit -> com.snappet.mobile.feature.habit.HabitRoot(onExit) },
        AppModule(
            id = "journal", title = "Journal",
            subtitle = "Tagged daily entries",
            icon = Icons.Filled.Book, tint = Color(0xFF8E4EC6),
            category = ModuleCategory.PRODUCTIVITY,
        ) { onExit -> com.snappet.mobile.feature.journal.JournalRoot(onExit) },
        AppModule(
            id = "tip", title = "Tip Calculator",
            subtitle = "Split & round up",
            icon = Icons.Filled.AttachMoney, tint = Color(0xFF30A46C),
            category = ModuleCategory.FINANCE,
        ) { onExit -> com.snappet.mobile.feature.tip.TipRoot(onExit) },
        AppModule(
            id = "expense", title = "Split Expenses",
            subtitle = "Groups & settle-up",
            icon = Icons.Filled.Receipt, tint = Color(0xFF0091FF),
            category = ModuleCategory.FINANCE,
        ) { onExit -> com.snappet.mobile.feature.expense.ExpenseRoot(onExit) },
        AppModule(
            id = "budget", title = "Budget",
            subtitle = "Categories & trends",
            icon = Icons.Filled.PieChart, tint = Color(0xFF0091FF),
            category = ModuleCategory.FINANCE,
        ) { onExit -> com.snappet.mobile.feature.budget.BudgetRoot(onExit) },
    )

    fun byId(id: String): AppModule? = all.firstOrNull { it.id == id }
}
