package com.snappet.mobile.feature.kilter

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class CreateMode(val label: String) { MANUAL("Manual"), GENERATE("✨ Generate") }
private enum class GenPhase { NEEDS_MODEL, PREPARING, IDLE, GENERATING, READY }

/** Everything needed to persist a climb — built by either tab, replayed on "Save anyway". */
private data class SavePayload(
    val frames: String, val layoutId: Int, val sizeId: Int, val angle: Int,
    val isNoMatch: Boolean, val predictedGrade: Double?, val source: String, val modelId: String?,
)

/**
 * Author a brand-new climb — Manual (tap holes on [KilterEditableBoard]) or ✨ Generate (the on-device
 * transformer). Either way Save validates against the downloaded dataset + prior creations
 * ([KilterDuplicateChecker]) and assigns the deterministic content uuid ([KilterClimbIdentity]) before
 * persisting a [KilterCreatedClimb]. Lights the draft on a connected board, and exports its frames.
 * Mirrors the iOS `CreateClimbView` (PRs 1–3). `onCreated` opens the saved climb.
 */
@Composable
fun CreateClimbScreen(
    catalog: KilterCatalog,
    dao: KilterDao,
    board: KilterBoardController,
    onCreated: (String) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val core = LocalAppContainer.current.core
    val scope = rememberCoroutineScope()

    var mode by remember { mutableStateOf(CreateMode.MANUAL) }
    var name by remember { mutableStateOf("") }

    // Manual state.
    var layoutId by remember { mutableStateOf(KilterSettings.layout(context)) }
    var productSizeId by remember { mutableStateOf(KilterSettings.productSizeId(context)) }
    var angle by remember { mutableStateOf(KilterSettings.angle(context)) }
    var isNoMatch by remember { mutableStateOf(false) }
    var assignments by remember { mutableStateOf<Map<Int, KilterAuthorRole>>(emptyMap()) }
    var placeable by remember { mutableStateOf<List<KilterPlaceableHold>>(emptyList()) }
    var geometry by remember { mutableStateOf(KilterBoardGeometry.EMPTY) }
    var manualHolds by remember { mutableStateOf<List<KilterHold>>(emptyList()) }

    val layouts = remember { catalog.layouts() }
    val sizes = remember(layoutId) { catalog.sizes(layoutId) }
    val angles = remember { catalog.angles() }

    // Generate state.
    val assets = remember { KilterGeneratorAssets(context) }
    var genModel by remember { mutableStateOf<KilterGeneratorModel?>(null) }
    var genRuntime by remember { mutableStateOf<KilterGeneratorRuntime?>(null) }
    var genPhase by remember { mutableStateOf(GenPhase.NEEDS_MODEL) }
    var genError by remember { mutableStateOf<String?>(null) }
    var genSizeId by remember { mutableStateOf(0) }
    var genAngle by remember { mutableStateOf(40) }
    var genGrade by remember { mutableStateOf(17) }
    var genNoMatch by remember { mutableStateOf(false) }
    var genResult by remember { mutableStateOf<KilterGeneratedClimb?>(null) }
    var genHolds by remember { mutableStateOf<List<KilterHold>>(emptyList()) }
    var genGeometry by remember { mutableStateOf(KilterBoardGeometry.EMPTY) }

    // Duplicate handling.
    var duplicate by remember { mutableStateOf<KilterDuplicateChecker.Duplicate?>(null) }
    var pendingSave by remember { mutableStateOf<SavePayload?>(null) }

    val validation = kilterValidate(assignments)

    // Keep the board size valid for the layout; rebuild the editor board + draft holds on changes.
    LaunchedEffect(layoutId, productSizeId) {
        if (sizes.none { it.id == productSizeId }) productSizeId = catalog.defaultSizeId(layoutId)
        val (p, g) = withContext(Dispatchers.IO) {
            catalog.placeableHolds(layoutId, productSizeId) to catalog.boardGeometry(layoutId, productSizeId)
        }
        placeable = p; geometry = g
    }
    // Recompute the draft's lit holds and light a connected board as it changes.
    LaunchedEffect(assignments, layoutId, productSizeId) {
        manualHolds = if (assignments.isEmpty()) emptyList() else withContext(Dispatchers.IO) {
            catalog.holds(KilterClimb("draft", "", "", layoutId, 0, 0, 0, 0, kilterFrames(assignments), "", isNoMatch), productSizeId)
        }
        if (board.isConnected) board.illuminate(manualHolds)
    }

    fun commit(p: SavePayload) {
        scope.launch {
            val canonical = KilterClimbIdentity.canonicalFrames(p.frames)
            val uuid = KilterClimbIdentity.uuid(p.layoutId, canonical)
            val existing = withContext(Dispatchers.IO) { dao.createdByUuid(uuid) }
            if (existing != null) { onCreated(uuid); return@launch }
            val box = catalog.boardBounds(KilterCatalog.parseFrames(canonical).map { it.first })
            val trimmed = name.trim().ifEmpty { if (p.source == "generated") "Generated climb" else "Untitled climb" }
            withContext(Dispatchers.IO) {
                dao.upsertCreated(KilterCreatedClimb(
                    uuid = uuid, name = trimmed, setterUsername = "You",
                    layoutId = p.layoutId, sizeId = p.sizeId, angle = p.angle, frames = canonical,
                    edgeLeft = box?.left ?: 0, edgeRight = box?.right ?: 0,
                    edgeBottom = box?.bottom ?: 0, edgeTop = box?.top ?: 0,
                    isNoMatch = p.isNoMatch, predictedGrade = p.predictedGrade, source = p.source,
                    modelId = p.modelId, createdAt = System.currentTimeMillis(),
                ))
                core.log("kilter", "created",
                    "${if (p.source == "generated") "Generated" else "Created"} $trimmed", p.predictedGrade)
            }
            onCreated(uuid)
        }
    }

    fun attemptSave(p: SavePayload, force: Boolean) {
        scope.launch {
            if (!force) {
                val checker = withContext(Dispatchers.IO) {
                    KilterDuplicateChecker.build(p.layoutId, catalog, dao.allCreated())
                }
                val dup = checker.find(p.layoutId, KilterClimbIdentity.canonicalFrames(p.frames))
                if (dup != null) { duplicate = dup; pendingSave = p; return@launch }
            }
            commit(p)
        }
    }

    fun prepareModel(force: Boolean) {
        scope.launch {
            if (!force && !assets.isInstalled) { genPhase = GenPhase.NEEDS_MODEL; return@launch }
            genPhase = GenPhase.PREPARING; genError = null
            try {
                val model = assets.ensureInstalled()
                genModel = model
                genRuntime = KilterGeneratorRuntime(model, assets.modelFile)
                if (model.meta.sizes.none { it.id == genSizeId }) genSizeId = if (model.meta.sizes.any { it.id == productSizeId }) productSizeId else model.meta.defaultSize
                if (!model.meta.angles.contains(genAngle)) genAngle = if (model.meta.angles.contains(angle)) angle else (model.meta.angles.firstOrNull() ?: 40)
                if (!model.meta.grades.contains(genGrade)) genGrade = model.meta.grades[model.meta.grades.size / 2]
                genPhase = GenPhase.IDLE
            } catch (e: Exception) {
                genError = e.message; genPhase = GenPhase.NEEDS_MODEL
            }
        }
    }

    fun generate() {
        val runtime = genRuntime ?: return
        genPhase = GenPhase.GENERATING
        scope.launch {
            try {
                val result = runtime.generate(KilterGenerateRequest(genSizeId, genAngle, genGrade, genNoMatch, candidates = 3))
                val layout = layoutForSize(catalog, genSizeId, layoutId)
                val holds = withContext(Dispatchers.IO) {
                    catalog.holds(KilterClimb("preview", "", "", layout, 0, 0, 0, 0, result.frames, "", genNoMatch), genSizeId) to
                        catalog.boardGeometry(layout, genSizeId)
                }
                genHolds = holds.first; genGeometry = holds.second; genResult = result
                genPhase = GenPhase.READY
                if (board.isConnected) board.illuminate(genHolds)
            } catch (e: Exception) {
                genError = e.message; genPhase = GenPhase.IDLE
            }
        }
    }

    ModuleScaffold(title = "Create climb", onExit = onExit) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CreateMode.entries.forEach { m ->
                    FilterChip(selected = mode == m, onClick = { mode = m; if (m == CreateMode.GENERATE) prepareModel(false) },
                        label = { Text(m.label) }, modifier = Modifier.testTag("kilter.create.mode.${m.name}"))
                }
            }
            OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") },
                singleLine = true, modifier = Modifier.fillMaxWidth().testTag("kilter.create.name"))

            if (mode == CreateMode.MANUAL) {
                ManualSection(
                    layouts = layouts, sizes = sizes, angles = angles, catalog = catalog,
                    layoutId = layoutId, onLayout = { layoutId = it; assignments = emptyMap() },
                    productSizeId = productSizeId, onSize = { productSizeId = it },
                    angle = angle, onAngle = { angle = it },
                    isNoMatch = isNoMatch, onNoMatch = { isNoMatch = it },
                    geometry = geometry, placeable = placeable, assignments = assignments,
                    onCycle = { pid -> assignments = cycle(assignments, pid) },
                    onClear = { assignments = emptyMap() },
                    validation = validation,
                    board = board, holds = manualHolds,
                    onCopyFrames = { copyFrames(context, kilterFrames(assignments)) },
                    onSave = {
                        if (validation == null) attemptSave(
                            SavePayload(kilterFrames(assignments), layoutId, productSizeId, angle, isNoMatch, null, "manual", null), false)
                    },
                )
            } else {
                GenerateSection(
                    phase = genPhase, error = genError, model = genModel, result = genResult,
                    genSizeId = genSizeId, onGenSize = { genSizeId = it },
                    genAngle = genAngle, onGenAngle = { genAngle = it },
                    genGrade = genGrade, onGenGrade = { genGrade = it },
                    genNoMatch = genNoMatch, onGenNoMatch = { genNoMatch = it },
                    geometry = genGeometry, holds = genHolds, board = board,
                    onDownload = { prepareModel(true) }, onGenerate = { generate() },
                    onCopyFrames = { genResult?.let { copyFrames(context, it.frames) } },
                    onUse = {
                        genResult?.let { r ->
                            attemptSave(SavePayload(r.frames, layoutForSize(catalog, genSizeId, layoutId), genSizeId,
                                genAngle, genNoMatch, r.predictedGrade, "generated", "v1"), false)
                        }
                    },
                )
            }
        }
    }

    duplicate?.let { dup ->
        AlertDialog(
            onDismissRequest = { duplicate = null },
            title = { Text("Climb already exists") },
            text = {
                Text(if (dup.origin == KilterDuplicateChecker.Origin.CATALOG)
                    "These exact holds are already “${dup.name}” by ${dup.setter} in your catalog."
                else "You already created this climb as “${dup.name}”.")
            },
            confirmButton = { TextButton(onClick = { duplicate = null; onCreated(dup.uuid) }) { Text("Open existing") } },
            dismissButton = {
                Row {
                    TextButton(onClick = { val p = pendingSave; duplicate = null; if (p != null) commit(p) }) { Text("Save anyway") }
                    TextButton(onClick = { duplicate = null }) { Text("Keep editing") }
                }
            },
        )
    }
}

