package com.snappet.mobile.feature.kilter

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch

private sealed interface InstallPhase {
    data object Idle : InstallPhase
    data object Working : InstallPhase
    data class Failed(val message: String) : InstallPhase
}

/**
 * The opt-in empty state shown when no catalog is installed (issue #42; emphasis reversed in #94).
 * Snappet ships no Aurora data; the user brings the climb catalog onto this device once — primarily
 * by downloading it from the user-configured hosted dataset (trimmed on-device by their filters),
 * or secondarily by importing a `.sqlite3` catalog file they already have via Storage Access
 * Framework — and from then on browse/detail/log/illuminate work offline. Surfaces Aurora's Terms
 * of Use + a link before any fetch. Mirrors the iOS `KilterCatalogSyncView` (whose first-run order
 * is tracked separately).
 */
@Composable
fun KilterCatalogSyncScreen(onInstalled: () -> Unit, onExit: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    var phase by remember { mutableStateOf<InstallPhase>(InstallPhase.Idle) }
    var showDownload by remember { mutableStateOf(false) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            phase = InstallPhase.Working
            scope.launch {
                phase = try {
                    installKilterCatalog(context, FileImportProvider(context, uri))
                    onInstalled()
                    InstallPhase.Idle
                } catch (e: Exception) {
                    InstallPhase.Failed(e.message ?: "Import failed")
                }
            }
        }
    }

    ModuleScaffold(title = "Kilter Board", onExit = onExit) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(24.dp)
                .testTag("kilter.catalog.sync.empty"),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Get the climb catalog", style = MaterialTheme.typography.headlineSmall)
            Text(
                "Snappet doesn't ship Kilter's climb catalog. Bring it onto this device once, then " +
                    "browse, log, and illuminate offline from then on.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )

            Surface(
                color = MaterialTheme.colorScheme.surfaceVariant,
                shape = MaterialTheme.shapes.medium,
            ) {
                Column(
                    Modifier.fillMaxWidth().padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        "The catalog is Aurora Climbing's data, governed by their Terms of Use. It " +
                            "stays on this device — Snappet never uploads it.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    TextButton(
                        onClick = { uriHandler.openUri("https://kilterboardapp.com/terms-of-use") },
                        modifier = Modifier.testTag("kilter.catalog.terms"),
                    ) { Text("Aurora Climbing Terms of Use") }
                }
            }

            when (val p = phase) {
                InstallPhase.Working -> LinearProgressIndicator(Modifier.fillMaxWidth())
                is InstallPhase.Failed -> Text(
                    p.message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.testTag("kilter.catalog.error"),
                )
                InstallPhase.Idle -> {}
            }

            // Issue #94: Download leads — it's the path that works on a phone. Importing a
            // catalog file you already have is the secondary, power-user route.
            Button(
                onClick = { showDownload = true },
                enabled = phase != InstallPhase.Working,
                modifier = Modifier.fillMaxWidth().testTag("kilter.catalog.sync"),
            ) { Text("Download from Kilter…") }

            OutlinedButton(
                onClick = { picker.launch(arrayOf("*/*")) },
                enabled = phase != InstallPhase.Working,
                modifier = Modifier.fillMaxWidth().testTag("kilter.catalog.import"),
            ) { Text("Import catalog file…") }

            Text(
                "Download fetches the catalog from a hosted dataset and trims it on-device with " +
                    "your filters. Import installs a catalog file you already have.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }

        if (showDownload) {
            KilterCatalogDownloadSheet(
                onInstalled = onInstalled,
                onDismiss = { showDownload = false },
            )
        }
    }
}
