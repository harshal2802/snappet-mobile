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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.collectAsState
import com.snappet.mobile.core.UsageRecord
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.LocalSpacing
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
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
                    Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(LocalSpacing.current.pageGutter),
                    verticalArrangement = Arrangement.spacedBy(24.dp),
                ) {
                    TodayRow(records)
                    WeekChart(records)
                    ActivityFeed(records)
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

private val weekdayInitialFmt = java.text.SimpleDateFormat("EEEEE", java.util.Locale.getDefault())

@Composable
private fun WeekChart(records: List<UsageRecord>) {
    val todayStart = startOfToday()
    val dayMs = TimeUnit.DAYS.toMillis(1)
    val counts = (6 downTo 0).map { offset ->
        val start = todayStart - offset * dayMs
        records.count { it.timestamp >= start && it.timestamp < start + dayMs }
    }
    // Weekday initials oldest→newest under each bar (mirrors the habit strip's labeling).
    val dayLabels = (6 downTo 0).map { offset -> weekdayInitialFmt.format(java.util.Date(todayStart - offset * dayMs)) }
    val maxCount = (counts.maxOrNull() ?: 0).coerceAtLeast(1)
    val todayIdx = counts.lastIndex
    // Issue #98: today's bar reads in full accent, the rest muted, so "more on Tue or Wed?" is answerable.
    val accent = MaterialTheme.colorScheme.primary
    val muted = MaterialTheme.colorScheme.primary.copy(alpha = 0.35f)
    val reduceMotion = LocalReduceMotion.current
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val grow by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "weekChartGrow",
    )
    // Issue #98: a Canvas is invisible to TalkBack — attach a spoken summary of the whole chart.
    val a11y = com.snappet.mobile.ui.ChartAccessibility.weekBarSummary("Last 7 days actions", counts, "action", dayLabels)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Last 7 days", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Box(
            Modifier.fillMaxWidth().testTag("home.weekChart")
                .semantics { contentDescription = a11y },
        ) {
            Canvas(Modifier.fillMaxWidth().height(160.dp)) {
                val n = counts.size
                val gap = size.width * 0.03f
                val barW = (size.width - gap * (n + 1)) / n
                // Reserve a little headroom so a value annotation on the tallest bar isn't clipped.
                val plotH = size.height * 0.88f
                counts.forEachIndexed { i, c ->
                    val h = plotH * (c.toFloat() / maxCount) * grow
                    val x = gap + i * (barW + gap)
                    drawRoundRect(
                        color = if (i == todayIdx) accent else muted,
                        topLeft = androidx.compose.ui.geometry.Offset(x, size.height - h),
                        size = androidx.compose.ui.geometry.Size(barW, h),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(8f, 8f),
                    )
                }
            }
            // Value annotation on today's bar (or the max if today is empty) — a readable number on the chart.
            val annIdx = if (counts[todayIdx] > 0) todayIdx else counts.indices.maxByOrNull { counts[it] } ?: todayIdx
            if (counts[annIdx] > 0) {
                Text(
                    "${counts[annIdx]}",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = accent,
                    modifier = Modifier.align(Alignment.TopStart).padding(start = 2.dp),
                )
            }
        }
        // Weekday initials under each bar.
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
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
