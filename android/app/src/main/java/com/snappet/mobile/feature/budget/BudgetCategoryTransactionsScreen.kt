package com.snappet.mobile.feature.budget

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A list of the transactions logged against one category for the selected month, newest first.
 * Tapping a row's edit affordance opens the editor sheet. Back returns to the Budget root. Mirrors
 * iOS `BudgetCategoryTransactionsView`.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun BudgetCategoryTransactionsScreen(
    category: BudgetCategory,
    categories: List<BudgetCategory>,
    transactions: List<BudgetTransaction>,
    scope: MonthScope,
    onEdit: (BudgetTransaction, BudgetCategory, Double, String) -> Unit,
    onDelete: (BudgetTransaction) -> Unit,
    onExit: () -> Unit,
) {
    // Issue #86: staged by id, not object — after restore the sheet self-heals shut if the row is gone.
    var editingId by rememberSaveable { mutableStateOf<Long?>(null) }
    val editing = transactions.firstOrNull { it.id == editingId }
    // Issue #88: a row staged for deletion by long-press, pending confirmation.
    var confirmingDelete by remember { mutableStateOf<BudgetTransaction?>(null) }

    val rows = transactions
        .filter { it.categoryId == category.categoryId && scope.contains(it.date) }
        .sortedByDescending { it.date }

    ModuleScaffold(title = category.name, onExit = onExit) { padding ->
        if (rows.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("No transactions", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        "No spending logged for ${category.name} in ${scope.label}.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else {
            LazyColumn(
                Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(rows, key = { it.id }) { txn ->
                    TransactionRow(category = category, txn = txn,
                                   onEdit = { editingId = txn.id },
                                   onLongPress = { confirmingDelete = txn })
                }
            }
        }
    }

    editing?.let { txn ->
        ModalBottomSheet(onDismissRequest = { editingId = null }, sheetState = rememberModalBottomSheetState()) {
            AddTransactionSheet(categories = categories, existing = txn) { cat, amount, note ->
                editingId = null
                onEdit(txn, cat, amount, note)
            }
        }
    }

    confirmingDelete?.let { txn ->
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete this transaction?",
            message = "This permanently removes it; the month's totals recompute.",
            onConfirm = { confirmingDelete = null; onDelete(txn) },
            onDismiss = { confirmingDelete = null },
        )
    }
}

private val rowDateFmt = SimpleDateFormat("MMM d, yyyy", Locale.getDefault())

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TransactionRow(category: BudgetCategory, txn: BudgetTransaction, onEdit: () -> Unit, onLongPress: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            // Tap edits (as before); long-press stages a delete (issue #88).
            .combinedClickable(onClick = onEdit, onLongClick = onLongPress)
            .padding(12.dp)
            .testTag("budget.editTxn"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                txn.note.ifEmpty { category.name },
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                rowDateFmt.format(Date(txn.date)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(txn.amount.asCurrency(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        IconButton(onClick = onEdit) {
            Icon(Icons.Filled.Edit, contentDescription = "Edit transaction", tint = MaterialTheme.colorScheme.primary)
        }
    }
}
