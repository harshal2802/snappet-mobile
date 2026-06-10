package com.snappet.mobile.feature.expense

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Sheet to create — or edit — an [ExpenseGroup]: a name plus an editable list of participant names.
 * At least two non-empty, distinct participants are required to save. When [existing] is passed the
 * form is pre-filled and saving updates it in place. Mirrors iOS `NewGroupSheet`.
 */
@Composable
fun NewGroupSheet(
    existing: ExpenseGroup?,
    suggestions: List<String> = emptyList(),
    onSave: (name: String, participants: List<String>) -> Unit,
) {
    var name by remember { mutableStateOf(existing?.name ?: "") }
    // Editing: pre-fill existing names. Creating: two empty slots to fill in.
    val participants = remember {
        mutableStateListOf<String>().apply {
            addAll(existing?.participants ?: listOf("", ""))
        }
    }

    val cleaned = participants.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
    val canSave = name.trim().isNotEmpty() && cleaned.size >= 2

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            if (existing != null) "Edit Group" else "New Group",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("Name (e.g. Trip, Roommates)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("expense.group.name"),
        )

        Text("Participants", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        participants.forEachIndexed { index, value ->
            OutlinedTextField(
                value = value,
                onValueChange = { participants[index] = it },
                label = { Text("Participant ${index + 1}") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("expense.group.participant.$index"),
            )
        }
        TextButton(
            onClick = { participants.add("") },
            modifier = Modifier.testTag("expense.group.addParticipant"),
        ) {
            Icon(Icons.Filled.AddCircle, contentDescription = null)
            Text("  Add Participant")
        }

        // Known names from other groups — one tap fills the next empty slot instead of
        // retyping (issue #88).
        val remaining = suggestions.filter { s -> participants.none { it.trim().equals(s, ignoreCase = true) } }
        if (remaining.isNotEmpty()) {
            Text("Known names", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(remaining.size) { i ->
                    val suggestion = remaining[i]
                    androidx.compose.material3.SuggestionChip(
                        onClick = {
                            val empty = participants.indexOfFirst { it.isBlank() }
                            if (empty >= 0) participants[empty] = suggestion else participants.add(suggestion)
                        },
                        label = { Text(suggestion) },
                        modifier = Modifier.testTag("expense.group.suggest.$suggestion"),
                    )
                }
            }
        }
        Text(
            "Add at least two people to split expenses between.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Button(
            onClick = { if (canSave) onSave(name.trim(), cleaned) },
            enabled = canSave,
            modifier = Modifier.fillMaxWidth().testTag("expense.group.save"),
        ) {
            Text("Save")
        }
    }
}
