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
 * The opt-in empty state shown when no catalog is installed (issue #42). Snappet ships no Aurora data;
 * the user brings the climb catalog onto this device once — by importing a `.sqlite3` they built
 * themselves via Storage Access Framework (Phase 1) — and from then on browse/detail/log/illuminate
 * work offline. Surfaces Aurora's Terms of Use + a link before any fetch. Mirrors the iOS
 * `KilterCatalogSyncView`.
 */
@Composable
fun KilterCatalogSyncScreen(onInstalled: () -> Unit, onExit: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    var phase by remember { mutableStateOf<InstallPhase>(InstallPhase.Idle) }

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

            Button(
                onClick = { picker.launch(arrayOf("*/*")) },
                enabled = phase != InstallPhase.Working,
                modifier = Modifier.fillMaxWidth().testTag("kilter.catalog.import"),
            ) { Text("Import catalog file…") }

            // Phase 2 (AuroraSyncProvider) — present but inert until the endpoint/account/ToU questions
            // in issue #42 are answered.
            OutlinedButton(
                onClick = {},
                enabled = false,
                modifier = Modifier.fillMaxWidth().testTag("kilter.catalog.sync"),
            ) { Text("Sync from Kilter (coming soon)") }

            Text(
                "No catalog file yet? Build one with the boardlib tool — see the Kilter tooling " +
                    "README (tools/kilter).",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}
