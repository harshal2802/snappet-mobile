package com.snappet.mobile.feature.kilter

import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
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
fun KilterSettingsScreen(
    catalog: KilterCatalog,
    dao: KilterDao,
    onCatalogChanged: () -> Unit,
    onExit: () -> Unit,
) {
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

    // Catalog library (issue #42): list downloads, switch active, remove individually, download/import.
    var libraryVersion by remember { mutableStateOf(0) }
    val catalogs = remember(libraryVersion) { installedKilterCatalogs(context) }
    val activeId = remember(libraryVersion) { activeKilterCatalogId(context) }
    var showDownload by remember { mutableStateOf(false) }
    var catalogError by remember { mutableStateOf<String?>(null) }
    val catalogPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                installKilterCatalog(context, FileImportProvider(context, uri))
                libraryVersion++
                onCatalogChanged()
            } catch (e: Exception) {
                catalogError = e.message
            }
        }
    }

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
            Text("Downloaded catalogs", style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary)
            if (catalogs.isEmpty()) {
                Text("No catalog installed", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                catalogs.forEach { c ->
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            if (c.id != activeId) { activateKilterCatalog(context, c.id); libraryVersion++; onCatalogChanged() }
                        },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        RadioButton(selected = c.id == activeId, onClick = {
                            if (c.id != activeId) { activateKilterCatalog(context, c.id); libraryVersion++; onCatalogChanged() }
                        })
                        Column(Modifier.weight(1f)) {
                            Text(c.displayName, style = MaterialTheme.typography.bodyMedium)
                            Text("${c.meta.climbCount} climbs · ${Formatter.formatShortFileSize(context, c.meta.sizeBytes)}",
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        TextButton(onClick = { removeKilterCatalog(context, c.id); libraryVersion++; onCatalogChanged() }) {
                            Text("Remove", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
            catalogError?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { catalogError = null; showDownload = true },
                    modifier = Modifier.testTag("kilter.settings.download"),
                ) { Text("Download from Kilter…") }
                OutlinedButton(
                    onClick = { catalogError = null; catalogPicker.launch(arrayOf("*/*")) },
                    modifier = Modifier.testTag("kilter.settings.import"),
                ) { Text("Import file…") }
            }
            Text("Snappet doesn't ship Kilter's catalog — it lives only on this device. Tap one to make it "
                + "active, Remove to delete. Removing keeps your logged ascents and saved climbs.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

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

        if (showDownload) {
            KilterCatalogDownloadSheet(
                onInstalled = { libraryVersion++; onCatalogChanged() },
                onDismiss = { showDownload = false },
            )
        }
    }
}
