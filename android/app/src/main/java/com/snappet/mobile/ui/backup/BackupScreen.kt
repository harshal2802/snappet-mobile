package com.snappet.mobile.ui.backup

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.snappet.mobile.core.SnappetBackup
import com.snappet.mobile.ui.LocalAppContainer
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Backup & restore (issue #84): exports every module's data — journals, habits, expenses,
 * budgets, tip history, workout sessions, Kilter logs/sessions/created climbs, usage —
 * as ONE JSON file the user places via SAF, and imports such a file back, replacing the
 * store's contents transactionally. Fully on-device (the Kilter catalog import pattern);
 * also the phone-to-phone migration path for an app with no accounts.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupScreen(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var status by remember { mutableStateOf<String?>(null) }
    var pendingImportText by remember { mutableStateOf<String?>(null) }

    val exporter = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            status = runCatching {
                val payload = container.backup.exportPayload()
                val text = SnappetBackup.encode(payload)
                context.contentResolver.openOutputStream(uri)?.use { stream ->
                    stream.write(text.toByteArray(Charsets.UTF_8))
                } ?: error("Couldn't open the chosen location.")
                val rows = payload.tables.values.sumOf { it.size }
                container.core.log("backup", "export",
                    "Exported $rows records across ${payload.tables.size} tables")
                "Exported $rows records across ${payload.tables.size} tables."
            }.getOrElse { "Export failed: ${it.message ?: "unknown error"}" }
        }
    }

    val importer = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    stream.readBytes().toString(Charsets.UTF_8)
                } ?: error("Couldn't read the chosen file.")
            }.fold(
                onSuccess = { pendingImportText = it },   // confirm before replacing everything
                onFailure = { status = "Import failed: ${it.message ?: "unknown error"}" },
            )
        }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Backup & restore") },
            navigationIcon = {
                IconButton(onClick = onExit, modifier = Modifier.testTag("backup.back")) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Export", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Saves one file with everything in Snappet — every module's history. " +
                            "Your data stays on devices you choose; nothing is uploaded.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Button(
                        onClick = {
                            val stamp = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
                            exporter.launch("snappet-backup-$stamp.json")
                        },
                        modifier = Modifier.testTag("backup.export"),
                    ) {
                        Icon(Icons.Filled.FileDownload, contentDescription = null)
                        Text("  Export Snappet data")
                    }
                }
            }

            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Import", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Restores a Snappet backup file, replacing everything currently in the app.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Button(
                        onClick = { importer.launch(arrayOf("application/json", "text/plain", "*/*")) },
                        modifier = Modifier.testTag("backup.import"),
                    ) {
                        Icon(Icons.Filled.FileUpload, contentDescription = null)
                        Text("  Import a backup")
                    }
                }
            }

            status?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium,
                     modifier = Modifier.testTag("backup.status"))
            }
        }
    }

    pendingImportText?.let { text ->
        AlertDialog(
            onDismissRequest = { pendingImportText = null },
            title = { Text("Replace all data?") },
            text = {
                Text("Importing replaces everything currently in Snappet with the backup's " +
                     "contents. This can't be undone.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingImportText = null
                        scope.launch {
                            status = runCatching {
                                val payload = SnappetBackup.decode(text)
                                val summary = container.backup.importPayload(payload)
                                container.core.log("backup", "import",
                                    "Imported ${summary.rows} records across ${summary.tables} tables")
                                "Imported ${summary.rows} records across ${summary.tables} tables."
                            }.getOrElse { "Import failed: ${it.message ?: "unknown error"}" }
                        }
                    },
                    modifier = Modifier.testTag("backup.confirmImport"),
                ) { Text("Replace") }
            },
            dismissButton = {
                TextButton(onClick = { pendingImportText = null }) { Text("Cancel") }
            },
        )
    }
}
