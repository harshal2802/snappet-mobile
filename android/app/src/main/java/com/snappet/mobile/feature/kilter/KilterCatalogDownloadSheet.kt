package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Static Kilter option lists for the download sheet (the dataset isn't loaded until after download).
 * Only Kilter Original (1) + Homewall (8) are supported today; the rest are shown struck-through as
 * future work. Grades/angles are the standard Kilter scale. Mirrors iOS `KilterCatalogOptions`.
 */
object KilterCatalogOptions {
    /** (id, name, supported). */
    val layouts = listOf(
        Triple(1, "Original", true), Triple(8, "Homewall", true),
        Triple(2, "JUUL", false), Triple(3, "Standard Medium", false), Triple(4, "BKB Level 1", false),
        Triple(5, "Spire", false), Triple(6, "Tycho Complete", false), Triple(7, "Tycho 2020", false))
    val angles = listOf(0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70)
    /** `difficulty_grades.difficulty` int → label (listed Kilter grades). */
    val grades = listOf(
        10 to "4a / V0", 11 to "4b / V0", 12 to "4c / V0", 13 to "5a / V1", 14 to "5b / V1",
        15 to "5c / V2", 16 to "6a / V3", 17 to "6a+ / V3", 18 to "6b / V4", 19 to "6b+ / V4",
        20 to "6c / V5", 21 to "6c+ / V5", 22 to "7a / V6", 23 to "7a+ / V7", 24 to "7b / V8",
        25 to "7b+ / V8", 26 to "7c / V9", 27 to "7c+ / V10", 28 to "8a / V11", 29 to "8a+ / V12",
        30 to "8b / V13", 31 to "8b+ / V14", 32 to "8c / V15", 33 to "8c+ / V16")
    val ascentChoices = listOf(0, 10, 50, 100, 500, 1000)
    val caps = listOf(1000, 2000, 5000, 10000, 0)   // 0 = all matching

    fun gradeLabel(d: Int): String = grades.firstOrNull { it.first == d }?.second ?: "—"

    /** A short library name from the active filters (shown in the Settings catalog list). */
    fun name(f: CatalogFilter): String {
        val parts = ArrayList<String>().apply { add("Kilter") }
        val layoutNames = listOfNotNull(
            if (f.layoutIds.contains(1)) "Original" else null,
            if (f.layoutIds.contains(8)) "Homewall" else null)
        if (layoutNames.isNotEmpty()) parts.add(layoutNames.joinToString("+"))
        f.angle?.let { parts.add("${it}°") }
        if (f.gradeMin != null || f.gradeMax != null) {
            val lo = f.gradeMin?.let { gradeLabel(it) } ?: "any"
            val hi = f.gradeMax?.let { gradeLabel(it) } ?: "any"
            parts.add("$lo–$hi")
        }
        if (f.benchmarkOnly) parts.add("classics")
        parts.add(if (f.maxClimbs == 0) "all" else "top ${f.maxClimbs}")
        return parts.joinToString(" · ")
    }
}

/**
 * Bottom-sheet for the in-app catalog download: pick the full Board-Explorer filter set, fetch the
 * gzipped dataset from the host, and trim it on-device to an importable catalog. No accounts. Only
 * Kilter Original + Homewall are buildable today; other boards/layouts show struck-through. Mirrors the
 * iOS `KilterCatalogDownloadSheet`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KilterCatalogDownloadSheet(onInstalled: () -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var host by remember { mutableStateOf(KILTER_DEFAULT_CATALOG_HOST) }
    var includeOriginal by remember { mutableStateOf(true) }
    var includeHomewall by remember { mutableStateOf(true) }
    var angle by remember { mutableStateOf<Int?>(null) }
    var gradeMin by remember { mutableStateOf<Int?>(null) }
    var gradeMax by remember { mutableStateOf<Int?>(null) }
    var minAscents by remember { mutableStateOf(0) }
    var minQuality by remember { mutableStateOf(0.0) }
    var setter by remember { mutableStateOf("") }
    var nameContains by remember { mutableStateOf("") }
    var benchmarkOnly by remember { mutableStateOf(false) }
    var listedOnly by remember { mutableStateOf(true) }
    var singleFrameOnly by remember { mutableStateOf(true) }
    var maxClimbs by remember { mutableStateOf(2000) }

    var boards by remember { mutableStateOf<List<CatalogBoardEntry>>(emptyList()) }
    var working by remember { mutableStateOf(false) }
    var progress by remember { mutableFloatStateOf(0f) }
    var error by remember { mutableStateOf<String?>(null) }

    androidx.compose.runtime.LaunchedEffect(host) {
        boards = HostedCatalogClient(host).importableBoards()
    }

    val hasLayout = includeOriginal || includeHomewall

    fun buildFilter() = CatalogFilter(
        layoutIds = listOfNotNull(if (includeOriginal) 1 else null, if (includeHomewall) 8 else null),
        angle = angle, gradeMin = gradeMin, gradeMax = gradeMax,
        minAscents = minAscents.takeIf { it > 0 }, minQuality = minQuality.takeIf { it > 0 },
        setter = setter, name = nameContains, benchmarkOnly = benchmarkOnly,
        listedOnly = listedOnly, singleFrameOnly = singleFrameOnly, maxClimbs = maxClimbs)

    ModalBottomSheet(onDismissRequest = { if (!working) onDismiss() }) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Download catalog", style = MaterialTheme.typography.titleLarge)

            Text("Board", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Text("Kilter Board ✓")
            boards.filter { it.board != "kilter" }.forEach { b ->
                Text(b.label, textDecoration = TextDecoration.LineThrough,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            Text("Layouts", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            SwitchRow("Original", includeOriginal) { includeOriginal = it }
            SwitchRow("Homewall", includeHomewall) { includeHomewall = it }
            KilterCatalogOptions.layouts.filter { !it.third }.forEach {
                Text(it.second, textDecoration = TextDecoration.LineThrough,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            Text("Filters", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Dropdown("Angle", (angle?.let { "${it}°" } ?: "Any")) { dismiss ->
                DropdownMenuItem(text = { Text("Any") }, onClick = { angle = null; dismiss() })
                KilterCatalogOptions.angles.forEach { a ->
                    DropdownMenuItem(text = { Text("${a}°") }, onClick = { angle = a; dismiss() })
                }
            }
            Dropdown("Min grade", gradeMin?.let { KilterCatalogOptions.gradeLabel(it) } ?: "Any") { dismiss ->
                DropdownMenuItem(text = { Text("Any") }, onClick = { gradeMin = null; dismiss() })
                KilterCatalogOptions.grades.forEach { (d, label) ->
                    DropdownMenuItem(text = { Text(label) }, onClick = {
                        gradeMin = d; if (gradeMax != null && d > gradeMax!!) gradeMax = d; dismiss()
                    })
                }
            }
            Dropdown("Max grade", gradeMax?.let { KilterCatalogOptions.gradeLabel(it) } ?: "Any") { dismiss ->
                DropdownMenuItem(text = { Text("Any") }, onClick = { gradeMax = null; dismiss() })
                KilterCatalogOptions.grades.forEach { (d, label) ->
                    DropdownMenuItem(text = { Text(label) }, onClick = {
                        gradeMax = d; if (gradeMin != null && d < gradeMin!!) gradeMin = d; dismiss()
                    })
                }
            }
            Dropdown("Min ascents", if (minAscents == 0) "Any" else "${minAscents}+") { dismiss ->
                KilterCatalogOptions.ascentChoices.forEach { n ->
                    DropdownMenuItem(text = { Text(if (n == 0) "Any" else "${n}+") }, onClick = { minAscents = n; dismiss() })
                }
            }
            Dropdown("Min quality", when (minQuality) { 0.0 -> "Any"; 3.0 -> "★ 3"; else -> "★ ${minQuality.toInt()}+" }) { dismiss ->
                listOf(0.0 to "Any", 1.0 to "★ 1+", 2.0 to "★ 2+", 3.0 to "★ 3").forEach { (q, label) ->
                    DropdownMenuItem(text = { Text(label) }, onClick = { minQuality = q; dismiss() })
                }
            }
            OutlinedTextField(setter, { setter = it }, label = { Text("Setter contains") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(nameContains, { nameContains = it }, label = { Text("Name contains") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            SwitchRow("Benchmarks (classics) only", benchmarkOnly) { benchmarkOnly = it }
            SwitchRow("Listed only", listedOnly) { listedOnly = it }
            SwitchRow("Single-frame only", singleFrameOnly) { singleFrameOnly = it }

            Text("Catalog size", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Dropdown("Keep most-climbed", if (maxClimbs == 0) "All matching" else "Top $maxClimbs") { dismiss ->
                KilterCatalogOptions.caps.forEach { n ->
                    DropdownMenuItem(text = { Text(if (n == 0) "All matching" else "Top $n") }, onClick = { maxClimbs = n; dismiss() })
                }
            }
            Text("The full dataset is ~80 MB to download; it's trimmed on-device to your filters.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            if (working) {
                LinearProgressIndicator(progress = { (progress / 0.75f).coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth())
                Text(if (progress < 0.75f) "Downloading…" else if (progress < 1f) "Trimming…" else "Installing…",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("kilter.dl.error"))
            }

            Button(
                onClick = {
                    error = null; working = true; progress = 0f
                    val filter = buildFilter()
                    val board = boards.firstOrNull { it.board == "kilter" }
                        ?: CatalogBoardEntry("kilter", "Kilter Board", "kilter.sqlite.gz", null, 0, true)
                    scope.launch {
                        try {
                            installKilterCatalog(
                                context,
                                HostedCatalogProvider(context, board, filter, host, KilterCatalogOptions.name(filter)),
                                onProgress = { p -> scope.launch(Dispatchers.Main) { progress = p } })
                            withContext(Dispatchers.Main) { onInstalled(); onDismiss() }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { working = false; error = e.message ?: "Download failed" }
                        }
                    }
                },
                enabled = !working && hasLayout,
                modifier = Modifier.fillMaxWidth().testTag("kilter.dl.download"),
            ) { Text("Download catalog") }

            Text("Source", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            OutlinedTextField(host, { host = it }, label = { Text("Host URL") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("kilter.dl.host"))
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun Dropdown(label: String, value: String, items: @Composable (dismiss: () -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label)
        Box {
            OutlinedButton(onClick = { open = true }) { Text(value) }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) { items { open = false } }
        }
    }
}
