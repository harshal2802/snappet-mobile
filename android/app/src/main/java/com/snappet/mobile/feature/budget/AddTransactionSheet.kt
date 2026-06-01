package com.snappet.mobile.feature.budget

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

/**
 * Sheet to log a spend against a category, or edit an existing one. When [existing] is non-null the
 * fields are pre-filled and the title switches to "Edit". The category defaults to the first one (so
 * an amount-only flow works) or the edited transaction's category. Reports
 * `(category, amount, note)` on save. Mirrors iOS `AddTransactionView`.
 */
@Composable
fun AddTransactionSheet(
    categories: List<BudgetCategory>,
    existing: BudgetTransaction?,
    onSave: (BudgetCategory, Double, String) -> Unit,
) {
    var selectedId by remember {
        mutableStateOf(existing?.categoryId ?: categories.firstOrNull()?.categoryId)
    }
    var amount by remember { mutableStateOf(existing?.amount?.toString() ?: "") }
    var note by remember { mutableStateOf(existing?.note ?: "") }

    val parsedAmount = amount.trim().toDoubleOrNull()
    val selectedCategory = categories.firstOrNull { it.categoryId == selectedId }
    val isValid = selectedCategory != null && (parsedAmount ?: 0.0) > 0.0

    Column(
        Modifier.fillMaxWidth().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            if (existing != null) "Edit Transaction" else "Add Transaction",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )

        if (categories.size > 1) {
            Text("Category", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                categories.forEach { category ->
                    FilterChip(
                        selected = category.categoryId == selectedId,
                        onClick = { selectedId = category.categoryId },
                        label = { Text(category.name) },
                        modifier = Modifier.testTag("budget.pickCategory.${category.name}"),
                    )
                }
            }
        }

        OutlinedTextField(
            value = amount,
            onValueChange = { amount = it },
            label = { Text("Amount") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth().testTag("budget.txnAmount"),
        )
        OutlinedTextField(
            value = note,
            onValueChange = { note = it },
            label = { Text("Note (optional)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("budget.txnNote"),
        )
        Button(
            onClick = { if (isValid) onSave(selectedCategory!!, parsedAmount!!, note.trim()) },
            enabled = isValid,
            modifier = Modifier.fillMaxWidth().testTag("budget.txnSave"),
        ) {
            Text("Save")
        }
    }
}
