package com.snappet.mobile.feature.pomodoro

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import java.util.Calendar
import java.util.concurrent.TimeUnit

/** Focus minutes for a single calendar day — the unit the 7-day chart plots. */
data class DailyFocus(val dayStart: Long, val minutes: Int)

/**
 * Aggregates [PomodoroSession] rows into the last 7 calendar days of focus minutes. Always
 * returns 7 buckets (oldest → newest) so empty days still render a zero bar. Mirrors iOS
 * `PomodoroStats.last7Days`.
 */
object PomodoroStats {
    fun startOfDay(ts: Long): Long {
        val cal = Calendar.getInstance().apply {
            timeInMillis = ts
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return cal.timeInMillis
    }

    fun last7Days(sessions: List<PomodoroSession>, now: Long = System.currentTimeMillis()): List<DailyFocus> {
        val today = startOfDay(now)
        val dayMs = TimeUnit.DAYS.toMillis(1)
        val days = (6 downTo 0).map { today - it * dayMs }
        val byDay = sessions.groupBy { startOfDay(it.completedAt) }
        return days.map { day -> DailyFocus(day, byDay[day]?.sumOf { it.minutes } ?: 0) }
    }
}

private val pomodoroWeekdayFmt = java.text.SimpleDateFormat("EEEEE", java.util.Locale.getDefault())

/** A compact 7-day focus-minutes bar chart. Shown on the Pomodoro root and atop History. */
@Composable
fun PomodoroFocusChart(data: List<DailyFocus>, modifier: Modifier = Modifier) {
    val minutes = data.map { it.minutes }
    val maxMinutes = (minutes.maxOrNull() ?: 0).coerceAtLeast(1)
    val dayLabels = data.map { pomodoroWeekdayFmt.format(java.util.Date(it.dayStart)) }
    val todayIdx = data.lastIndex.coerceAtLeast(0)
    val reduceMotion = LocalReduceMotion.current
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val grow by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "pomodoroChartGrow",
    )
    // Issue #98: today's bar in full accent, others muted — answers "Tuesday or Wednesday?".
    val accent = SnappetAccents.Tomato
    val muted = SnappetAccents.Tomato.copy(alpha = 0.35f)
    // Issue #98: a Canvas is silent to TalkBack — attach a spoken summary.
    val a11y = com.snappet.mobile.ui.ChartAccessibility.weekBarSummary("Last 7 days focus", minutes, "minute", dayLabels)
    Column(
        modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(16.dp))
            .padding(16.dp)
            .testTag("pomodoro.chart"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Last 7 days", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        androidx.compose.foundation.layout.Box(
            Modifier.fillMaxWidth().semantics { contentDescription = a11y },
        ) {
            Canvas(Modifier.fillMaxWidth().height(160.dp)) {
                val n = data.size
                val gap = size.width * 0.03f
                val barW = (size.width - gap * (n + 1)) / n
                val plotH = size.height * 0.88f
                data.forEachIndexed { i, d ->
                    val h = plotH * (d.minutes.toFloat() / maxMinutes) * grow
                    val x = gap + i * (barW + gap)
                    drawRoundRect(
                        color = if (i == todayIdx) accent else muted,
                        topLeft = Offset(x, size.height - h),
                        size = Size(barW, h),
                        cornerRadius = CornerRadius(8f, 8f),
                    )
                }
            }
            val annIdx = if (data.isNotEmpty() && data[todayIdx].minutes > 0) todayIdx
            else minutes.indices.maxByOrNull { minutes[it] } ?: todayIdx
            if (data.isNotEmpty() && minutes[annIdx] > 0) {
                Text(
                    "${minutes[annIdx]}m",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = accent,
                    modifier = Modifier.align(androidx.compose.ui.Alignment.TopStart).padding(start = 2.dp),
                )
            }
        }
        androidx.compose.foundation.layout.Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            dayLabels.forEachIndexed { i, lbl ->
                Text(
                    lbl,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = if (i == todayIdx) FontWeight.Bold else FontWeight.Normal,
                    color = if (i == todayIdx) accent else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}
