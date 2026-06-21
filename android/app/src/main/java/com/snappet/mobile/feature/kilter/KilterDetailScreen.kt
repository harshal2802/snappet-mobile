package com.snappet.mobile.feature.kilter

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DoNotTouch
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RichTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
/**
 * Issue #93: the detail screen now pages through the browsed list's siblings — swipe left/right (or
 * the catalog order) to move climb-to-climb without backing out, with an "n / total" pill. When
 * [siblings] is empty (e.g. opened from Create / Surprise me) it shows just [uuid] with no pager.
 * [onSelectSibling] keeps the host's selected uuid in step so the back target and any re-entry are
 * correct. Mirrors iOS `KilterClimbDetailView`'s sibling swipe.
 */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun KilterDetailScreen(
    uuid: String,
    catalog: KilterCatalog,
    board: KilterBoardController,
    sessions: KilterSessionManager,
    onExit: () -> Unit,
    siblings: List<String> = emptyList(),
    onSelectSibling: (String) -> Unit = {},
    onBackToPlan: () -> Unit = {},
    onNextPick: (String) -> Unit = {},
) {
    val pages = remember(siblings, uuid) {
        // De-duplicate while preserving order: the browse list can legitimately repeat a uuid (the
        // Climb-of-the-day is also one of the filtered rows), and a repeated page uuid both confuses the
        // pager's identity tracking AND — as a duplicate LazyLayout key — makes it measure pages to zero
        // width, leaving their content unreachable. One page per climb.
        val deduped = (if (siblings.contains(uuid)) siblings else listOf(uuid)).distinct()
        deduped.ifEmpty { listOf(uuid) }
    }
    if (pages.size <= 1) {
        KilterClimbDetail(uuid = uuid, catalog = catalog, board = board, sessions = sessions,
            onExit = onExit, onBackToPlan = onBackToPlan, onNextPick = onNextPick)
        return
    }
    val startIndex = remember(pages, uuid) { pages.indexOf(uuid).coerceAtLeast(0) }
    val pagerState = androidx.compose.foundation.pager.rememberPagerState(
        initialPage = startIndex, pageCount = { pages.size },
    )
    // As the user settles on a new page, tell the host so the selected uuid (the back target) follows.
    androidx.compose.runtime.LaunchedEffect(pagerState.settledPage) {
        pages.getOrNull(pagerState.settledPage)?.let { if (it != uuid) onSelectSibling(it) }
    }
    // Host → pager: when the host changes the selected climb (e.g. "Next pick" sets selectedUuid), move
    // the pager to it — rememberPagerState ignores a changed initialPage on recomposition, so the page
    // must be scrolled explicitly or the advance is a silent no-op. The settledPage effect above is the
    // reverse direction (swipe → host); together they stay consistent without looping (idempotent).
    androidx.compose.runtime.LaunchedEffect(uuid, pages) {
        val target = pages.indexOf(uuid)
        if (target >= 0 && target != pagerState.currentPage) pagerState.animateScrollToPage(target)
    }
    androidx.compose.foundation.pager.HorizontalPager(
        state = pagerState,
        modifier = Modifier.fillMaxSize().testTag("kilter.detail.pager"),
        // Keep neighbours warm so a swipe lands on rendered content, not a spinner.
        beyondViewportPageCount = 1,
        // A stable per-climb key so the pager tracks pages by identity across recompositions. `pages` is
        // de-duplicated above, so these keys are unique (a Climb-of-the-day that also appears in the list
        // would otherwise repeat a uuid here — a duplicate LazyLayout key — and the pager would mismeasure
        // the page to zero width, making its content unreachable).
        key = { pages[it] },
    ) { page ->
        val isCurrent = page == pagerState.currentPage
        Box(
            Modifier
                .fillMaxSize()
                .then(if (isCurrent) Modifier else Modifier.clearAndSetSemantics {}),
        ) {
            KilterClimbDetail(
                uuid = pages[page], catalog = catalog, board = board, sessions = sessions, onExit = onExit,
                positionLabel = "${page + 1} / ${pages.size}",
                onBackToPlan = onBackToPlan, onNextPick = onNextPick,
                chromeless = true,
            )
        }
    }
}