/** The layout that owns a `product_size` (the model only knows sizes; a climb needs its layout). */
private fun layoutForSize(catalog: KilterCatalog, sizeId: Int, fallback: Int): Int {
    for (l in catalog.layouts()) if (catalog.sizes(l.id).any { it.id == sizeId }) return l.id
    return fallback
}

/** Cycle a hole's role: unset → start → middle → finish → foot → unset. */
private fun cycle(assignments: Map<Int, KilterAuthorRole>, pid: Int): Map<Int, KilterAuthorRole> {
    val current = assignments[pid]
    val next = current?.next ?: if (current == null) KilterAuthorRole.START else null
    return assignments.toMutableMap().apply { if (next != null) put(pid, next) else remove(pid) }
}

private fun copyFrames(context: Context, frames: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("frames", KilterClimbIdentity.canonicalFrames(frames)))
}

internal fun shareFrames(context: Context, frames: String) {
    val send = Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, frames) }
    context.startActivity(Intent.createChooser(send, "Share frames"))
}

// ---- Sub-sections ----

@Composable
private fun ManualSection(
    layouts: List<KilterLayout>, sizes: List<KilterBoardSize>, angles: List<Int>, catalog: KilterCatalog,
    layoutId: Int, onLayout: (Int) -> Unit, productSizeId: Int, onSize: (Int) -> Unit,
    angle: Int, onAngle: (Int) -> Unit, isNoMatch: Boolean, onNoMatch: (Boolean) -> Unit,
    geometry: KilterBoardGeometry, placeable: List<KilterPlaceableHold>, assignments: Map<Int, KilterAuthorRole>,
    onCycle: (Int) -> Unit, onClear: () -> Unit, validation: KilterClimbValidationError?,
    board: KilterBoardController, holds: List<KilterHold>,
    onCopyFrames: () -> Unit, onSave: () -> Unit,
) {
    PickerRow("Layout", layouts.firstOrNull { it.id == layoutId }?.name ?: "—", layouts.map { it.id to it.name }, onLayout)
    if (sizes.size > 1) PickerRow("Board size", sizes.firstOrNull { it.id == productSizeId }?.name ?: "—", sizes.map { it.id to it.label }, onSize)
    PickerRow("Angle", "$angle°", angles.map { it to "$it°" }, onAngle)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("No matching", Modifier.weight(1f))
        Switch(checked = isNoMatch, onCheckedChange = onNoMatch, modifier = Modifier.testTag("kilter.create.noMatch"))
    }
    KilterEditableBoard(geometry, placeable, assignments, onCycle, Modifier.fillMaxWidth())
    RoleCounts(assignments.values.toList())
    if (validation != null) {
        Text(validation.message, color = Color(0xFFD97706), style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.testTag("kilter.create.invalid"))
    } else {
        Text("Ready to save · ${assignments.size} holds", color = Color(0xFF30A46C),
            style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("kilter.create.valid"))
    }
    if (board.isConnected && holds.isNotEmpty()) {
        OutlinedButton(onClick = { board.illuminate(holds) }, modifier = Modifier.fillMaxWidth()) {
            Text("Light ${holds.size} holds on board")
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (assignments.isNotEmpty()) {
            OutlinedButton(onClick = onCopyFrames) { Text("Copy frames") }
            OutlinedButton(onClick = onClear, modifier = Modifier.testTag("kilter.create.clear")) { Text("Clear") }
        }
        Button(onClick = onSave, enabled = validation == null,
            modifier = Modifier.weight(1f).testTag("kilter.create.save")) { Text("Save climb") }
    }
}

