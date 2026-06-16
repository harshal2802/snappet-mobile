package com.snappet.mobile.ui.home

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateIntAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import com.snappet.mobile.core.ModuleRegistry
import com.snappet.mobile.core.UsageRecord
import com.snappet.mobile.feature.habit.Habit
import com.snappet.mobile.feature.habit.HabitCompletion
import com.snappet.mobile.feature.habit.HabitStats
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import kotlinx.coroutines.launch
import java.util.Calendar
import java.util.concurrent.TimeUnit

/**
 * The daily home: actionable cross-module cards + aggregated usage, so the suite reads as one app
 * (issue #99). Reactive via Room `Flow`s — any mini-app logging updates this automatically; the
 * cards read the SAME flows the Glance widgets read (via [TodayData]). Feed rows show module display
 * names and deep-link into their module through [onOpenModule]. Mirrors the iOS `HomeDashboardView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeDashboardScreen(onOpenModule: (String) -> Unit = {}) {
    val container = LocalAppContainer.current
    val core = container.core
    val records by core.allFlow().collectAsState(initial = emptyList())
    val habits by container.database.habitDao().habitsFlow().collectAsState(initial = emptyList())
    val completions by container.database.habitDao().completionsFlow().collectAsState(initial = emptyList())
    val pomodoros by container.database.pomodoroDao().allFlow().collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()

    val reduceMotion = LocalReduceMotion.current
    Scaffold(topBar = { TopAppBar(title = { Text("Today") }) }) { padding ->
        AnimatedContent(
            targetState = records.isEmpty(),
            transitionSpec = {
                fadeIn(gated(reduceMotion, SnappetMotion.quick())) togetherWith
                    fadeOut(gated(reduceMotion, SnappetMotion.quick()))
            },
            label = "homeEmptyPopulated",
        ) { isEmpty ->
            if (isEmpty) {
                Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("No activity yet", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Open an app from the Apps tab — your activity shows up here.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp),
                        )
                    }
                }
            } else {
                Column(
                    Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(24.dp),
                ) {
                    TodayRow(records)
                    ActionCards(
                        habits = habits, completions = completions, pomodoros = pomodoros,
                        onOpenModule = onOpenModule,
                        onToggleHabit = { habit, doneToday ->
                            scope.launch {
                                val dao = container.database.habitDao()
                                val today = HabitStats.startOfDay(System.currentTimeMillis())
                                if (doneToday) {
                                    completions.firstOrNull { it.habitId == habit.habitId && it.day == today }
                                        ?.let { dao.deleteCompletion(it) }
                                } else {
                                    dao.insertCompletion(HabitCompletion(habitId = habit.habitId, day = today))
                                    core.log("habit", "complete", "Completed ${habit.name}")
                                }
                            }
                        },
                    )
                    WeekChart(records)
                    ActivityFeed(records, onOpenModule)
                }
            }
        }
    }
}

private fun startOfToday(): Long {
    val cal = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }
    return cal.timeInMillis
}

@Composable
private fun TodayRow(records: List<UsageRecord>) {
    val todayStart = startOfToday()
    val today = records.filter { it.timestamp >= todayStart }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Today", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile(today.size, "actions", SnappetAccents.Azure, Modifier.weight(1f))
            StatTile(today.map { it.module }.toSet().size, "apps used", SnappetAccents.Violet, Modifier.weight(1f))
            StatTile(streak(records), "day streak", SnappetAccents.Ember, Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatTile(value: Int, label: String, tint: Color, modifier: Modifier = Modifier) {
    val reduceMotion = LocalReduceMotion.current
    val animated by animateIntAsState(
        targetValue = value,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "statTile.$label",
    )
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("$animated", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = tint)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun WeekChart(records: List<UsageRecord>) {
    val todayStart = startOfToday()
    val dayMs = TimeUnit.DAYS.toMillis(1)
    val counts = (6 downTo 0).map { offset ->
        val start = todayStart - offset * dayMs
        records.count { it.timestamp >= start && it.timestamp < start + dayMs }
    }
    val maxCount = (counts.maxOrNull() ?: 0).coerceAtLeast(1)
    val barColor = MaterialTheme.colorScheme.primary
    val reduceMotion = LocalReduceMotion.current
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val grow by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "weekChartGrow",
    )
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Last 7 days", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Canvas(Modifier.fillMaxWidth().height(160.dp)) {
            val n = counts.size
            val gap = size.width * 0.03f
            val barW = (size.width - gap * (n + 1)) / n
            counts.forEachIndexed { i, c ->
                val h = size.height * (c.toFloat() / maxCount) * grow
                val x = gap + i * (barW + gap)
                drawRoundRect(
                    color = barColor,
                    topLeft = androidx.compose.ui.geometry.Offset(x, size.height - h),
                    size = androidx.compose.ui.geometry.Size(barW, h),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(8f, 8f),
                )
            }
        }
    }
}

@Composable
private fun ActivityFeed(records: List<UsageRecord>, onOpenModule: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Recent activity", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        records.take(12).forEach { r ->
            // Issue #99: show the module's proper display name (not the raw id), and tapping the row
            // opens the source module. Unknown ids (legacy) fall back to a title-cased label, no tap.
            val module = ModuleRegistry.byId(r.module)
            val displayName = module?.title ?: r.module.replaceFirstChar { it.uppercase() }
            Row(
                Modifier.fillMaxWidth()
                    .then(if (module != null) Modifier.clickable { onOpenModule(r.module) } else Modifier)
                    .padding(vertical = 4.dp)
                    .testTag("home.feedRow"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(r.summary, style = MaterialTheme.typography.bodyMedium)
                    Text(
                        displayName,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    relativeTime(r.timestamp),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            HorizontalDivider()
        }
    }
}

/** Consecutive days (ending today) with at least one logged action. */
private fun streak(records: List<UsageRecord>): Int {
    val dayMs = TimeUnit.DAYS.toMillis(1)
    val days = records.map {
        val cal = Calendar.getInstance().apply {
            timeInMillis = it.timestamp
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        cal.timeInMillis
    }.toSet()
    var streak = 0
    var cursor = startOfToday()
    while (days.contains(cursor)) {
        streak++
        cursor -= dayMs
    }
    return streak
}

private fun relativeTime(ts: Long): String {
    val diff = System.currentTimeMillis() - ts
    val mins = TimeUnit.MILLISECONDS.toMinutes(diff)
    return when {
        mins < 1 -> "now"
        mins < 60 -> "${mins}m ago"
        mins < 1440 -> "${mins / 60}h ago"
        else -> "${mins / 1440}d ago"
    }
}

/**
 * Issue #99: actionable cross-module cards reading the same Room flows the Glance widgets read (via
 * [TodayData]). Habits-today with inline check-off, focus minutes, and the active/last Kilter session,
 * each deep-tapping into its module.
 */
@Composable
private fun ActionCards(
    habits: List<Habit>,
    completions: List<HabitCompletion>,
    pomodoros: List<com.snappet.mobile.feature.pomodoro.PomodoroSession>,
    onOpenModule: (String) -> Unit,
    onToggleHabit: (Habit, doneToday: Boolean) -> Unit,
) {
    val habitsToday = TodayData.habits(habits, completions)
    val focus = TodayData.focus(pomodoros)

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Jump back in", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)

        // Habits card — inline check-off for the first not-yet-done habit, tap header to open.
        if (habits.isNotEmpty()) {
            val firstUndone = habits.firstOrNull { !TodayData.isHabitDoneToday(it.habitId, completions) }
            ActionCard(
                tint = SnappetAccents.forModule("habit"),
                title = "Habits",
                subtitle = "${habitsToday.doneToday}/${habitsToday.total} done today" +
                    if (habitsToday.bestStreak > 0) " · ${habitsToday.bestStreak}-day streak" else "",
                onOpen = { onOpenModule("habit") },
                trailing = {
                    if (firstUndone != null) {
                        IconButton(
                            onClick = { onToggleHabit(firstUndone, false) },
                            modifier = Modifier.testTag("home.habitCheck"),
                        ) {
                            Icon(Icons.Outlined.RadioButtonUnchecked, contentDescription = "Mark ${firstUndone.name} done")
                        }
                    } else {
                        Icon(Icons.Filled.CheckCircle, contentDescription = "All habits done",
                            tint = com.snappet.mobile.ui.theme.pulseSuccess(), modifier = Modifier.size(28.dp))
                    }
                },
            )
        }

        // Focus card — today's minutes + open Pomodoro.
        ActionCard(
            tint = SnappetAccents.forModule("pomodoro"),
            title = "Focus",
            subtitle = if (focus.minutesToday > 0) "${focus.minutesToday} min today" else "Start a focus session",
            onOpen = { onOpenModule("pomodoro") },
            trailing = {},
        )
    }
}

@Composable
private fun ActionCard(
    tint: Color,
    title: String,
    subtitle: String,
    onOpen: () -> Unit,
    trailing: @Composable () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.10f))
            .clickable { onOpen() }
            .padding(16.dp)
            .testTag("home.card.$title"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = tint)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        trailing()
    }
}