/**
 * Top-bar + body chrome for the climb detail. Normally the shared [ModuleScaffold]. Inside the sibling
 * pager ([chromeless]) it's a plain `Column` with a hand-rolled [TopAppBar] instead — a `Scaffold` there
 * nests a `SubcomposeLayout` within the pager's LazyLayout and mismeasures the scrollable body to zero
 * width, so its log buttons become unhittable. The plain column lays the body out at full width while
 * keeping the same back arrow + title + actions (so per-page Save/Share/back all still work).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DetailChrome(
    chromeless: Boolean,
    title: String,
    onExit: () -> Unit,
    actions: @Composable (androidx.compose.foundation.layout.RowScope.() -> Unit),
    content: @Composable (PaddingValues) -> Unit,
) {
    if (!chromeless) {
        ModuleScaffold(title = title, onExit = onExit, actions = actions, content = content)
        return
    }
    Column(Modifier.fillMaxSize()) {
        androidx.compose.material3.TopAppBar(
            title = { Text(title) },
            navigationIcon = {
                IconButton(
                    onClick = onExit,
                    modifier = Modifier.testTag("BackButton")
                        .semantics { contentDescription = "Back" },
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
            actions = actions,
        )
        content(PaddingValues(0.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KilterClimbDetail(
    uuid: String,
    catalog: KilterCatalog,
    board: KilterBoardController,
    sessions: KilterSessionManager,
    onExit: () -> Unit,
    positionLabel: String? = null,
    onBackToPlan: () -> Unit = {},
    onNextPick: (String) -> Unit = {},
    // When hosted in the sibling pager, skip the M3 `Scaffold` chrome (the pager renders one page of this
    // per climb): a `Scaffold` nests a `SubcomposeLayout` inside the pager's own LazyLayout, which there
    // mismeasures the scrollable body to zero width — leaving its log buttons unhittable. The chromeless
    // path renders an equivalent plain top bar + body so the content lays out and stays interactive.
    chromeless: Boolean = false,
) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val dao = container.database.kilterDao()
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val snackbar = com.snappet.mobile.ui.LocalSnackbarController.current
    val haptics = com.snappet.mobile.ui.rememberSnappetHaptics()
    // Issue #89: BLE permission denial used to be a silent no-op — track it to show a rationale +
    // Settings deep link so Connect is never a dead control.
    var permissionDenied by remember { mutableStateOf(false) }

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
    var showShareSheet by remember { mutableStateOf(false) }

    // Push the persisted/selected dialect to the controller (initial sync + on every switch); a switch
    // re-lights the current climb instantly inside the controller.
    androidx.compose.runtime.LaunchedEffect(apiLevel) { board.setApiLevel(apiLevel) }

    androidx.compose.runtime.LaunchedEffect(uuid) {
        val loaded = withContext(Dispatchers.IO) {
            // Resolve a catalog climb first, else one the user authored (KilterCreatedClimb → asClimb) so
            // created climbs open in this same screen — render, logging, favorite, BLE all work unchanged.
            val created = dao.createdByUuid(uuid)
            val c = catalog.climb(uuid) ?: created?.asClimb() ?: return@withContext null
            // Seed the board size to this layout's default if unset/invalid, then map LEDs for it.
            val eff = if (catalog.sizes(c.layoutId).any { it.id == productSizeId }) productSizeId
            else catalog.defaultSizeId(c.layoutId)
            // Created climbs have no per-angle catalog stats — synthesize one from the designed angle +
            // predicted/chosen grade so the grade row and angle picker still read.
            var s = catalog.stats(uuid)
            if (s.isEmpty() && created?.predictedGrade != null) {
                s = listOf(KilterClimbStat(created.angle, created.predictedGrade, null, 0, 0.0, ""))
            }
            Loaded(c, s, catalog.holds(c, eff), catalog.boardGeometry(c.layoutId, eff),
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

    // Auto-dismiss the inline log pill after ~3s (issue #89: it was set and never cleared).
    androidx.compose.runtime.LaunchedEffect(logConfirmation) {
        if (logConfirmation != null) {
            kotlinx.coroutines.delay(3000)
            logConfirmation = null
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        if (granted.values.all { it }) {
            permissionDenied = false
            board.connect()
        } else {
            // Denial is no longer silent — surface a rationale + Settings link instead (issue #89).
            permissionDenied = true
        }
    }

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
        haptics.commit()
        logConfirmation = "Logged ${status.label.lowercase()} · $grade"
        // Persist the ascent IMMEDIATELY (iOS parity: `modelContext.insert` + save on tap). The earlier
        // design deferred the whole write to the undo snackbar's timeout (issue #89) — but that timeout
        // never fired once the climber tapped back to the catalog (the snackbar host is disposed) and was
        // never delivered to the test clock at all, so the just-logged send simply never reached History.
        // The write runs on the process-lifetime app scope so it survives leaving the detail screen, and
        // Undo now deletes the row it wrote (a real, addressable delete) rather than cancelling a no-op.
        container.appScope.launch {
            // Issue #92: the first logged climb of a sitting auto-opens a "manual" session so ascents
            // group without the user discovering the kebab Start. start() is a no-op if one is open.
            if (sessions.currentSessionId == null) sessions.start(selectedAngle, "manual")
            val sessionId = sessions.currentSessionId
            val rowId = dao.insertLog(
                KilterLogEntry(
                    climbUuid = c.uuid, climbName = c.name, angle = selectedAngle,
                    difficulty = stat.difficulty, gradeLabel = grade, status = status.name,
                    createdAt = System.currentTimeMillis(), sessionId = sessionId,
                )
            )
            // Tick the active planned session, if this run came from "Plan a session": flips the matching
            // plan item to sent/attempted. No-op for an ad-hoc session or off-plan climb.
            sessions.applyLogToPlan(c.uuid, status, System.currentTimeMillis())
            container.core.log("kilter", "log-${status.name.lowercase()}",
                "${status.label} ${c.name} ($grade @${selectedAngle}°)", stat.difficulty)
            // Offer Undo on the app scope's main-thread launch so it survives a fast back-out too; it
            // simply deletes the entry we just wrote.
            snackbar.showUndo(
                message = "Logged ${status.label.lowercase()} · $grade",
                onUndo = {
                    logConfirmation = null
                    container.appScope.launch { dao.deleteLogById(rowId) }
                },
                commit = {},
            )
        }
    }

    fun toggleFavorite() {
        scope.launch {
            val existing = favorites.firstOrNull { it.climbUuid == uuid }
            if (existing != null) dao.removeFavorite(existing)
            else dao.addFavorite(KilterFavorite(uuid, System.currentTimeMillis()))
        }
    }

    // P5 (Kilter Improvement, On the Board): explicitly lighting a climb on the board records a lit
    // event — the new axis that surfaces every climb pulled up and worked, even ones never logged as an
    // ascent. Captured ONLY on this explicit light (not the passive auto-light on connect), mirroring the
    // iOS "capture-on-explicit-light" fix. Deduped per climb-per-session at the DAO upsert. The board
    // illuminate behavior is unchanged; the capture rides alongside it off the main thread.
    fun lightClimb() {
        board.illuminate(holds)
        val c = climb ?: return
        val stat = stats.firstOrNull { it.angle == selectedAngle }
        val grade = stat?.let { catalog.gradeLabel(it.difficulty) } ?: ""
        val connected = board.isConnected
        val sessionId = sessions.currentSessionId
        scope.launch {
            dao.upsertLitEvent(
                KilterLitEvent(
                    climbUuid = c.uuid, climbName = c.name, gradeLabel = grade, angle = selectedAngle,
                    layoutId = c.layoutId, sizeId = productSizeId, litAt = System.currentTimeMillis(),
                    wasConnected = connected, sessionId = sessionId,
                )
            )
        }
    }

    DetailChrome(
        chromeless = chromeless,
        title = climb?.name ?: "Climb",
        onExit = onExit,
        actions = {
            // Issue #91: share the climb as a cross-platform QR + deep link (with a "Copy hold string"
            // fallback for climbs the recipient may not have), replacing the old text-only frames send.
            climb?.let { c ->
                IconButton(onClick = { showShareSheet = true }, modifier = Modifier.testTag("kilter.share")) {
                    Icon(Icons.Filled.Share, contentDescription = "Share climb")
                }
            }
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
            // Plan-backed run: this climb is a station in the plan — jump back to the list or advance to
            // the next pending pick (a forward loop, not a back-button hunt). iOS-parity climb strip.
            if (sessions.currentPlanId != null) {
                val nextPick = sessions.nextPlanClimb(uuid)
                Row(
                    Modifier.fillMaxWidth().testTag("kilter.climb.planStrip"),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    androidx.compose.material3.TextButton(onClick = onBackToPlan,
                        modifier = Modifier.testTag("kilter.climb.backToPlan")) { Text("‹ Back to plan") }
                    sessions.planProgress?.let { (d, t) ->
                        Text("$d/$t", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (nextPick != null) {
                        androidx.compose.material3.TextButton(onClick = { onNextPick(nextPick) },
                            modifier = Modifier.testTag("kilter.climb.nextPick")) { Text("Next pick ›") }
                    } else {
                        Text("Plan done", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            // Issue #93: position pill when paging through siblings ("3 / 24"). Swipe left/right moves.
            positionLabel?.let { pos ->
                Box(
                    Modifier.background(MaterialTheme.colorScheme.surfaceVariant, CircleShape)
                        .padding(horizontal = 12.dp, vertical = 4.dp).testTag("kilter.detail.position"),
                ) {
                    Text(pos, style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
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
                // hold, else a quiet "Matching" chip (the default). TAP it for an explanation (the
                // convention isn't obvious) via a rich tooltip. Mirrors iOS.
                val noMatch = climb?.isNoMatch == true
                val matchColor = if (noMatch) com.snappet.mobile.ui.theme.pulseWarning() else MaterialTheme.colorScheme.onSurfaceVariant
                val matchTooltip = rememberTooltipState(isPersistent = true)
                TooltipBox(
                    positionProvider = TooltipDefaults.rememberRichTooltipPositionProvider(),
                    tooltip = {
                        RichTooltip(title = { Text(if (noMatch) "No matching" else "Matching allowed") }) {
                            Text(
                                "“Matching” means putting both hands on the same hold. " +
                                    if (noMatch) "This climb is set no-matching — the setter asks you not to match hands on any hold."
                                    else "Matching is allowed on this climb (the default).")
                        }
                    },
                    state = matchTooltip,
                ) {
                    Row(Modifier.clip(CircleShape)
                        .background(matchColor.copy(alpha = if (noMatch) 0.18f else 0.14f), CircleShape)
                        .clickable { scope.launch { matchTooltip.show() } }
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
                }
                if (isClassic) {
                    val classic = com.snappet.mobile.ui.theme.pulseWarning()
                    Box(Modifier.background(classic.copy(alpha = 0.18f), CircleShape)
                        .padding(horizontal = 10.dp, vertical = 4.dp)) {
                        Text("★ Classic", style = MaterialTheme.typography.labelMedium,
                            color = classic, fontWeight = FontWeight.SemiBold)
                    }
                }
                if (fa.isNotEmpty()) {
                    Text("FA $fa", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
            }

            // Issue #93: each log action has a DISTINCT icon (Flash = bolt, Sent = check, Project = flag,
            // Attempt = replay — no two share a glyph; Project's flag also no longer clashes with the
            // top-bar Saved star) and a long-press RichTooltip spelling out the four climbing statuses,
            // which are jargon to a newcomer. A one-line "What do these mean?" affordance teaches the
            // long-press.
            Text("What do these mean? Long-press a button.",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("kilter.log.help"))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LogButton("Flash", Icons.Filled.Bolt, true, "Flash",
                    "Sent it clean on your very first try, with no prior practice on it.",
                    Modifier.weight(1f), "kilter.log.flash") { log(KilterAscentStatus.FLASH) }
                LogButton("Sent", Icons.Filled.Check, true, "Sent",
                    "Completed the climb top to bottom (after one or more goes).",
                    Modifier.weight(1f), "kilter.log.sent") { log(KilterAscentStatus.SENT) }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LogButton("Project", Icons.Filled.Flag, false, "Project",
                    "A climb you're working toward but haven't sent yet — your current project.",
                    Modifier.weight(1f), "kilter.log.project") { log(KilterAscentStatus.PROJECT) }
                LogButton("Attempt", Icons.Filled.Replay, false, "Attempt",
                    "A try that didn't top out — logged so your effort still counts.",
                    Modifier.weight(1f), "kilter.log.attempt") { log(KilterAscentStatus.ATTEMPT) }
            }
            androidx.compose.animation.AnimatedVisibility(visible = logConfirmation != null) {
                val confirm = com.snappet.mobile.ui.theme.pulseSuccess()
                Box(Modifier.background(confirm.copy(alpha = 0.16f), CircleShape)
                    .padding(horizontal = 12.dp, vertical = 6.dp)) {
                    Text("✓ ${logConfirmation ?: ""}", style = MaterialTheme.typography.bodySmall,
                        color = confirm, fontWeight = FontWeight.Medium,
                        modifier = Modifier.testTag("kilter.logConfirmation"))
                }
            }

            if (stats.size > 1) GradeChart(stats, selectedAngle, catalog)

            // Illuminate (Phase 2). Simulators / devices with no BLE radio never show the section.
            if (board.state != KilterBoardController.State.UNSUPPORTED) {
                if (permissionDenied) {
                    PermissionRationale(
                        onOpenSettings = {
                            val intent = android.content.Intent(
                                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.fromParts("package", context.packageName, null),
                            )
                            runCatching { context.startActivity(intent) }
                        },
                    )
                }
                when (board.state) {
                    KilterBoardController.State.CONNECTED -> {
                        OutlinedButton(
                            onClick = { lightClimb() },
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

    if (showShareSheet) {
        climb?.let { c ->
            com.snappet.mobile.feature.kilter.share.KilterShareSheet(
                uuid = c.uuid, angle = selectedAngle, frames = c.frames,
                onDismiss = { showShareSheet = false },
            )
        }
    }
}

/**
 * Shown when Nearby-devices (BLE) permission was denied (issue #89): explains why the board needs it
 * and deep-links to app Settings, so the Connect button is never a silently dead control.
 */