@Composable
private fun GenerateSection(
    phase: GenPhase, error: String?, model: KilterGeneratorModel?, result: KilterGeneratedClimb?,
    genSizeId: Int, onGenSize: (Int) -> Unit, genAngle: Int, onGenAngle: (Int) -> Unit,
    genGrade: Int, onGenGrade: (Int) -> Unit, genNoMatch: Boolean, onGenNoMatch: (Boolean) -> Unit,
    geometry: KilterBoardGeometry, holds: List<KilterHold>, board: KilterBoardController,
    onDownload: () -> Unit, onGenerate: () -> Unit, onCopyFrames: () -> Unit, onUse: () -> Unit,
) {
    when (phase) {
        GenPhase.NEEDS_MODEL -> {
            error?.let { Text(it, color = Color(0xFFD97706), style = MaterialTheme.typography.bodySmall) }
            Button(onClick = onDownload, modifier = Modifier.fillMaxWidth().testTag("kilter.generate.download")) {
                Text("Download generator model (~9 MB)")
            }
            Text("A small transformer runs entirely on your device. Downloaded once.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        GenPhase.PREPARING -> BusyRow("Loading the generator model…")
        else -> {
            if (model != null) {
                PickerRow("Board size", model.meta.sizes.firstOrNull { it.id == genSizeId }?.name ?: "—",
                    model.meta.sizes.map { it.id to it.name }, onGenSize)
                PickerRow("Angle", "$genAngle°", model.meta.angles.map { it to "$it°" }, onGenAngle)
                PickerRow("Target grade", model.gradeLabel(genGrade), model.meta.grades.map { it to model.gradeLabel(it) }, onGenGrade)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("No matching", Modifier.weight(1f)); Switch(checked = genNoMatch, onCheckedChange = onGenNoMatch)
                }
                Button(onClick = onGenerate, enabled = phase != GenPhase.GENERATING,
                    modifier = Modifier.fillMaxWidth().testTag("kilter.generate.run")) {
                    Text(if (result == null) "Generate climb" else "Generate another")
                }
            }
            if (phase == GenPhase.GENERATING) BusyRow("Generating…")
            if (phase == GenPhase.READY && result != null) {
                HorizontalDivider()
                KilterBoard(geometry, holds, Modifier.fillMaxWidth())
                Text("Predicted ${model?.gradeLabel(result.predictedGrade.toInt()) ?: "—"} · target ${model?.gradeLabel(genGrade) ?: genGrade}",
                    style = MaterialTheme.typography.bodyMedium)
                RoleCounts(holds.mapNotNull { KilterAuthorRole.fromRoleId(roleIdForName(it.role)) })
                if (board.isConnected && holds.isNotEmpty()) {
                    OutlinedButton(onClick = { board.illuminate(holds) }, modifier = Modifier.fillMaxWidth()) {
                        Text("Light on board")
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onCopyFrames) { Text("Copy frames") }
                    Button(onClick = onUse, modifier = Modifier.weight(1f).testTag("kilter.generate.use")) { Text("Use this climb") }
                }
                Text("Generated on-device — the grade is a model estimate. Valid by construction.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun RoleCounts(roles: List<KilterAuthorRole>) {
    val counts = roles.groupingBy { it }.eachCount()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
        Tally("Start", counts[KilterAuthorRole.START] ?: 0, "00DD00")
        Tally("Hand", counts[KilterAuthorRole.MIDDLE] ?: 0, "00FFFF")
        Tally("Finish", counts[KilterAuthorRole.FINISH] ?: 0, "FF00FF")
        Tally("Foot", counts[KilterAuthorRole.FOOT] ?: 0, "FFA500")
    }
}

@Composable
private fun Tally(label: String, n: Int, hex: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("$n", color = hexColor(hex), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun BusyRow(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.padding(4.dp)); Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun roleIdForName(role: String): Int = when (role) {
    "start" -> 12; "finish" -> 14; "foot" -> 15; else -> 13
}

@Composable
private fun PickerRow(label: String, value: String, options: List<Pair<Int, String>>, onSelect: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Box {
            OutlinedButton(onClick = { expanded = true }) { Text(value) }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { (id, name) ->
                    DropdownMenuItem(text = { Text(name) }, onClick = { onSelect(id); expanded = false })
                }
            }
        }
    }
}
