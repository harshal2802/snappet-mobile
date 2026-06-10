package com.snappet.mobile.feature.budget

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

/**
 * Add/edit sheet for a budget category. [existing] == null means "add new"; otherwise the fields are
 * pre-filled for editing. Reports `(name, monthlyLimit)` on save. Save is disabled until the name is
 * non-blank and the limit parses to a positive number. Mirrors iOS `BudgetCategoryEditor`.
 *
 * The text fields are tagged `Name` / `Amount` (capitalised) to match the shared iOS test contract.
 */
@Composable
fun BudgetCategoryEditor(existing: BudgetCategory?, onDelete: (() -> Unit)? = null, onSave: (String, Double) -> Unit) {
    // Issue #86: drafts survive rotation; keyed by category so switching records doesn't restore a stale draft.
    var name by rememberSaveable(existing?.categoryId) { mutableStateOf(existing?.name ?: "") }
    var limit by rememberSaveable(existing?.categoryId) { mutableStateOf(existing?.monthlyLimit?.toString() ?: "") }
    val trimmed = name.trim()
    val parsedLimit = limit.trim().toDoubleOrNull()
    val isValid = trimmed.isNotEmpty() && (parsedLimit ?: 0.0) > 0.0

    Column(
        Modifier.fillMaxWidth().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            if (existing != null) "Edit Category" else "New Category",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("Name") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("Name"),
        )
        OutlinedTextField(
            value = limit,
            onValueChange = { limit = it },
            label = { Text("Amount") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth().testTag("Amount"),
        )
        Button(
            onClick = { if (isValid) onSave(trimmed, parsedLimit!!) },
            enabled = isValid,
            modifier = Modifier.fillMaxWidth().testTag("Save"),
        ) {
            Text("Save")
        }

        // Issue #88: a category is deletable — the cascade is confirmed upstream with
        // its transaction count.
        if (existing != null && onDelete != null) {
            androidx.compose.material3.TextButton(
                onClick = onDelete,
                modifier = Modifier.fillMaxWidth().testTag("budget.deleteCategory"),
            ) {
                Text("Delete category…", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}
