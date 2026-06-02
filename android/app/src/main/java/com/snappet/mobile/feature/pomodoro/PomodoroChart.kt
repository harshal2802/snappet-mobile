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

/** A compact 7-day focus-minutes bar chart. Shown on the Pomodoro root and atop History. */
@Composable
fun PomodoroFocusChart(data: List<DailyFocus>, modifier: Modifier = Modifier) {
    val maxMinutes = (data.maxOfOrNull { it.minutes } ?: 0).coerceAtLeast(1)
    val reduceMotion = LocalReduceMotion.current
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val grow by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "pomodoroChartGrow",
    )
    Column(
        modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(16.dp))
            .padding(16.dp)
            .testTag("pomodoro.chart"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Last 7 days", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Canvas(Modifier.fillMaxWidth().height(160.dp)) {
            val n = data.size
            val gap = size.width * 0.03f
            val barW = (size.width - gap * (n + 1)) / n
            data.forEachIndexed { i, d ->
                val h = size.height * (d.minutes.toFloat() / maxMinutes) * grow
                val x = gap + i * (barW + gap)
                drawRoundRect(
                    color = SnappetAccents.Tomato,
                    topLeft = Offset(x, size.height - h),
                    size = Size(barW, h),
                    cornerRadius = CornerRadius(8f, 8f),
                )
            }
        }
    }
}
