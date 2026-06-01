package com.snappet.mobile.feature.habit

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.core.SnappetCore
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Green = Color(0xFF30A46C)
private val Orange = Color(0xFFF76808)

/**
 * Root entry for the Habit mini-app. Lists habits with their current streak, a 30-day completion
 * rate, and a tappable 7-day strip to backfill/correct past days. Habits are created/edited via a
 * [HabitEditorSheet] modal bottom sheet. Mirrors iOS `HabitRootView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HabitRoot(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val dao = container.database.habitDao()
    val core = container.core
    val scope = rememberCoroutineScope()

    val habits by dao.habitsFlow().collectAsState(initial = emptyList())
    val completions by dao.completionsFlow().collectAsState(initial = emptyList())

    var showAdd by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<Habit?>(null) }

    ModuleScaffold(
        title = "Habits",
        onExit = onExit,
        actions = {
            IconButton(onClick = { showAdd = true }, modifier = Modifier.testTag("habit.add")) {
                Icon(Icons.Filled.Add, contentDescription = "Add habit")
            }
        },
    ) { padding ->
        if (habits.isEmpty()) {
            EmptyState(padding) { showAdd = true }
        } else {
            HabitList(
                padding = padding,
                habits = habits,
                completions = completions,
                onToggleDay = { habit, dayStart -> toggle(scope, dao, core, completions, habit, dayStart) },
                onEdit = { editing = it },
            )
        }
    }

    if (showAdd) {
        ModalBottomSheet(onDismissRequest = { showAdd = false }, sheetState = rememberModalBottomSheetState()) {
            HabitEditorSheet(existing = null) { name, symbol ->
                showAdd = false
                scope.launch {
                    dao.insertHabit(Habit(name = name, symbol = symbol, createdAt = System.currentTimeMillis()))
                    core.log("habit", "create", "Added habit: $name")
                }
            }
        }
    }

    editing?.let { habit ->
        ModalBottomSheet(onDismissRequest = { editing = null }, sheetState = rememberModalBottomSheetState()) {
            HabitEditorSheet(existing = habit) { name, symbol ->
                editing = null
                scope.launch {
                    dao.updateHabit(habit.copy(name = name, symbol = symbol))
                    core.log("habit", "edit", "Edited habit: $name")
                }
            }
        }
    }
}

/** Insert or remove a completion for [dayStart] (already start-of-day). Logs done/backfill on insert. */
private fun toggle(
    scope: kotlinx.coroutines.CoroutineScope,
    dao: HabitDao,
    core: SnappetCore,
    completions: List<HabitCompletion>,
    habit: Habit,
    dayStart: Long,
) {
    val existing = completions.firstOrNull { it.habitId == habit.habitId && it.day == dayStart }
    scope.launch {
        if (existing != null) {
            dao.deleteCompletion(existing)
        } else {
            dao.insertCompletion(HabitCompletion(habitId = habit.habitId, day = dayStart))
            val isToday = dayStart == HabitStats.startOfDay(System.currentTimeMillis())
            core.log(
                "habit",
                if (isToday) "done" else "backfill",
                if (isToday) "Did: ${habit.name}" else "Backfilled: ${habit.name}",
            )
        }
    }
}

@Composable
private fun EmptyState(padding: PaddingValues, onAdd: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = Green, modifier = Modifier.size(48.dp))
            Text("No habits yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "Add a habit to start building a daily streak.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = onAdd, modifier = Modifier.testTag("habit.add")) {
                Text("Add Habit")
            }
        }
    }
}

@Composable
private fun HabitList(
    padding: PaddingValues,
    habits: List<Habit>,
    completions: List<HabitCompletion>,
    onToggleDay: (Habit, Long) -> Unit,
    onEdit: (Habit) -> Unit,
) {
    LazyColumn(
        Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        itemsIndexed(habits, key = { _, h -> h.habitId }) { index, habit ->
            val days = completions.filter { it.habitId == habit.habitId }.map { it.day }.toSet()
            HabitRow(
                index = index,
                habit = habit,
                streak = HabitStats.streak(days),
                rate = HabitStats.completionRate(days, habit.createdAt),
                weekDays = weekStrip(days),
                onToggleDay = { dayStart -> onToggleDay(habit, dayStart) },
                onEdit = { onEdit(habit) },
            )
        }
    }
}

/** The last 7 calendar days (oldest -> today) with each day's done state. Mirrors iOS `weekStrip`. */
private fun weekStrip(days: Set<Long>, now: Long = System.currentTimeMillis()): List<WeekDay> {
    val today = HabitStats.startOfDay(now)
    return (6 downTo 0).map { offset ->
        val day = HabitStats.dayBefore(today, offset)
        WeekDay(offset = offset, dayStart = day, isDone = days.contains(day))
    }
}

@Composable
private fun HabitRow(
    index: Int,
    habit: Habit,
    streak: Int,
    rate: Double,
    weekDays: List<WeekDay>,
    onToggleDay: (Long) -> Unit,
    onEdit: () -> Unit,
) {
    val pct = Math.round(rate * 100).toInt()
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(16.dp)
            .testTag("habit.row.$index"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(HabitSymbols.icon(habit.symbol), contentDescription = null, tint = Green, modifier = Modifier.size(28.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(habit.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                StreakLabel(streak)
                Text(
                    "$pct% last 30 days",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("habit.rate.$index"),
                )
            }
        }
        WeekStripRow(weekDays = weekDays, onToggleDay = onToggleDay, onEdit = onEdit)
    }
}

@Composable
private fun StreakLabel(streak: Int) {
    if (streak > 0) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(Icons.Filled.LocalFireDepartment, contentDescription = null, tint = Orange, modifier = Modifier.size(16.dp))
            Text(
                "$streak ${if (streak == 1) "day" else "days"} streak",
                style = MaterialTheme.typography.bodyMedium,
                color = Orange,
            )
        }
    } else {
        Text(
            "No streak yet",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun WeekStripRow(weekDays: List<WeekDay>, onToggleDay: (Long) -> Unit, onEdit: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        IconButton(onClick = onEdit, modifier = Modifier.size(36.dp).testTag("habit.edit")) {
            Icon(Icons.Filled.Edit, contentDescription = "Edit habit", tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
        }
        weekDays.forEach { day -> DayCell(day = day, onToggle = { onToggleDay(day.dayStart) }) }
    }
}

private val weekdayFmt = SimpleDateFormat("EEEEE", Locale.getDefault())
private val dayNumberFmt = SimpleDateFormat("d", Locale.getDefault())

@Composable
private fun DayCell(day: WeekDay, onToggle: () -> Unit) {
    val date = Date(day.dayStart)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onToggle)
            .testTag("habit.day.${day.offset}")
            .padding(2.dp),
    ) {
        Text(weekdayFmt.format(date), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Box(
            Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(if (day.isDone) Green else Green.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                dayNumberFmt.format(date),
                style = MaterialTheme.typography.labelSmall,
                color = if (day.isDone) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
