package com.snappet.mobile.feature.tip

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale
import kotlin.math.ceil

private enum class TipScreen { ROOT, HISTORY }

/**
 * Root entry for the Tip Calculator mini-app: enter a bill, pick a tip percentage, split between
 * people with an optional round-up, and see live currency-formatted results. Committing records a
 * [TipCalculation] (browsable from History) and logs one usage event. Presets are user-editable and
 * persist in SharedPreferences. Mirrors the iOS `TipRootView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TipRoot(onExit: () -> Unit) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()

    var screen by remember { mutableStateOf(TipScreen.ROOT) }
    var showPresetEditor by remember { mutableStateOf(false) }

    var billText by remember { mutableStateOf("") }
    var tipPercent by remember { mutableStateOf(18) }
    var splitCount by remember { mutableStateOf(1) }
    var roundUp by remember { mutableStateOf(false) }
    val presets = remember { mutableStateListOf(*TipSettings.presets(context).toTypedArray()) }

    val bill = billText.toDoubleOrNull() ?: 0.0
    val rawTip = (if (bill > 0) bill else 0.0) * tipPercent / 100.0
    val rawTotal = (if (bill > 0) bill else 0.0) + rawTip
    val total = if (roundUp) ceil(rawTotal) else rawTotal
    val tipAmount = (total - (if (bill > 0) bill else 0.0)).coerceAtLeast(0.0)
    val effectiveTipPct = if (bill > 0) tipAmount / bill * 100.0 else tipPercent.toDouble()
    val perPerson = total / maxOf(1, splitCount)

    fun commit() {
        if (bill <= 0) return
        scope.launch {
            container.database.tipDao().insert(
                TipCalculation(
                    bill = bill,
                    tipPct = effectiveTipPct,
                    people = splitCount,
                    tipAmount = tipAmount,
                    total = total,
                    createdAt = System.currentTimeMillis(),
                )
            )
            container.core.log("tip", "calc", "Tip on ${currency(bill)}", tipAmount)
        }
    }

    when (screen) {
        TipScreen.HISTORY -> TipHistoryScreen(onExit = { screen = TipScreen.ROOT })
        TipScreen.ROOT -> ModuleScaffold(
            title = "Tip Calculator",
            onExit = onExit,
            actions = {
                IconButton(onClick = { screen = TipScreen.HISTORY }, modifier = Modifier.testTag("tip.history")) {
                    Icon(Icons.Filled.History, contentDescription = "History")
                }
            },
        ) { padding ->
            TipBody(
                padding = padding,
                billText = billText,
                onBillChange = { billText = it.filter { c -> c.isDigit() || c == '.' } },
                presets = presets,
                tipPercent = tipPercent,
                onSelectPreset = { tipPercent = it },
                splitCount = splitCount,
                onSplitChange = { splitCount = it.coerceIn(1, 20) },
                roundUp = roundUp,
                onRoundUpChange = { roundUp = it },
                tipAmount = tipAmount,
                total = total,
                perPerson = perPerson,
                onEditPresets = { showPresetEditor = true },
                onCommit = { commit() },
            )
        }
    }

    if (showPresetEditor) {
        ModalBottomSheet(
            onDismissRequest = { showPresetEditor = false },
            sheetState = rememberModalBottomSheetState(),
        ) {
            PresetEditorSheet(
                presets = presets,
                onChange = { index, value ->
                    val v = value.coerceIn(TipSettings.presetRange)
                    presets[index] = v
                    TipSettings.setPreset(context, index, v)
                },
                onDone = { showPresetEditor = false },
            )
        }
    }
}

@Composable
private fun TipBody(
    padding: PaddingValues,
    billText: String,
    onBillChange: (String) -> Unit,
    presets: List<Int>,
    tipPercent: Int,
    onSelectPreset: (Int) -> Unit,
    splitCount: Int,
    onSplitChange: (Int) -> Unit,
    roundUp: Boolean,
    onRoundUpChange: (Boolean) -> Unit,
    tipAmount: Double,
    total: Double,
    perPerson: Double,
    onEditPresets: () -> Unit,
    onCommit: () -> Unit,
) {
    Column(
        Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text("Bill", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = billText,
            onValueChange = onBillChange,
            label = { Text("Amount") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth().testTag("tip.bill"),
        )

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Tip", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            OutlinedButton(onClick = onEditPresets, modifier = Modifier.testTag("tip.editPresets")) {
                Text("Edit presets")
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            presets.forEachIndexed { index, preset ->
                val selected = preset == tipPercent
                if (selected) {
                    Button(onClick = { onSelectPreset(preset) }, modifier = Modifier.weight(1f).testTag("tip.preset.$index")) {
                        Text("$preset%")
                    }
                } else {
                    FilledTonalButton(onClick = { onSelectPreset(preset) }, modifier = Modifier.weight(1f).testTag("tip.preset.$index")) {
                        Text("$preset%")
                    }
                }
            }
        }

        Text("Split", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Row(Modifier.fillMaxWidth().testTag("tip.people"), verticalAlignment = Alignment.CenterVertically) {
            Text("People", modifier = Modifier.weight(1f))
            Text("$splitCount", color = MaterialTheme.colorScheme.onSurfaceVariant)
            IconButton(onClick = { onSplitChange(splitCount - 1) }, modifier = Modifier.testTag("tip.people.dec")) {
                Icon(Icons.Filled.Remove, contentDescription = "Fewer people")
            }
            IconButton(onClick = { onSplitChange(splitCount + 1) }, modifier = Modifier.testTag("tip.people.inc")) {
                Icon(Icons.Filled.Add, contentDescription = "More people")
            }
        }
        Row(Modifier.fillMaxWidth().testTag("tip.roundUp"), verticalAlignment = Alignment.CenterVertically) {
            Text("Round up total", modifier = Modifier.weight(1f))
            Switch(checked = roundUp, onCheckedChange = onRoundUpChange)
        }

        Text("Results", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        ResultRow("Tip", currency(tipAmount), tag = "tip.tip")
        ResultRow("Total", currency(total), tag = "tip.total")
        ResultRow("Per person", currency(perPerson), emphasized = true, tag = "tip.perPerson")

        Button(onClick = onCommit, modifier = Modifier.fillMaxWidth().testTag("tip.commit")) {
            Text("Add to history")
        }
    }
}

@Composable
private fun ResultRow(label: String, value: String, emphasized: Boolean = false, tag: String) {
    Row(Modifier.fillMaxWidth().testTag(tag), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontWeight = if (emphasized) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.weight(1f))
        Text(
            value,
            fontWeight = if (emphasized) FontWeight.Bold else FontWeight.Normal,
            color = if (emphasized) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun PresetEditorSheet(
    presets: List<Int>,
    onChange: (Int, Int) -> Unit,
    onDone: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Edit Presets", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        presets.forEachIndexed { index, preset ->
            Row(
                Modifier.fillMaxWidth().testTag("tip.presetEdit.$index"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Preset ${index + 1}", modifier = Modifier.weight(1f))
                Text("$preset%", color = MaterialTheme.colorScheme.onSurfaceVariant)
                IconButton(onClick = { onChange(index, preset - TipSettings.presetStep) }, modifier = Modifier.testTag("tip.presetEdit.$index.dec")) {
                    Icon(Icons.Filled.Remove, contentDescription = "Decrease preset ${index + 1}")
                }
                IconButton(onClick = { onChange(index, preset + TipSettings.presetStep) }, modifier = Modifier.testTag("tip.presetEdit.$index.inc")) {
                    Icon(Icons.Filled.Add, contentDescription = "Increase preset ${index + 1}")
                }
            }
        }
        Button(onClick = onDone, modifier = Modifier.fillMaxWidth().testTag("tip.presetEdit.done")) {
            Text("Done")
        }
    }
}

/** Format an amount in the device's currency, mirroring the iOS `.currency(code:)` style. */
internal fun currency(amount: Double): String {
    val fmt = NumberFormat.getCurrencyInstance(Locale.getDefault())
    runCatching { fmt.currency = Currency.getInstance(Locale.getDefault()) }
    return fmt.format(amount)
}
