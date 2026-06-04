package com.snappet.mobile.feature.expense

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.SnappetAccents
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Read-only breakdown of a saved itemized receipt: the totals, the per-person split, and the item
 * list with who shares each line. An Edit action reopens it in `NewReceiptSheet`. Mirrors the iOS
 * `ReceiptDetailView`. Shown via local-state navigation from `GroupDetail`.
 */
@Composable
fun ReceiptDetail(
    group: ExpenseGroup,
    record: ExpenseRecord,
    onBack: () -> Unit,
    onEdit: () -> Unit,
) {
    val result = ReceiptSplit.compute(record.items, record.taxAmount, record.discountAmount, group.participants)
    ModuleScaffold(
        title = record.title,
        onExit = onBack,
        actions = {
            IconButton(onClick = onEdit, modifier = Modifier.testTag("expense.receipt.edit")) {
                Icon(Icons.Filled.Edit, contentDescription = "Edit receipt")
            }
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(Modifier.fillMaxWidth()) {
                        Text("Paid by", modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(record.payer, fontWeight = FontWeight.SemiBold)
                    }
                    Row(Modifier.fillMaxWidth()) {
                        Text("Date", modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(dateLabel(record.date))
                    }
                }
            }

            item { ReceiptSummary(result) }

            item {
                Text("Items (${record.items.size})", style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(record.items.size) { i ->
                val item = record.items[i]
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(Modifier.fillMaxWidth()) {
                        Text(item.name.ifEmpty { "Item" }, modifier = Modifier.weight(1f))
                        Text(money(item.price))
                    }
                    val unassigned = item.assignees.isEmpty()
                    Text(
                        assigneeLabel(item.assignees, group.participants),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (unassigned) SnappetAccents.Tomato else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/** Short, human label for an item's assignees relative to the group. Mirrors iOS `AssigneeSummary`. */
fun assigneeLabel(assignees: List<String>, participants: List<String>): String = when {
    assignees.isEmpty() -> "Unassigned"
    assignees.size == participants.size -> "Everyone"
    assignees.size <= 2 -> assignees.joinToString(" & ")
    else -> "${assignees.size} people"
}

private fun dateLabel(epochMillis: Long): String =
    SimpleDateFormat("MMM d, yyyy", Locale.getDefault()).format(Date(epochMillis))

private fun money(value: Double): String = "$" + String.format("%.2f", value)
