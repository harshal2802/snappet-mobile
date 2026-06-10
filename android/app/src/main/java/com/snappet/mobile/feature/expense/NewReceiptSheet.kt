package com.snappet.mobile.feature.expense

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

/**
 * Sheet to add — or edit — an itemized **receipt** in a group: a list of line items, each shared by
 * its own set of people, plus tax and discount allocated proportionally. Scan a receipt with the
 * camera or paste its text to auto-fill the items, then tap the chips to choose who shares each line.
 * A live [ReceiptSummary] shows the running total and per-person split. Mirrors the iOS
 * `NewReceiptSheet`. The parent persists the result (computing the grand total via [ReceiptSplit]).
 */
@Composable
fun NewReceiptSheet(
    group: ExpenseGroup,
    record: ExpenseRecord?,
    onSave: (title: String, payer: String, items: List<ReceiptItem>, tax: Double, discount: Double) -> Unit,
) {
    val participants = group.participants
    var title by rememberSaveable { mutableStateOf(record?.title ?: "") }
    var payer by rememberSaveable { mutableStateOf(record?.payer ?: participants.firstOrNull() ?: "") }
    var taxText by rememberSaveable { mutableStateOf(record?.taxAmount?.takeIf { it > 0 }?.let { formatAmount(it) } ?: "") }
    var discountText by rememberSaveable { mutableStateOf(record?.discountAmount?.takeIf { it > 0 }?.let { formatAmount(it) } ?: "") }
    var showPaste by remember { mutableStateOf(false) }

    // The receipt kind used to tune parsing; AUTO resolves via ReceiptClassifier on scan/paste.
    var receiptType by rememberSaveable { mutableStateOf(ReceiptType.AUTO) }

    // Totals read off the most recent scan/paste, so the validation banner can cross-check the
    // edited items against what the receipt printed.
    var detectedSubtotal by remember { mutableStateOf<Double?>(null) }
    var detectedTax by remember { mutableStateOf<Double?>(null) }
    var detectedTotal by remember { mutableStateOf<Double?>(null) }
    var detectedItemCount by remember { mutableStateOf<Int?>(null) }

    // Issue #86: the line items are the OCR payoff — losing them to a rotation means re-scanning
    // the receipt — so they get a custom Saver, keyed by the record being edited (null = new).
    val items = rememberSaveable(record?.id, saver = ItemEditListSaver) {
        mutableStateListOf<ItemEdit>().apply {
            record?.items?.forEach { add(ItemEdit(it.name, formatAmount(it.price), it.assignees)) }
        }
    }

    val tax = taxText.toDoubleOrNull() ?: 0.0
    val discount = discountText.toDoubleOrNull() ?: 0.0
    val cleaned = items.map { ReceiptItem(it.name.trim(), it.price, it.assignees.toList()) }.filter { it.price > 0 }
    // Memoize the split + validation so they only recompute when their inputs actually change,
    // not on every recomposition (e.g. an unrelated state change).
    val result = remember(cleaned, tax, discount, participants) {
        ReceiptSplit.compute(cleaned, tax, discount, participants)
    }
    val report = remember(result, detectedSubtotal, detectedTax, detectedTotal, detectedItemCount) {
        ReceiptValidation.validate(
            result, detectedSubtotal, detectedTax, detectedTotal, detectedItemCount, cleaned.size,
        )
    }
    val showValidation = detectedTotal != null || report.overall != ReceiptValidation.Status.PASS

    fun applyParsed(parsed: ReceiptParser.ParsedReceipt) {
        parsed.items.forEach { items.add(ItemEdit(it.name, formatAmount(it.price), participants)) }
        // Accumulate (not overwrite) detected tax/discount so a second paste / multi-page scan
        // stays consistent with the way items append, and never clobbers a hand-typed value.
        if (parsed.discount > 0) {
            discountText = formatAmount((discountText.toDoubleOrNull() ?: 0.0) + parsed.discount)
        }
        parsed.tax?.let { taxText = formatAmount((taxText.toDoubleOrNull() ?: 0.0) + it) }
        if (title.isBlank()) title = "Receipt"
        detectedSubtotal = parsed.subtotal
        detectedTax = parsed.tax
        detectedTotal = parsed.total
        detectedItemCount = parsed.itemCount
    }

    // Parse with the selected type's profile; AUTO classifies the text and snaps the picker to it.
    fun parseAndApply(text: String) {
        if (text.isBlank()) return
        val resolved = receiptType.resolved(text)
        if (receiptType == ReceiptType.AUTO) receiptType = resolved
        applyParsed(ReceiptParser.parse(text, resolved.profile))
    }

    val scan = rememberReceiptScanner { text -> parseAndApply(text) }

    val canSave = title.trim().isNotEmpty() && payer.isNotEmpty() &&
        cleaned.any { it.assignees.isNotEmpty() }

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            if (record != null) "Edit Receipt" else "New Receipt",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            label = { Text("Title (e.g. Costco run)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("expense.receipt.title"),
        )

        Text("Paid by", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        ParticipantPicker(
            participants = participants,
            selected = payer,
            tag = "expense.receipt.payer",
            onSelect = { payer = it },
        )

        Text("Receipt type", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        ReceiptTypePicker(selected = receiptType, onSelect = { receiptType = it })

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(onClick = scan, modifier = Modifier.weight(1f).testTag("expense.receipt.scan")) {
                Icon(Icons.Filled.CameraAlt, contentDescription = null, modifier = Modifier.width(18.dp))
                Text(" Scan")
            }
            OutlinedButton(onClick = { showPaste = true }, modifier = Modifier.weight(1f).testTag("expense.receipt.paste")) {
                Icon(Icons.Filled.ContentPaste, contentDescription = null, modifier = Modifier.width(18.dp))
                Text(" Paste")
            }
        }

        if (showValidation) {
            ReceiptValidationBanner(report)
        }

        Text("Items (${items.size})", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        items.forEachIndexed { index, item ->
            ItemEditRow(item = item, participants = participants, onDelete = { items.removeAt(index) })
        }
        OutlinedButton(
            onClick = { items.add(ItemEdit("", "", participants)) },
            modifier = Modifier.fillMaxWidth().testTag("expense.receipt.addItem"),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.width(18.dp))
            Text(" Add item")
        }

        Text("Adjustments", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = discountText,
            onValueChange = { discountText = it },
            label = { Text("Discount") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth().testTag("expense.receipt.discount"),
        )
        OutlinedTextField(
            value = taxText,
            onValueChange = { taxText = it },
            label = { Text("Tax") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth().testTag("expense.receipt.tax"),
        )

        ReceiptSummary(result)

        Button(
            onClick = { if (canSave) onSave(title.trim(), payer, cleaned, tax, discount) },
            enabled = canSave,
            modifier = Modifier.fillMaxWidth().testTag("expense.receipt.save"),
        ) {
            Text("Save")
        }
    }

    if (showPaste) {
        PasteReceiptDialog(
            onDismiss = { showPaste = false },
            onAdd = { text -> showPaste = false; parseAndApply(text) },
        )
    }
}

/** Menu-style picker over the [ReceiptType]s, mirroring [ParticipantPicker]. */
@Composable
private fun ReceiptTypePicker(selected: ReceiptType, onSelect: (ReceiptType) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(
            onClick = { expanded = true },
            modifier = Modifier.fillMaxWidth().testTag("expense.receipt.type"),
        ) {
            Text(selected.displayName, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            ReceiptType.entries.forEach { type ->
                DropdownMenuItem(
                    text = { Text(type.displayName) },
                    onClick = { onSelect(type); expanded = false },
                    modifier = Modifier.testTag("expense.receipt.type.${type.name}"),
                )
            }
        }
    }
}

/** Mutable editing state for one line item (name, price text, and the set of assignees). */
private class ItemEdit(name: String, price: String, assignees: List<String>) {
    var name by mutableStateOf(name)
    var priceText by mutableStateOf(price)
    val assignees = mutableStateListOf<String>().apply { addAll(assignees) }
    val price: Double get() = priceText.toDoubleOrNull() ?: 0.0
}

/**
 * Saver for the receipt's item list (issue #86): [ItemEdit] holds `MutableState` fields, which
 * `autoSaver` can't bundle, so each item flattens to `[name, priceText, assignees...]` (plain
 * strings) and restore builds fresh [ItemEdit]s.
 */
private val ItemEditListSaver = listSaver<SnapshotStateList<ItemEdit>, ArrayList<String>>(
    save = { list ->
        list.map { item -> arrayListOf(item.name, item.priceText).apply { addAll(item.assignees) } }
    },
    restore = { saved ->
        saved.map { fields -> ItemEdit(fields[0], fields[1], fields.drop(2)) }.toMutableStateList()
    },
)

@Composable
private fun ItemEditRow(item: ItemEdit, participants: List<String>, onDelete: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = item.name,
                onValueChange = { item.name = it },
                label = { Text("Item") },
                singleLine = true,
                modifier = Modifier.weight(1f).testTag("expense.receipt.item.name"),
            )
            OutlinedTextField(
                value = item.priceText,
                onValueChange = { item.priceText = it },
                label = { Text("Price") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.width(110.dp).testTag("expense.receipt.item.price"),
            )
            IconButton(onClick = onDelete) {
                Icon(Icons.Filled.Delete, contentDescription = "Remove item")
            }
        }
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            participants.forEach { person ->
                val checked = item.assignees.contains(person)
                FilterChip(
                    selected = checked,
                    onClick = { if (checked) item.assignees.remove(person) else item.assignees.add(person) },
                    label = { Text(person) },
                    modifier = Modifier.testTag("expense.receipt.item.assign.$person"),
                )
            }
        }
    }
}

@Composable
private fun PasteReceiptDialog(onDismiss: () -> Unit, onAdd: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Paste receipt") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "One item per line. Lines ending in a price become items; SUBTOTAL / TAX / TOTAL and instant-savings lines are detected automatically.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    label = { Text("Receipt text") },
                    modifier = Modifier.fillMaxWidth().testTag("expense.receipt.pasteText"),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onAdd(text) }, modifier = Modifier.testTag("expense.receipt.pasteAdd")) {
                Text("Add items")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
