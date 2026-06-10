package com.snappet.mobile.feature.tip

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import kotlinx.coroutines.launch
import com.snappet.mobile.ui.ModuleScaffold
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Past tip calculations, newest first. Each row shows the bill + tip% + people on top and the total
 * + date below. Mirrors iOS `TipHistoryView`. `onExit` returns to the calculator root.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TipHistoryScreen(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()
    val calculations by container.database.tipDao().allFlow().collectAsState(initial = emptyList())
    val dateFmt = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())
    // A row staged for deletion by a long-press (issue #88).
    var pendingDelete by remember { mutableStateOf<TipCalculation?>(null) }

    ModuleScaffold(title = "History", onExit = onExit) { padding ->
        if (calculations.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No history yet", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Calculations you make appear here.",
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
                items(calculations, key = { it.id }) { calc ->
                    Column(
                        Modifier.fillMaxWidth()
                            // Long-press to delete — the suite's secondary-action idiom.
                            .combinedClickable(onClick = {}, onLongClick = { pendingDelete = calc })
                            .padding(vertical = 8.dp).testTag("tip.historyRow"),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(currency(calc.bill), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Text(
                                "${calc.tipPct.roundToInt()}% · ${calc.people}p",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "Total ${currency(calc.total)}",
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                dateFmt.format(Date(calc.createdAt)),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }

    pendingDelete?.let { calc ->
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete this calculation?",
            message = "This permanently removes it from your history.",
            onConfirm = {
                pendingDelete = null
                scope.launch { container.database.tipDao().delete(calc) }
            },
            onDismiss = { pendingDelete = null },
        )
    }
}
