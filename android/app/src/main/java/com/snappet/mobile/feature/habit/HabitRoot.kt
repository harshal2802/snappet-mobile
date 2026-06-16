package com.snappet.mobile.feature.habit

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateIntAsState
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.draw.scale
import com.snappet.mobile.core.SnappetCore
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.LocalSpacing
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Green = SnappetAccents.Leaf
private val Orange = SnappetAccents.Ember

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
    val snackbar = com.snappet.mobile.ui.LocalSnackbarController.current
    val haptics = com.snappet.mobile.ui.rememberSnappetHaptics()

    val habits by dao.habitsFlow().collectAsState(initial = emptyList())
    val completions by dao.completionsFlow().collectAsState(initial = emptyList())

    var showAdd by rememberSaveable { mutableStateOf(false) }
    // Issue #86: staged by id, not object — after restore the edit sheet self-heals shut if the habit is gone.
    var editingId by rememberSaveable { mutableStateOf<String?>(null) }
    val editing = habits.firstOrNull { it.habitId == editingId }
    // Issue #88: a habit staged for deletion (from the edit sheet), pending confirmation.
    var confirmingDelete by remember { mutableStateOf<Habit?>(null) }

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
                onToggleDay = { habit, dayStart ->
                    haptics.commit() // tactile confirmation on toggle (issue #89)
                    toggle(scope, dao, core, completions, habit, dayStart) { milestone ->
                        // 7/30-day streak celebration (issue #89).
                        snackbar.show("$milestone-day streak — keep it up!")
                    }
                },
                onEdit = { editingId = it.habitId },
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
        ModalBottomSheet(onDismissRequest = { editingId = null }, sheetState = rememberModalBottomSheetState()) {
            HabitEditorSheet(
                existing = habit,
                onSave = { name, symbol ->
                    editingId = null
                    scope.launch {
                        dao.updateHabit(habit.copy(name = name, symbol = symbol))
                        core.log("habit", "edit", "Edited habit: $name")
                    }
                },
                onDelete = { editingId = null; confirmingDelete = habit },
            )
        }
    }

    confirmingDelete?.let { habit ->
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete \u201C${habit.name}\u201D?",
            message = "This removes the habit and all its completion history.",
            onConfirm = {
                confirmingDelete = null
                scope.launch {
                    dao.deleteCompletionsFor(habit.habitId)
                    dao.deleteHabit(habit)
                }
            },
            onDismiss = { confirmingDelete = null },
        )
    }
}

/**
 * Insert or remove a completion for [dayStart] (already start-of-day). Logs done/backfill on insert.
 * On a completion that lands the streak on a milestone (7 or 30 days), invokes [onMilestone] with the
 * milestone count so the caller can celebrate (issue #89).
 */
private fun toggle(
    scope: kotlinx.coroutines.CoroutineScope,
    dao: HabitDao,
    core: SnappetCore,
    completions: List<HabitCompletion>,
    habit: Habit,
    dayStart: Long,
    onMilestone: (Int) -> Unit = {},
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
            // Recompute the streak with this just-added day and celebrate 7/30-day milestones.
            val days = completions.filter { it.habitId == habit.habitId }.map { it.day }.toSet() + dayStart
            val streak = HabitStats.streak(days)
            if (streak == 7 || streak == 30) onMilestone(streak)
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
    val reduceMotion = LocalReduceMotion.current
    val pctTarget = Math.round(rate * 100).toInt()
    val pct by animateIntAsState(
        targetValue = pctTarget,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "habit.rate.$index",
    )
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
    val reduceMotion = LocalReduceMotion.current
    val animatedStreak by animateIntAsState(
        targetValue = streak,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "habitStreak",
    )
    if (streak > 0) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(Icons.Filled.LocalFireDepartment, contentDescription = null, tint = Orange, modifier = Modifier.size(16.dp))
            Text(
                "$animatedStreak ${if (streak == 1) "day" else "days"} streak",
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
        // Issue #98: the edit button was explicitly .size(36.dp), defeating M3's 48dp minimum target.
        // Float the visible glyph at 18dp but give the touch target the accessibility minimum.
        IconButton(
            onClick = onEdit,
            modifier = Modifier.sizeIn(minWidth = LocalSpacing.current.minTouchTarget, minHeight = LocalSpacing.current.minTouchTarget)
                .testTag("habit.edit"),
        ) {
            Icon(Icons.Filled.Edit, contentDescription = "Edit habit", tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
        }
        weekDays.forEach { day -> DayCell(day = day, onToggle = { onToggleDay(day.dayStart) }) }
    }
}

private val weekdayFmt = SimpleDateFormat("EEEEE", Locale.getDefault())
private val dayNumberFmt = SimpleDateFormat("d", Locale.getDefault())
private val a11yDateFmt = SimpleDateFormat("EEEE d MMMM", Locale.getDefault())

@Composable
private fun DayCell(day: WeekDay, onToggle: () -> Unit) {
    val date = Date(day.dayStart)
    val reduceMotion = LocalReduceMotion.current
    val fill by animateColorAsState(
        targetValue = if (day.isDone) Green else Green.copy(alpha = 0.12f),
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "habitDayFill",
    )
    val cellScale by animateFloatAsState(
        targetValue = if (day.isDone) 1f else 0.92f,
        animationSpec = gated(reduceMotion, SnappetMotion.expressive()),
        label = "habitDayScale",
    )
    // Issue #98: TalkBack now reads the cell as a checkbox with its done/not-done state (it used to
    // announce just the day number), and the touch target reaches the 48dp minimum (the visible
    // circle stays 28dp). One merged semantics node per day instead of two stray text reads.
    val minTarget = LocalSpacing.current.minTouchTarget
    val dateLabel = a11yDateFmt.format(date)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .sizeIn(minWidth = minTarget, minHeight = minTarget)
            .clickable(
                onClick = onToggle,
                onClickLabel = if (day.isDone) "mark not done" else "mark done",
                role = Role.Checkbox,
            )
            .clearAndSetSemantics {
                role = Role.Checkbox
                contentDescription = dateLabel
                stateDescription = if (day.isDone) "Done" else "Not done"
            }
            .testTag("habit.day.${day.offset}")
            .padding(2.dp),
    ) {
        Text(weekdayFmt.format(date), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Box(
            Modifier
                .size(28.dp)
                .scale(cellScale)
                .clip(CircleShape)
                .background(fill),
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
