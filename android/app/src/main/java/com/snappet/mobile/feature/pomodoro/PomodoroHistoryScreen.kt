package com.snappet.mobile.feature.pomodoro

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material3.Icon
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
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Full focus-session history, newest first, grouped by calendar day (each header carrying that
 * day's session count + total minutes), with the 7-day chart on top. Mirrors iOS
 * `PomodoroHistoryView`. `onExit` returns to the timer root.
 */
@Composable
fun PomodoroHistoryScreen(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val sessions by container.database.pomodoroDao().allFlow().collectAsState(initial = emptyList())
    val grouped = sessions.groupBy { PomodoroStats.startOfDay(it.completedAt) }.toSortedMap(compareByDescending { it })
    val dayFmt = SimpleDateFormat("EEEE, MMM d", Locale.getDefault())
    val timeFmt = SimpleDateFormat("h:mm a", Locale.getDefault())

    ModuleScaffold(title = "History", onExit = onExit) { padding ->
        if (sessions.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No focus sessions yet", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Complete a focus block and it will appear here.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp),
                    )
                }
            }
        } else {
            LazyColumn(
                Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item { PomodoroFocusChart(PomodoroStats.last7Days(sessions), Modifier.padding(vertical = 8.dp)) }
                for ((day, daySessions) in grouped) {
                    item {
                        Row(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 4.dp)) {
                            Text(dayFmt.format(Date(day)), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Text(
                                "${daySessions.size} · ${daySessions.sumOf { it.minutes }} min",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                    items(daySessions, key = { it.id }) { session ->
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("pomodoro.historyRow"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Filled.Psychology, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            Text("  ${timeFmt.format(Date(session.completedAt))}", modifier = Modifier.weight(1f).padding(start = 8.dp))
                            Text(
                                "${session.minutes} min",
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}
