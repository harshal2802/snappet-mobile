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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One physical Kilter board size: its `product_size_id`, a label, and its fit box. Mirrors iOS. */
data class KilterKnownSize(val id: Int, val name: String, val box: KilterSizeBox)

/** A Kilter board the user can own — a layout + its sizes. Drives the download sheet's board picker. */
data class KilterKnownBoard(
    val layoutId: Int, val name: String, val defaultSizeId: Int, val sizes: List<KilterKnownSize>)

/**
 * Static Kilter option lists for the download sheet (the dataset isn't loaded until after download).
 * Only Kilter Original (1) + Homewall (8) are supported today. Grades/angles are the standard Kilter
 * scale. Mirrors iOS `KilterCatalogOptions`.
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
    val caps = listOf(1000, 2000, 5000, 10000, 0)   // 0 = everything that fits

    /** The two supported Kilter boards + their listed sizes, each with its fit box (hole units, from the
     *  real Aurora product_sizes.edge_*). Embedded because the dataset isn't installed on a first
     *  download — board dimensions are structural reference (like layout ids), not climb data (#42).
     *  Homewall ships each size under several LED-kit ids; we keep one per physical size. */
    val boards = listOf(
        KilterKnownBoard(1, "Kilter Original", defaultSizeId = 10, sizes = listOf(
            KilterKnownSize(14, "7 × 10", KilterSizeBox(28, 116, 36, 156)),
            KilterKnownSize(8, "8 × 12", KilterSizeBox(24, 120, 0, 156)),
            KilterKnownSize(10, "12 × 12 (with kickboard)", KilterSizeBox(0, 144, 0, 156)),
            KilterKnownSize(27, "12 × 12 (no kickboard)", KilterSizeBox(0, 144, 12, 156)),
            KilterKnownSize(7, "12 × 14", KilterSizeBox(0, 144, 0, 180)),
            KilterKnownSize(28, "16 × 12", KilterSizeBox(-24, 168, 0, 156)))),
        KilterKnownBoard(8, "Kilter Homewall", defaultSizeId = 25, sizes = listOf(
            KilterKnownSize(17, "7 × 10", KilterSizeBox(-44, 44, 24, 144)),
            KilterKnownSize(23, "8 × 12", KilterSizeBox(-44, 44, -12, 144)),
            KilterKnownSize(21, "10 × 10", KilterSizeBox(-56, 56, 24, 144)),
            KilterKnownSize(25, "10 × 12", KilterSizeBox(-56, 56, -12, 144)))))

    fun gradeLabel(d: Int): String = grades.firstOrNull { it.first == d }?.second ?: "—"
    fun board(layoutId: Int): KilterKnownBoard = boards.firstOrNull { it.layoutId == layoutId } ?: boards[0]
    fun sizeName(layoutId: Int, sizeId: Int): String? = board(layoutId).sizes.firstOrNull { it.id == sizeId }?.name

    /** A short library name, e.g. "Kilter · Original · 12 × 14 · top 2000" (shown in the catalog list). */
    fun name(f: CatalogFilter): String {
        val parts = ArrayList<String>().apply { add("Kilter") }
        f.layoutIds.firstOrNull()?.let { layout ->
            parts.add(board(layout).name.removePrefix("Kilter "))
            f.sizeId?.let { sid -> sizeName(layout, sid)?.let { parts.add(it) } }
        }
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

    // The user's board — layout + size — is the ONLY download filter; the rest are browse-time. Picks are
    // persisted (KilterSettings) so re-opening restores the user's board, matching iOS @AppStorage.
    var layoutId by remember { mutableStateOf(KilterSettings.dlLayout(context)) }
    var sizeId by remember { mutableStateOf(KilterSettings.dlSizeId(context)) }
    var maxClimbs by remember { mutableStateOf(KilterSettings.dlMaxClimbs(context)) }
    var host by remember { mutableStateOf(KILTER_DEFAULT_CATALOG_HOST) }
    var showAdvanced by remember { mutableStateOf(false) }
    // Keep a persisted size valid for the persisted board (e.g. if the board table ever changes).
    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (KilterCatalogOptions.board(layoutId).sizes.none { it.id == sizeId }) {
            sizeId = KilterCatalogOptions.board(layoutId).defaultSizeId
            KilterSettings.setDlSizeId(context, sizeId)
        }
    }

    var boards by remember { mutableStateOf<List<CatalogBoardEntry>>(emptyList()) }
    var working by remember { mutableStateOf(false) }
    var progress by remember { mutableFloatStateOf(0f) }
    var error by remember { mutableStateOf<String?>(null) }

    androidx.compose.runtime.LaunchedEffect(host) {
        boards = HostedCatalogClient(host).importableBoards()
    }

    val currentBoard = KilterCatalogOptions.board(layoutId)
    val selectedSize = currentBoard.sizes.firstOrNull { it.id == sizeId }

    fun buildFilter(): CatalogFilter = CatalogFilter(
        layoutIds = listOf(layoutId),
        sizeId = selectedSize?.id, sizeBox = selectedSize?.box,
        maxClimbs = maxClimbs)

    ModalBottomSheet(onDismissRequest = { if (!working) onDismiss() }) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Get climbs", style = MaterialTheme.typography.titleLarge)

            // Your board: layout + size — the only two download filters.
            Text("Your board", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Dropdown("Board", currentBoard.name) { dismiss ->
                KilterCatalogOptions.boards.forEach { b ->
                    DropdownMenuItem(text = { Text(b.name) }, onClick = {
                        layoutId = b.layoutId; sizeId = b.defaultSizeId
                        KilterSettings.setDlLayout(context, b.layoutId); KilterSettings.setDlSizeId(context, b.defaultSizeId)
                        dismiss()
                    })
                }
            }
            Dropdown("Size", selectedSize?.name ?: "—") { dismiss ->
                currentBoard.sizes.forEach { s ->
                    DropdownMenuItem(text = { Text(s.name) }, onClick = {
                        sizeId = s.id; KilterSettings.setDlSizeId(context, s.id); dismiss()
                    })
                }
            }
            Text("Pick the Kilter board you climb on — we'll get the climbs that fit it. The size is " +
                "printed on the board (and shown in the official Kilter app).",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            // How many climbs.
            Text("How many climbs", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Dropdown("Climbs to keep", if (maxClimbs == 0) "Everything that fits" else "Most popular $maxClimbs") { dismiss ->
                KilterCatalogOptions.caps.forEach { n ->
                    DropdownMenuItem(text = { Text(if (n == 0) "Everything that fits" else "Most popular $n") },
                        onClick = { maxClimbs = n; KilterSettings.setDlMaxClimbs(context, n); dismiss() })
                }
            }
            Text("More climbs = a bigger download. Once installed, filter by grade, angle, quality and " +
                "more right in the list.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            if (working) {
                LinearProgressIndicator(progress = { (progress / 0.75f).coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth())
                Text(if (progress < 0.75f) "Downloading…" else if (progress < 1f) "Trimming to your board…" else "Installing…",
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
                enabled = !working && selectedSize != null,
                modifier = Modifier.fillMaxWidth().testTag("kilter.dl.download"),
            ) { Text("Download") }

            // Advanced (collapsed): host URL — most users never touch it.
            TextButton(onClick = { showAdvanced = !showAdvanced }) {
                Text(if (showAdvanced) "Hide advanced" else "Advanced")
            }
            if (showAdvanced) {
                OutlinedTextField(host, { host = it }, label = { Text("Host URL") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("kilter.dl.host"))
                Text("Snappet downloads from a static file you host — no Kilter account, nothing uploaded.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
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
