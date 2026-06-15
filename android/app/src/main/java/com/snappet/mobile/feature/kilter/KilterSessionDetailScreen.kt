package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.feature.kilter.hr.HeartRateZone
import com.snappet.mobile.ui.ModuleScaffold
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Detail for one Kilter session (issue #92): a header, a summary grid, an HR summary (when a strap was
 * captured), the grade pyramid, and the per-climb timeline. All numbers come from the pure
 * [KilterSessionStats] core (unit-tested) — this screen only renders. Mirrors the iOS
 * `KilterSessionDetailView`. `onExit` returns to History.
 */
@Composable
fun KilterSessionDetailScreen(
    sessionId: String,
    dao: KilterDao,
    catalog: KilterCatalog,
    onExit: () -> Unit,
) {
    val allSessions by dao.sessionsFlow().collectAsState(initial = emptyList())
    val allLogs by dao.logsFlow().collectAsState(initial = emptyList())
    val session = allSessions.firstOrNull { it.id == sessionId }
    val dateFmt = SimpleDateFormat("EEE d MMM · HH:mm", Locale.getDefault())

    ModuleScaffold(title = "Session", onExit = onExit) { padding ->
        if (session == null) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text("Session not found", style = MaterialTheme.typography.titleMedium)
            }
            return@ModuleScaffold
        }

        val logs = allLogs.filter { it.sessionId == sessionId }
        val end = session.endedAt ?: System.currentTimeMillis()
        val stats = KilterSessionStats.make(
            logs = logs.map {
                KilterSessionStats.SessionLog(
                    climbUuid = it.climbUuid, climbName = it.climbName, gradeLabel = it.gradeLabel,
                    difficulty = it.difficulty, status = KilterAscentStatus.from(it.status),
                    attempts = it.attempts, loggedAt = it.createdAt,
                )
            },
            startMillis = session.startedAt, endMillis = end,
        )
        val durMin = (stats.totalDurationSec / 60.0).toInt()

        LazyColumn(
            Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Header.
            item {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    val kind = if (session.source == "ble") "Board session" else "Manual session"
                    Text(kind, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text("${dateFmt.format(Date(session.startedAt))} · ${session.angle}°",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(if (session.endedAt == null) "Active now" else "$durMin min",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            // Summary grid (sends / climbs / hardest / tries / sends-per-hour).
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                    Metric("Sends", "${stats.sends}", "kilter.session.sends")
                    Metric("Climbs", "${stats.totalClimbs}", null)
                    Metric("Hardest", stats.hardestSendGrade ?: "—", null)
                }
            }
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                    Metric("Projects", "${stats.projects}", null)
                    Metric("Tries", "${stats.totalAttempts}", null)
                    Metric("Sends/hr", String.format(Locale.US, "%.1f", stats.sendsPerHour), null)
                }
            }

            // HR summary — from the persisted columns (set on session end when a strap was captured).
            if (session.avgHr != null && session.maxHr != null) {
                item { SectionHeader("Heart rate") }
                item {
                    Row(Modifier.fillMaxWidth().testTag("kilter.session.hr"),
                        horizontalArrangement = Arrangement.SpaceEvenly) {
                        Metric("Avg", "${session.avgHr}", null)
                        Metric("Max", "${session.maxHr}", null)
                        val zone = HeartRateZone.forBpm(session.avgHr)
                        Metric("Zone", zone.pillLabel, null)
                    }
                }
            }

            // Grade pyramid.
            if (stats.pyramid.isNotEmpty()) {
                item { SectionHeader("Grade pyramid") }
                val maxBar = stats.pyramid.maxOf { it.sends }
                items(stats.pyramid, key = { it.gradeLabel }) { bar ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(bar.gradeLabel, style = MaterialTheme.typography.labelMedium, modifier = Modifier.width(64.dp))
                        Box(
                            Modifier.fillMaxWidth(0.9f * bar.sends / maxBar).height(14.dp)
                                .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(7.dp))
                        )
                        Text("  ${bar.sends}", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            // Per-climb timeline.
            if (stats.timeline.isNotEmpty()) {
                item { SectionHeader("Climbs") }
                items(stats.timeline, key = { it.index }) { row ->
                    val color = when (row.status) {
                        KilterAscentStatus.FLASH, KilterAscentStatus.SENT -> com.snappet.mobile.ui.theme.pulseSuccess()
                        KilterAscentStatus.PROJECT -> com.snappet.mobile.ui.theme.pulseWarning()
                        KilterAscentStatus.ATTEMPT -> com.snappet.mobile.ui.theme.pulseNeutral()
                    }
                    Row(Modifier.fillMaxWidth().testTag("kilter.session.timelineRow"),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.background(color.copy(alpha = 0.22f), RoundedCornerShape(8.dp))
                            .padding(horizontal = 7.dp, vertical = 2.dp)) {
                            Text(row.status.label, style = MaterialTheme.typography.labelSmall,
                                color = color, fontWeight = FontWeight.SemiBold)
                        }
                        Text(row.climbName, style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium, maxLines = 1, modifier = Modifier.weight(1f))
                        Text(row.gradeLabel, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (row.attempts > 1) {
                            Text("${row.attempts} tries", style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Metric(label: String, value: String, testTag: String?) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = if (testTag != null) Modifier.testTag(testTag) else Modifier,
    ) {
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
}
