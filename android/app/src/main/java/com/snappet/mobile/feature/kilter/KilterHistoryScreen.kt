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
import androidx.compose.material3.TextButton
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Your Kilter history: a summary, a grade pyramid (sends per grade), board sessions (auto-captured
 * while connected over BLE — Phase 2), and the full ascent log, newest first. Mirrors the iOS
 * `KilterHistoryView`. `onExit` returns to the catalog.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun KilterHistoryScreen(dao: KilterDao, onExit: () -> Unit) {
    val entries by dao.logsFlow().collectAsState(initial = emptyList())
    val allSessions by dao.sessionsFlow().collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    val dateFmt = SimpleDateFormat("EEE d MMM", Locale.getDefault())
    // Issue #88: the whole climbing history must not be one unconfirmed tap away.
    var confirmingClearAll by remember { mutableStateOf(false) }
    // The ascent staged by a long-press: correct its status or delete it.
    var editingEntry by remember { mutableStateOf<KilterLogEntry?>(null) }
    var confirmingDelete by remember { mutableStateOf<KilterLogEntry?>(null) }

    if (confirmingClearAll) {
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Clear all history?",
            message = "This permanently removes every logged climb and session.",
            confirmLabel = "Clear all",
            onConfirm = {
                confirmingClearAll = false
                scope.launch { dao.clearLogs(); dao.clearSessions() }
            },
            onDismiss = { confirmingClearAll = false },
        )
    }

    confirmingDelete?.let { entry ->
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete this ascent?",
            message = "${entry.climbName} (${entry.gradeLabel}) is removed from your history and stats.",
            onConfirm = {
                confirmingDelete = null
                scope.launch { dao.deleteLog(entry) }
            },
            onDismiss = { confirmingDelete = null },
        )
    }

    editingEntry?.let { entry ->
        AscentEditDialog(
            entry = entry,
            onSetStatus = { status ->
                editingEntry = null
                scope.launch { dao.updateLogStatus(entry.id, status.name) }
            },
            onDelete = { editingEntry = null; confirmingDelete = entry },
            onDismiss = { editingEntry = null },
        )
    }

    ModuleScaffold(
        title = "History",
        onExit = onExit,
        actions = {
            if (entries.isNotEmpty()) {
                TextButton(onClick = { confirmingClearAll = true },
                    modifier = Modifier.testTag("kilter.history.clear")) { Text("Clear all") }
            }
        },
    ) { padding ->
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No history yet", style = MaterialTheme.typography.titleMedium)
                    Text("Climbs you log appear here.", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp))
                }
            }
            return@ModuleScaffold
        }

        val sends = entries.filter { KilterAscentStatus.from(it.status).isSend }
        val monthStart = Calendar.getInstance().apply {
            set(Calendar.DAY_OF_MONTH, 1); set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val sendsThisMonth = sends.count { it.createdAt >= monthStart }
        val hardest = sends.maxByOrNull { it.difficulty }?.gradeLabel ?: "—"
        val pyramid = sends.groupBy { it.gradeLabel }
            .map { (label, rows) -> Triple(label, rows.size, rows.first().difficulty) }
            .sortedBy { it.third }
        val usedSessionIds = entries.mapNotNull { it.sessionId }.toSet()
        val sessions = allSessions.filter { usedSessionIds.contains(it.id) }
        val maxBar = pyramid.maxOfOrNull { it.second } ?: 1

        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                    SummaryStat("Sends", "${sends.size}")
                    SummaryStat("This month", "$sendsThisMonth")
                    SummaryStat("Hardest", hardest)
                }
            }
            item { SectionHeader("Grade pyramid") }
            if (pyramid.isEmpty()) {
                item { Text("Log a send to build your pyramid.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            } else {
                items(pyramid, key = { it.first }) { (label, count, _) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(label, style = MaterialTheme.typography.labelMedium, modifier = Modifier.width(64.dp))
                        Box(
                            Modifier.fillMaxWidth(0.9f * count / maxBar).height(14.dp)
                                .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(7.dp))
                        )
                        Text("  $count", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            if (sessions.isNotEmpty()) {
                item { SectionHeader("Sessions") }
                items(sessions, key = { it.id }) { session ->
                    val logs = entries.filter { it.sessionId == session.id }
                    Column(Modifier.fillMaxWidth().testTag("kilter.sessionRow"), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(dateFmt.format(Date(session.startedAt)), style = MaterialTheme.typography.titleSmall)
                            Text(" · ${session.angle}°", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Box(Modifier.weight(1f))
                            val ble = session.source == "ble"
                            Box(
                                Modifier.background(if (ble) com.snappet.mobile.ui.theme.pulseSuccess().copy(alpha = 0.2f) else MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
                                    .padding(horizontal = 8.dp, vertical = 2.dp)
                            ) { Text(if (ble) "BLE" else "Manual", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold) }
                        }
                        val sent = logs.count { KilterAscentStatus.from(it.status).isSend }
                        val proj = logs.count { it.status == KilterAscentStatus.PROJECT.name }
                        val dur = session.endedAt?.let { " · ${((it - session.startedAt) / 60000)} min" } ?: ""
                        Text("$sent sent · $proj proj$dur", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            item { SectionHeader("Ascents") }
            items(entries, key = { it.id }) { entry ->
                AscentRow(entry, onLongPress = { editingEntry = entry })
            }
        }
    }
}

@Composable
private fun SummaryStat(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(top = 8.dp))
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AscentRow(entry: KilterLogEntry, onLongPress: () -> Unit = {}) {
    val status = KilterAscentStatus.from(entry.status)
    val color = when (status) {
        KilterAscentStatus.FLASH, KilterAscentStatus.SENT -> com.snappet.mobile.ui.theme.pulseSuccess()
        KilterAscentStatus.PROJECT -> com.snappet.mobile.ui.theme.pulseWarning()
        KilterAscentStatus.ATTEMPT -> com.snappet.mobile.ui.theme.pulseNeutral()
    }
    Column(
        Modifier.fillMaxWidth()
            .combinedClickable(onClick = {}, onLongClick = onLongPress)
            .padding(vertical = 4.dp).testTag("kilter.historyRow"),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.background(color.copy(alpha = 0.22f), RoundedCornerShape(8.dp)).padding(horizontal = 7.dp, vertical = 2.dp)) {
                Text(status.label, style = MaterialTheme.typography.labelSmall, color = color, fontWeight = FontWeight.SemiBold)
            }
            Text(entry.climbName, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 1)
        }
        Text("${entry.gradeLabel} · ${entry.angle}°", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Long-press menu for one logged ascent (issue #88): correct the status — a
 *  fat-fingered Flash no longer inflates the pyramid forever — or delete the row. */
@Composable
private fun AscentEditDialog(
    entry: KilterLogEntry,
    onSetStatus: (KilterAscentStatus) -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("${entry.climbName} · ${entry.gradeLabel}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Logged as ${KilterAscentStatus.from(entry.status).label}. Correct it:",
                     style = MaterialTheme.typography.bodyMedium)
                KilterAscentStatus.entries.forEach { status ->
                    androidx.compose.material3.TextButton(
                        onClick = { onSetStatus(status) },
                        modifier = Modifier.fillMaxWidth().testTag("kilter.setStatus.${status.name}"),
                        enabled = status.name != entry.status,
                    ) { Text(status.label) }
                }
            }
        },
        confirmButton = {
            androidx.compose.material3.TextButton(
                onClick = onDelete,
                modifier = Modifier.testTag("kilter.deleteAscent"),
            ) { Text("Delete…", color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = {
            androidx.compose.material3.TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
