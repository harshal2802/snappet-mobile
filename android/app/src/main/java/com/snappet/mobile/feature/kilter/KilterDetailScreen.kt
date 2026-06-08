package com.snappet.mobile.feature.kilter

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DoNotTouch
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/**
 * A single climb: holds rendered on the board, an angle selector (difficulty is per-angle),
 * grade/quality/ascents for that angle, logging (Flash/Sent/Project/Attempt), a Saved toggle, a
 * beta-video link, and — when a board is connected over BLE — illumination (Phase 2). Mirrors the
 * iOS `KilterClimbDetailView`. `onExit` returns to the catalog.
 */
@Composable
fun KilterDetailScreen(
    uuid: String,
    catalog: KilterCatalog,
    board: KilterBoardController,
    sessions: KilterSessionManager,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val dao = container.database.kilterDao()
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current

    val favorites by dao.favoritesFlow().collectAsState(initial = emptyList())
    val isFavorite = remember(favorites, uuid) { favorites.any { it.climbUuid == uuid } }

    var climb by remember { mutableStateOf<KilterClimb?>(null) }
    var stats by remember { mutableStateOf<List<KilterClimbStat>>(emptyList()) }
    var holds by remember { mutableStateOf<List<KilterHold>>(emptyList()) }
    var geometry by remember { mutableStateOf(KilterBoardGeometry.EMPTY) }
    var betaLinks by remember { mutableStateOf<List<String>>(emptyList()) }
    var selectedAngle by remember { mutableStateOf(KilterSettings.angle(context)) }
    var logConfirmation by remember { mutableStateOf<String?>(null) }
    var angleMenu by remember { mutableStateOf(false) }
    val gradeFormat = remember { KilterSettings.gradeFormat(context) }
    // Board payload dialect + the "wrong holds?" escape hatch (hidden until tapped).
    var apiLevel by remember { mutableStateOf(KilterSettings.apiLevel(context)) }
    // The user's physical board size (product_size_id) — wrong size lights shifted/incorrect holds.
    var productSizeId by remember { mutableStateOf(KilterSettings.productSizeId(context)) }
    var sizeMenu by remember { mutableStateOf(false) }
    var showProtocolFix by remember { mutableStateOf(false) }

    // Push the persisted/selected dialect to the controller (initial sync + on every switch); a switch
    // re-lights the current climb instantly inside the controller.
    androidx.compose.runtime.LaunchedEffect(apiLevel) { board.setApiLevel(apiLevel) }

    androidx.compose.runtime.LaunchedEffect(uuid) {
        val loaded = withContext(Dispatchers.IO) {
            val c = catalog.climb(uuid) ?: return@withContext null
            // Seed the board size to this layout's default if unset/invalid, then map LEDs for it.
            val eff = if (catalog.sizes(c.layoutId).any { it.id == productSizeId }) productSizeId
            else catalog.defaultSizeId(c.layoutId)
            Loaded(c, catalog.stats(uuid), catalog.holds(c, eff), catalog.boardGeometry(c.layoutId, eff),
                catalog.betaLinks(uuid), eff)
        } ?: return@LaunchedEffect
        climb = loaded.climb; stats = loaded.stats; holds = loaded.holds
        geometry = loaded.geometry; betaLinks = loaded.beta
        if (productSizeId != loaded.effectiveSize) {
            productSizeId = loaded.effectiveSize; KilterSettings.setProductSizeId(context, loaded.effectiveSize)
        }
        selectedAngle = if (stats.any { it.angle == selectedAngle }) selectedAngle
        else stats.maxByOrNull { it.ascents }?.angle ?: selectedAngle
    }

    // Open / close a session as the board connects / disconnects (Phase 2).
    androidx.compose.runtime.LaunchedEffect(board) {
        board.onConnectionChange = { connected ->
            scope.launch { if (connected) sessions.start(selectedAngle, "ble") else sessions.end() }
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted -> if (granted.values.all { it }) board.connect() }

    fun requestConnect() {
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        permissionLauncher.launch(perms)
    }

    fun log(status: KilterAscentStatus) {
        val c = climb ?: return
        val stat = stats.firstOrNull { it.angle == selectedAngle } ?: return
        val grade = catalog.gradeLabel(stat.difficulty)
        scope.launch {
            dao.insertLog(
                KilterLogEntry(
                    climbUuid = c.uuid, climbName = c.name, angle = selectedAngle,
                    difficulty = stat.difficulty, gradeLabel = grade, status = status.name,
                    createdAt = System.currentTimeMillis(), sessionId = sessions.currentSessionId,
                )
            )
            container.core.log("kilter", "log-${status.name.lowercase()}",
                "${status.label} ${c.name} ($grade @${selectedAngle}°)", stat.difficulty)
        }
        logConfirmation = "Logged ${status.label.lowercase()} · $grade"
    }

    fun toggleFavorite() {
        scope.launch {
            val existing = favorites.firstOrNull { it.climbUuid == uuid }
            if (existing != null) dao.removeFavorite(existing)
            else dao.addFavorite(KilterFavorite(uuid, System.currentTimeMillis()))
        }
    }

    ModuleScaffold(
        title = climb?.name ?: "Climb",
        onExit = onExit,
        actions = {
            IconButton(onClick = { toggleFavorite() }, modifier = Modifier.testTag("kilter.favorite")) {
                Icon(if (isFavorite) Icons.Filled.Star else Icons.Outlined.StarBorder,
                    contentDescription = if (isFavorite) "Remove from saved" else "Save climb")
            }
        },
    ) { padding ->
        val currentStat = stats.firstOrNull { it.angle == selectedAngle }
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            KilterBoard(geometry, holds, Modifier.fillMaxWidth())

            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                LegendDot("00DD00", "start", "Start"); LegendDot("00FFFF", "middle", "Middle")
                LegendDot("FF00FF", "finish", "Finish"); LegendDot("FFA500", "foot", "Foot")
            }

            // Angle selector
            Box {
                OutlinedButton(onClick = { angleMenu = true }, modifier = Modifier.testTag("kilter.angle")) {
                    Text("${selectedAngle}°")
                }
                DropdownMenu(expanded = angleMenu, onDismissRequest = { angleMenu = false }) {
                    stats.forEach { s ->
                        DropdownMenuItem(
                            text = { Text("${s.angle}°  ·  ${catalog.gradeLabel(s.difficulty)}") },
                            onClick = { selectedAngle = s.angle; KilterSettings.setAngle(context, s.angle); angleMenu = false },
                        )
                    }
                }
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                Stat("Grade", currentStat?.let { kilterDisplayGrade(catalog.gradeLabel(it.difficulty), gradeFormat) } ?: "—", "kilter.grade")
                Stat("Quality", "★".repeat((currentStat?.quality ?: 0.0).roundToInt().coerceIn(0, 3)), null)
                Stat("Ascents", "${currentStat?.ascents ?: 0}", null)
            }

            // Matching rule (always shown) + benchmark ("Classic") badge + first-ascensionist.
            val isClassic = currentStat?.benchmarkDifficulty != null
            val fa = currentStat?.faUsername ?: ""
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically) {
                // The Kilter "No matching" rule: amber chip when the setter forbids matching hands on a
                // hold, else a quiet "Matching" chip (the default). Mirrors iOS.
                val noMatch = climb?.isNoMatch == true
                val matchColor = if (noMatch) Color(0xFFF76808) else MaterialTheme.colorScheme.onSurfaceVariant
                Row(Modifier.background(matchColor.copy(alpha = if (noMatch) 0.18f else 0.14f), CircleShape)
                    .padding(horizontal = 10.dp, vertical = 4.dp).testTag("kilter.matchTag"),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(if (noMatch) Icons.Filled.DoNotTouch else Icons.Filled.PanTool,
                        contentDescription = if (noMatch) "No matching allowed" else "Matching allowed",
                        tint = matchColor, modifier = Modifier.size(14.dp))
                    Text(if (noMatch) "No matching" else "Matching",
                        style = MaterialTheme.typography.labelMedium, color = matchColor,
                        fontWeight = FontWeight.SemiBold)
                }
                if (isClassic) {
                    Box(Modifier.background(Color(0xFFD97706).copy(alpha = 0.18f), CircleShape)
                        .padding(horizontal = 10.dp, vertical = 4.dp)) {
                        Text("★ Classic", style = MaterialTheme.typography.labelMedium,
                            color = Color(0xFFD97706), fontWeight = FontWeight.SemiBold)
                    }
                }
                if (fa.isNotEmpty()) {
                    Text("FA $fa", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LogButton("Flash", Icons.Filled.Bolt, true, Modifier.weight(1f), "kilter.log.flash") { log(KilterAscentStatus.FLASH) }
                LogButton("Sent", Icons.Filled.Check, true, Modifier.weight(1f), "kilter.log.sent") { log(KilterAscentStatus.SENT) }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LogButton("Project", Icons.Filled.Star, false, Modifier.weight(1f), "kilter.log.project") { log(KilterAscentStatus.PROJECT) }
                LogButton("Attempt", Icons.Filled.Bolt, false, Modifier.weight(1f), "kilter.log.attempt") { log(KilterAscentStatus.ATTEMPT) }
            }
            androidx.compose.animation.AnimatedVisibility(visible = logConfirmation != null) {
                Box(Modifier.background(Color(0xFF30A46C).copy(alpha = 0.16f), CircleShape)
                    .padding(horizontal = 12.dp, vertical = 6.dp)) {
                    Text("✓ ${logConfirmation ?: ""}", style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF1E7E48), fontWeight = FontWeight.Medium,
                        modifier = Modifier.testTag("kilter.logConfirmation"))
                }
            }

            if (stats.size > 1) GradeChart(stats, selectedAngle, catalog)

            // Illuminate (Phase 2). Simulators / devices with no BLE radio never show the section.
            if (board.state != KilterBoardController.State.UNSUPPORTED) {
                when (board.state) {
                    KilterBoardController.State.CONNECTED -> {
                        OutlinedButton(
                            onClick = { board.illuminate(holds) },
                            modifier = Modifier.fillMaxWidth().testTag("kilter.illuminate"),
                        ) {
                            Icon(Icons.Filled.Lightbulb, contentDescription = null)
                            Text("  Light up this climb")
                        }
                        // Escape hatch when the board lights the wrong holds — reveals the two fixes in
                        // likelihood order: (1) board size (the usual cause of shifted/incorrect holds —
                        // each size addresses its LEDs differently), then (2) the Standard/Legacy payload
                        // dialect for older controllers. Both re-light the current climb at once.
                        if (showProtocolFix) {
                            val sizes = climb?.let { catalog.sizes(it.layoutId) } ?: emptyList()
                            if (sizes.size > 1) {
                                Box {
                                    OutlinedButton(
                                        onClick = { sizeMenu = true },
                                        modifier = Modifier.testTag("kilter.board.size"),
                                    ) { Text("Board size: ${sizes.firstOrNull { it.id == productSizeId }?.label ?: "—"}") }
                                    DropdownMenu(expanded = sizeMenu, onDismissRequest = { sizeMenu = false }) {
                                        sizes.forEach { s ->
                                            DropdownMenuItem(text = { Text(s.label) }, onClick = {
                                                productSizeId = s.id
                                                KilterSettings.setProductSizeId(context, s.id)
                                                sizeMenu = false
                                                climb?.let { c ->
                                                    // Size remaps LEDs AND reshapes the board — rebuild both.
                                                    holds = catalog.holds(c, s.id)
                                                    geometry = catalog.boardGeometry(c.layoutId, s.id)
                                                    if (board.isConnected) board.illuminate(holds)
                                                }
                                            })
                                        }
                                    }
                                }
                                Text("Pick your board's size — the wrong size lights shifted/incorrect holds.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                KilterProtocol.ApiLevel.entries.forEach { level ->
                                    FilterChip(
                                        selected = apiLevel == level,
                                        onClick = { apiLevel = level; KilterSettings.setApiLevel(context, level) },
                                        label = { Text(level.label) },
                                        modifier = Modifier.testTag("kilter.board.protocol.${level.name}"),
                                    )
                                }
                            }
                            Text("Still off? Older controllers use Legacy. Each change re-lights instantly.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        } else {
                            TextButton(
                                onClick = { showProtocolFix = true },
                                modifier = Modifier.testTag("kilter.board.wrongHolds"),
                            ) { Text("Wrong holds lighting up?") }
                        }
                        TextButton(onClick = { board.disconnect() }) { Text("Disconnect board") }
                    }

                    KilterBoardController.State.SCANNING, KilterBoardController.State.CONNECTING -> {
                        Row(
                            Modifier.fillMaxWidth().testTag("kilter.board.connecting"),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Text(
                                if (board.state == KilterBoardController.State.SCANNING) "  Searching for your board…"
                                else "  Connecting…",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        TextButton(
                            onClick = { board.cancel() },
                            modifier = Modifier.testTag("kilter.board.cancel"),
                        ) { Text("Cancel") }
                    }

                    KilterBoardController.State.FAILED -> {
                        Text(
                            board.failureMessage ?: "Couldn't connect to the board.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedButton(
                            onClick = { requestConnect() },
                            modifier = Modifier.fillMaxWidth().testTag("kilter.illuminate"),
                        ) { Icon(Icons.Filled.Lightbulb, contentDescription = null); Text("  Try again") }
                    }

                    KilterBoardController.State.BLUETOOTH_OFF -> {
                        Text(
                            "Bluetooth is off. Turn it on to connect your board.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().testTag("kilter.board.bluetoothOff"),
                        )
                        OutlinedButton(
                            onClick = { requestConnect() },
                            modifier = Modifier.fillMaxWidth().testTag("kilter.illuminate"),
                        ) { Icon(Icons.Filled.Lightbulb, contentDescription = null); Text("  Connect board") }
                    }

                    else -> {   // IDLE
                        OutlinedButton(
                            onClick = { requestConnect() },
                            modifier = Modifier.fillMaxWidth().testTag("kilter.illuminate"),
                        ) {
                            Icon(Icons.Filled.Lightbulb, contentDescription = null)
                            Text("  Connect board")
                        }
                    }
                }
            }

            betaLinks.firstOrNull()?.let { link ->
                TextButton(onClick = { uriHandler.openUri(link) }, modifier = Modifier.testTag("kilter.beta")) {
                    Text("▶ Beta video")
                }
            }
            climb?.let { Text("Set by ${it.setter}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

@Composable
private fun Stat(label: String, value: String, testTag: String?) {
    Column(horizontalAlignment = Alignment.CenterHorizontally,
        modifier = if (testTag != null) Modifier.testTag(testTag) else Modifier) {
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun LogButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isSend: Boolean,
    modifier: Modifier,
    testTag: String,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        modifier = modifier.testTag(testTag),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (isSend) Color(0xFF30A46C) else Color(0xFFF76808)),
    ) {
        Icon(icon, contentDescription = null); Text("  $label")
    }
}

/** How grade changes across board angles — the selected angle highlighted in the Kilter accent. */
@Composable
private fun GradeChart(stats: List<KilterClimbStat>, selectedAngle: Int, catalog: KilterCatalog) {
    val accent = Color(0xFFD97706)
    val muted = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.30f)
    val diffs = stats.map { it.difficulty }
    val lo = (diffs.minOrNull() ?: 0.0) - 1.0
    val hi = (diffs.maxOrNull() ?: 1.0) + 1.0
    val range = (hi - lo).coerceAtLeast(1.0)
    Column(Modifier.fillMaxWidth()) {
        Text("Grade by angle", style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(6.dp))
        Row(Modifier.fillMaxWidth().height(92.dp), verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            stats.forEach { s ->
                val frac = (((s.difficulty - lo) / range).toFloat()).coerceIn(0.06f, 1f)
                Box(Modifier.weight(1f).fillMaxHeight(frac)
                    .background(if (s.angle == selectedAngle) accent else muted, RoundedCornerShape(3.dp)))
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            stats.forEach { s ->
                Text("${s.angle}", Modifier.weight(1f), textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelSmall, maxLines = 1,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** One legend entry: the role's *shape* (not a plain dot) in the role color, teaching the color-blind-
 *  friendly shape code the board draws. Uses the same `holdPath` the board uses. */
@Composable
private fun LegendDot(hex: String, role: String, label: String) {
    val color = hexColor(hex)
    val shape = KilterHoldShape.forRole(role)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Canvas(Modifier.size(11.dp)) {
            drawPath(
                holdPath(shape, Offset(size.width / 2f, size.height / 2f), size.minDimension * 0.92f),
                color, style = Stroke(width = 2f, join = StrokeJoin.Round))
        }
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Bundles the catalog load so it happens in one shot off the main thread. */
private data class Loaded(
    val climb: KilterClimb,
    val stats: List<KilterClimbStat>,
    val holds: List<KilterHold>,
    val geometry: KilterBoardGeometry,
    val beta: List<String>,
    val effectiveSize: Int,
)
