package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch

/**
 * Kilter preferences: the default board + angle that seed browsing, how grades render, and a
 * destructive "clear logged history". Mirrors the iOS `KilterSettingsView`. `onExit` returns to the
 * catalog.
 */
@Composable
fun KilterSettingsScreen(catalog: KilterCatalog, dao: KilterDao, onExit: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val logs by dao.logsFlow().collectAsState(initial = emptyList())

    var layoutId by remember { mutableStateOf(KilterSettings.layout(context)) }
    var angle by remember { mutableStateOf(KilterSettings.angle(context)) }
    var gradeFormat by remember { mutableStateOf(KilterSettings.gradeFormat(context)) }
    var apiLevel by remember { mutableStateOf(KilterSettings.apiLevel(context)) }
    var layoutMenu by remember { mutableStateOf(false) }
    var angleMenu by remember { mutableStateOf(false) }
    var confirmingClear by remember { mutableStateOf(false) }

    val layouts = remember { catalog.layouts() }
    val angles = remember { catalog.angles() }

    ModuleScaffold(title = "Kilter Settings", onExit = onExit) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Defaults", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Box {
                OutlinedButton(onClick = { layoutMenu = true }) {
                    Text("Board: ${layouts.firstOrNull { it.id == layoutId }?.name ?: "—"}")
                }
                DropdownMenu(expanded = layoutMenu, onDismissRequest = { layoutMenu = false }) {
                    layouts.forEach { l ->
                        DropdownMenuItem(text = { Text(l.name) }, onClick = {
                            layoutId = l.id; KilterSettings.setLayout(context, l.id); layoutMenu = false
                        })
                    }
                }
            }
            Box {
                OutlinedButton(onClick = { angleMenu = true }) { Text("Angle: ${angle}°") }
                DropdownMenu(expanded = angleMenu, onDismissRequest = { angleMenu = false }) {
                    angles.forEach { a ->
                        DropdownMenuItem(text = { Text("${a}°") }, onClick = {
                            angle = a; KilterSettings.setAngle(context, a); angleMenu = false
                        })
                    }
                }
            }

            HorizontalDivider()
            Text("Grades", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KilterGradeFormat.entries.forEach { fmt ->
                    FilterChip(
                        selected = gradeFormat == fmt,
                        onClick = { gradeFormat = fmt; KilterSettings.setGradeFormat(context, fmt) },
                        label = { Text(fmt.label) },
                        modifier = Modifier.testTag("kilter.settings.gradeFormat.${fmt.name}"),
                    )
                }
            }

            HorizontalDivider()
            Text("Board protocol", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KilterProtocol.ApiLevel.entries.forEach { level ->
                    FilterChip(
                        selected = apiLevel == level,
                        onClick = { apiLevel = level; KilterSettings.setApiLevel(context, level) },
                        label = { Text(level.label) },
                        modifier = Modifier.testTag("kilter.settings.apiLevel.${level.name}"),
                    )
                }
            }
            Text("Almost all boards use Standard. If you connect but the wrong holds light up, switch "
                + "to Legacy — it's for older controllers.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            HorizontalDivider()
            Button(
                onClick = { confirmingClear = true },
                enabled = logs.isNotEmpty(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer),
                modifier = Modifier.testTag("kilter.settings.clearHistory"),
            ) { Text("Clear logged history") }
            Text("Removes all ${logs.size} logged ascents and sessions. Saved climbs are kept.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        if (confirmingClear) {
            AlertDialog(
                onDismissRequest = { confirmingClear = false },
                title = { Text("Clear all logged history?") },
                text = { Text("This permanently deletes your ascent log and sessions. It can't be undone.") },
                confirmButton = {
                    TextButton(onClick = {
                        confirmingClear = false
                        scope.launch { dao.clearLogs(); dao.clearSessions() }
                    }) { Text("Clear") }
                },
                dismissButton = { TextButton(onClick = { confirmingClear = false }) { Text("Cancel") } },
            )
        }
    }
}
