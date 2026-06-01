package com.snappet.mobile.feature.expense

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag

/**
 * A menu-style picker over [participants]: an [OutlinedButton] tagged [tag] showing the current
 * [selected] name; tapping opens a [DropdownMenu] whose items are each a [DropdownMenuItem] with a
 * plain [Text] of the participant name (so a UI test can match the option by its name). Mirrors the
 * iOS `Picker(pickerStyle: .menu)`.
 */
@Composable
fun ParticipantPicker(
    participants: List<String>,
    selected: String,
    tag: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(
            onClick = { expanded = true },
            modifier = Modifier.fillMaxWidth().testTag(tag),
        ) {
            Text(selected.ifEmpty { "Select" }, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            participants.forEach { person ->
                DropdownMenuItem(
                    text = { Text(person) },
                    onClick = {
                        onSelect(person)
                        expanded = false
                    },
                    modifier = Modifier.testTag("$tag.option.$person"),
                )
            }
        }
    }
}

/** Format a Double amount without trailing ".0" so edit pre-fills read like the typed value. */
fun formatAmount(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
