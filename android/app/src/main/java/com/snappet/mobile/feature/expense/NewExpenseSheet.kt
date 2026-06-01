package com.snappet.mobile.feature.expense

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp

/**
 * Sheet to add — or edit — an [ExpenseRecord] in a group: title, amount, who paid, and which
 * participants share the cost (default all, equal split). When [record] is passed the form is
 * pre-filled and saving updates it in place. The payer defaults to the first participant so the
 * common case needs no picking. Mirrors iOS `NewExpenseSheet`.
 */
@Composable
fun NewExpenseSheet(
    group: ExpenseGroup,
    record: ExpenseRecord?,
    onSave: (title: String, amount: Double, payer: String, splitAmong: List<String>) -> Unit,
) {
    val participantsList = group.participants
    var title by remember { mutableStateOf(record?.title ?: "") }
    var amountText by remember { mutableStateOf(record?.amount?.let { formatAmount(it) } ?: "") }
    var payer by remember { mutableStateOf(record?.payer ?: participantsList.firstOrNull() ?: "") }
    val splitAmong = remember {
        mutableStateListOf<String>().apply { addAll(record?.participants ?: participantsList) }
    }

    val amount = amountText.toDoubleOrNull() ?: 0.0
    val canSave = title.trim().isNotEmpty() && amount > 0 && payer.isNotEmpty() && splitAmong.isNotEmpty()

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            if (record != null) "Edit Expense" else "New Expense",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            label = { Text("Title (e.g. Dinner)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("expense.expense.title"),
        )
        OutlinedTextField(
            value = amountText,
            onValueChange = { amountText = it },
            label = { Text("Amount") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth().testTag("expense.expense.amount"),
        )

        Text("Paid by", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        ParticipantPicker(
            participants = participantsList,
            selected = payer,
            tag = "expense.expense.payer",
            onSelect = { payer = it },
        )

        Text("Split equally among", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        participantsList.forEach { person ->
            val checked = splitAmong.contains(person)
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable {
                        if (checked) splitAmong.remove(person) else splitAmong.add(person)
                    }
                    .padding(vertical = 8.dp)
                    .testTag("expense.participant.$person"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(person, modifier = Modifier.weight(1f))
                if (checked) {
                    Icon(Icons.Filled.Check, contentDescription = "Included", tint = MaterialTheme.colorScheme.primary)
                }
            }
        }

        Button(
            onClick = {
                if (canSave) {
                    // Preserve the group's participant order for the stored split list.
                    val splitList = participantsList.filter { splitAmong.contains(it) }
                    onSave(title.trim(), amount, payer, splitList)
                }
            },
            enabled = canSave,
            modifier = Modifier.fillMaxWidth().testTag("expense.expense.save"),
        ) {
            Text("Save")
        }
    }
}