@Composable
private fun PermissionRationale(onOpenSettings: () -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.4f))
            .padding(12.dp)
            .testTag("kilter.permissionRationale"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "Snappet needs Nearby devices permission to find your board.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onErrorContainer,
        )
        OutlinedButton(onClick = onOpenSettings, modifier = Modifier.testTag("kilter.openSettings")) {
            Text("Open Settings")
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LogButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isSend: Boolean,
    tooltipTitle: String,
    tooltipBody: String,
    modifier: Modifier,
    testTag: String,
    onClick: () -> Unit,
) {
    // Issue #93: a long-press RichTooltip explains the climbing status (jargon to a newcomer).
    val tooltipState = rememberTooltipState(isPersistent = true)
    // Keep the caller's `Modifier.weight(1f)` on a plain Box, not on the TooltipBox: TooltipBox wraps its
    // anchor in a SubcomposeLayout, and a weighted SubcomposeLayout inside the sibling HorizontalPager's
    // own LazyLayout mismeasures — the second button in each Row collapses to ZERO width, so its tap never
    // lands on the Button and the log is silently dropped (History stays empty). The Box owns the weight and
    // lays the row out evenly; the TooltipBox + Button just fill it. Same fix family as the chromeless body.
    Box(modifier) {
        TooltipBox(
            positionProvider = TooltipDefaults.rememberRichTooltipPositionProvider(),
            tooltip = { RichTooltip(title = { Text(tooltipTitle) }) { Text(tooltipBody) } },
            state = tooltipState,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Button(
                onClick = onClick,
                modifier = Modifier.fillMaxWidth().testTag(testTag),
            colors = ButtonDefaults.buttonColors(
                // Issue #97: route through the accent tokens instead of re-hardcoded hex (Leaf = send,
                // Ember = a try/attempt).
                containerColor = if (isSend) com.snappet.mobile.ui.theme.SnappetAccents.Leaf
                else com.snappet.mobile.ui.theme.SnappetAccents.Ember),
            ) {
                Icon(icon, contentDescription = null); Text("  $label")
            }
        }
    }
}

/** How grade changes across board angles — the selected angle highlighted in the Kilter accent. */
@Composable
private fun GradeChart(stats: List<KilterClimbStat>, selectedAngle: Int, catalog: KilterCatalog) {
    // Issue #97: the selected bar reads in the Kilter module accent token (was pulseWarning()).
    val accent = com.snappet.mobile.ui.theme.kilterAccent()
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
