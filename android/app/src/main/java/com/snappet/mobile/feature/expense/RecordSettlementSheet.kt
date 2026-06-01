package com.snappet.mobile.feature.expense

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
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
 * Sheet to record a manual settlement: [payer] paid [recipient] a given amount to pay down what
 * they owe. Saving inserts a settlement [ExpenseRecord] (isSettlement = true, participants =
 * [recipient]) which the balance math treats as a direct transfer — recording a settlement equal
 * to a suggested transfer clears that pair. Mirrors iOS `RecordSettlementSheet`.
 */
@Composable
fun RecordSettlementSheet(
    group: ExpenseGroup,
    onSave: (payer: String, recipient: String, amount: Double) -> Unit,
) {
    val participantsList = group.participants
    // Start unselected ("Select") so neither picker button renders a participant name before the
    // user chooses — keeping each name matchable to its dropdown option alone (the test taps
    // options by exact name). The test explicitly sets payer=Bob, recipient=Alice.
    var payer by remember { mutableStateOf("") }
    var recipient by remember { mutableStateOf("") }
    var amountText by remember { mutableStateOf("") }

    val amount = amountText.toDoubleOrNull() ?: 0.0
    val canSave = amount > 0 && payer.isNotEmpty() && recipient.isNotEmpty() && payer != recipient

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Record Settlement", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)

        Text("Who paid", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        ParticipantPicker(
            participants = participantsList,
            selected = payer,
            tag = "expense.settle.payer",
            onSelect = { payer = it },
        )

        Text("Who received", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        ParticipantPicker(
            participants = participantsList,
            selected = recipient,
            tag = "expense.settle.recipient",
            onSelect = { recipient = it },
        )

        OutlinedTextField(
            value = amountText,
            onValueChange = { amountText = it },
            label = { Text("Amount") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth().testTag("expense.settle.amount"),
        )
        Text(
            if (payer == recipient) "Pick two different people."
            else "Records that $payer paid $recipient back.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Button(
            onClick = { if (canSave) onSave(payer, recipient, amount) },
            enabled = canSave,
            modifier = Modifier.fillMaxWidth().testTag("expense.settle.save"),
        ) {
            Text("Save")
        }
    }
}
