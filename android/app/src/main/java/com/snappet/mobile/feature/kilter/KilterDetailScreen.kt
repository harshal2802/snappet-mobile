package com.snappet.mobile.feature.kilter

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.graphics.Color
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
    var betaLinks by remember { mutableStateOf<List<String>>(emptyList()) }
    var selectedAngle by remember { mutableStateOf(KilterSettings.angle(context)) }
    var logConfirmation by remember { mutableStateOf<String?>(null) }
    var angleMenu by remember { mutableStateOf(false) }

    androidx.compose.runtime.LaunchedEffect(uuid) {
        val loaded = withContext(Dispatchers.IO) {
            val c = catalog.climb(uuid) ?: return@withContext null
            Quad(c, catalog.stats(uuid), catalog.holds(c), catalog.betaLinks(uuid))
        } ?: return@LaunchedEffect
        climb = loaded.climb; stats = loaded.stats; holds = loaded.holds; betaLinks = loaded.beta
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
            KilterBoard(holds, Modifier.fillMaxWidth().height(340.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                LegendDot("00DD00", "Start"); LegendDot("00FFFF", "Middle")
                LegendDot("FF00FF", "Finish"); LegendDot("FFA500", "Foot")
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
                Stat("Grade", currentStat?.let { catalog.gradeLabel(it.difficulty) } ?: "—", "kilter.grade")
                Stat("Quality", "★".repeat((currentStat?.quality ?: 0.0).roundToInt().coerceIn(0, 3)), null)
                Stat("Ascents", "${currentStat?.ascents ?: 0}", null)
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LogButton("Flash", Icons.Filled.Bolt, true, Modifier.weight(1f), "kilter.log.flash") { log(KilterAscentStatus.FLASH) }
                LogButton("Sent", Icons.Filled.Check, true, Modifier.weight(1f), "kilter.log.sent") { log(KilterAscentStatus.SENT) }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LogButton("Project", Icons.Filled.Star, false, Modifier.weight(1f), "kilter.log.project") { log(KilterAscentStatus.PROJECT) }
                LogButton("Attempt", Icons.Filled.Bolt, false, Modifier.weight(1f), "kilter.log.attempt") { log(KilterAscentStatus.ATTEMPT) }
            }
            logConfirmation?.let {
                Text(it, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("kilter.logConfirmation"))
            }

            // Illuminate (Phase 2)
            if (board.state != KilterBoardController.State.UNSUPPORTED) {
                OutlinedButton(
                    onClick = { if (board.isConnected) board.illuminate(holds) else requestConnect() },
                    modifier = Modifier.fillMaxWidth().testTag("kilter.illuminate"),
                ) {
                    Icon(Icons.Filled.Lightbulb, contentDescription = null)
                    Text(
                        when {
                            board.isConnected -> "  Light up this climb"
                            board.state == KilterBoardController.State.SCANNING -> "  Searching for board…"
                            board.state == KilterBoardController.State.CONNECTING -> "  Connecting…"
                            board.state == KilterBoardController.State.FAILED -> "  Couldn't connect — retry"
                            else -> "  Connect board"
                        }
                    )
                }
                if (board.isConnected) {
                    TextButton(onClick = { board.disconnect() }) { Text("Disconnect board") }
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

@Composable
private fun LegendDot(hex: String, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(10.dp).background(hexColor(hex), CircleShape))
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Small 4-tuple to return the catalog load in one shot off the main thread. */
private data class Quad(
    val climb: KilterClimb,
    val stats: List<KilterClimbStat>,
    val holds: List<KilterHold>,
    val beta: List<String>,
)
