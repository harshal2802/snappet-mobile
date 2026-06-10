package com.snappet.mobile.feature.habit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import com.snappet.mobile.ui.theme.SnappetAccents
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Reusable editor sheet for a habit's name + symbol, used for both create ([existing] == null) and
 * edit. On save it hands the trimmed name + chosen symbol back to [onSave]; Save is disabled while
 * the name is blank. Mirrors iOS `HabitEditorView`.
 */
@Composable
fun HabitEditorSheet(existing: Habit?, onDelete: (() -> Unit)? = null, onSave: (String, String) -> Unit) {
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var symbol by remember { mutableStateOf(existing?.symbol ?: HabitSymbols.default) }
    val trimmed = name.trim()

    Column(
        Modifier.fillMaxWidth().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            if (existing != null) "Edit Habit" else "New Habit",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("Name") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("habit.nameField"),
        )

        Text("Symbol", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 56.dp),
            modifier = Modifier.fillMaxWidth().height(160.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(HabitSymbols.all) { sym ->
                val selected = sym == symbol
                Box(
                    Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (selected) SnappetAccents.Leaf.copy(alpha = 0.2f) else Color.Transparent)
                        .testTag("habit.symbol.$sym"),
                    contentAlignment = Alignment.Center,
                ) {
                    IconButton(onClick = { symbol = sym }) {
                        Icon(
                            HabitSymbols.icon(sym),
                            contentDescription = sym,
                            tint = if (selected) SnappetAccents.Leaf else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        }

        Button(
            onClick = { if (trimmed.isNotEmpty()) onSave(trimmed, symbol) },
            enabled = trimmed.isNotEmpty(),
            modifier = Modifier.fillMaxWidth().testTag("habit.save"),
        ) {
            Text(if (existing != null) "Save" else "Add")
        }

        // Issue #88: a habit (and its history) is finally deletable — confirm upstream.
        if (existing != null && onDelete != null) {
            androidx.compose.material3.TextButton(
                onClick = onDelete,
                modifier = Modifier.fillMaxWidth().testTag("habit.delete"),
            ) {
                Text("Delete habit…", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}
