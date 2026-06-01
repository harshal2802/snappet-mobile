package com.snappet.mobile.ui.home

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
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.collectAsState
import com.snappet.mobile.core.UsageRecord
import com.snappet.mobile.ui.LocalAppContainer
import java.util.Calendar
import java.util.concurrent.TimeUnit

/**
 * The daily home: aggregates historical usage across every mini-app so the suite reads as one
 * app, not a bag of tools. Reactive via a Room `Flow` — any mini-app logging to SnappetCore
 * updates this automatically. Mirrors the iOS `HomeDashboardView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeDashboardScreen() {
    val core = LocalAppContainer.current.core
    val records by core.allFlow().collectAsState(initial = emptyList())

    Scaffold(topBar = { TopAppBar(title = { Text("Today") }) }) { padding ->
        if (records.isEmpty()) {
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
                WeekChart(records)
                ActivityFeed(records)
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
            StatTile("${today.size}", "actions", Color(0xFF0091FF), Modifier.weight(1f))
            StatTile("${today.map { it.module }.toSet().size}", "apps used", Color(0xFF8E4EC6), Modifier.weight(1f))
            StatTile(streak(records).toString(), "day streak", Color(0xFFF76808), Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatTile(value: String, label: String, tint: Color, modifier: Modifier = Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(value, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = tint)
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
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Last 7 days", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Canvas(Modifier.fillMaxWidth().height(160.dp)) {
            val n = counts.size
            val gap = size.width * 0.03f
            val barW = (size.width - gap * (n + 1)) / n
            counts.forEachIndexed { i, c ->
                val h = size.height * (c.toFloat() / maxCount)
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
private fun ActivityFeed(records: List<UsageRecord>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Recent activity", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        records.take(12).forEach { r ->
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(r.summary, style = MaterialTheme.typography.bodyMedium)
                    Text(
                        r.module.replaceFirstChar { it.uppercase() },
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
