package com.snappet.mobile.feature.kilter

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.EventNote
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.LocalSpacing
import com.snappet.mobile.ui.theme.snappetSurfaceTransition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private enum class KilterScreen { ROOT, DETAIL, HISTORY, SETTINGS, CREATE, SESSION, SCAN, PLAN }

/**
 * Root entry for the Kilter Board mini-app. Browse the user-installed read-only catalog (filtered by
 * layout, angle, grade, and a Saved filter), open a climb for the board render + logging, and review
 * History. The board controller + session manager are created here and shared with the detail
 * screen. Mirrors the iOS `KilterRootView`. `onExit` returns to the App Library.
 */
@Composable
fun KilterRoot(onExit: () -> Unit) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val dao = container.database.kilterDao()
    val board = remember { KilterBoardController(context) }
    // Issue #92: a standard BLE heart-rate strap (0x180D) captured during a session. The thin platform
    // edge; live capture is device-pending. The session manager flushes its avg/max summary on end.
    val heartRate = remember { com.snappet.mobile.feature.kilter.hr.BleHeartRateSource(context) }
    val sessions = remember { KilterSessionManager(dao, heartRate) }
    // Re-hydrate the open session + its pinned plan from the store on entry (the manager is
    // remember-scoped, so this survives navigating out of and back into Kilter, and a relaunch).
    androidx.compose.runtime.LaunchedEffect(Unit) { sessions.recover() }
    // Seed the board's payload dialect from the persisted preference (Standard/Legacy).
    androidx.compose.runtime.LaunchedEffect(Unit) { board.setApiLevel(KilterSettings.apiLevel(context)) }

    // The app ships no catalog (issue #42); open the user-installed one off the main thread, showing a
    // brief loading state. `reloadToken` re-opens the reader after an import (sync screen) or remove
    // (Settings).
    var catalog by remember { mutableStateOf<KilterCatalog?>(null) }
    var loading by remember { mutableStateOf(true) }
    var reloadToken by remember { mutableStateOf(0) }
    androidx.compose.runtime.LaunchedEffect(reloadToken) {
        loading = true
        catalog = withContext(Dispatchers.IO) {
            KilterCatalog.reset()
            KilterCatalog.get(context)
        }
        loading = false
    }
    val cat = catalog
    if (loading || cat == null) {
        ModuleScaffold(title = "Kilter Board", onExit = onExit) { padding ->
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                androidx.compose.material3.CircularProgressIndicator()
            }
        }
        return
    }

    // No catalog on this device yet → the opt-in import screen instead of an empty browse list.
    if (!cat.isAvailable) {
        KilterCatalogSyncScreen(onInstalled = { reloadToken++ }, onExit = onExit)
        return
    }

    var screen by rememberSaveable { mutableStateOf(KilterScreen.ROOT) }
    var selectedUuid by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedSessionId by rememberSaveable { mutableStateOf<String?>(null) }
    // Issue #93: the browsed list's uuids, plumbed into detail so it can swipe through siblings without
    // backing out to the catalog each time (iOS parity). Empty for a single-climb open (e.g. from Create).
    var browseSiblings by rememberSaveable { mutableStateOf<List<String>>(emptyList()) }

    // Issue #91: a queued `snappet://kilter/climb/...` deep link opens its climb at the encoded angle.
    val pendingLink = KilterDeepLinkBus.pending
    androidx.compose.runtime.LaunchedEffect(pendingLink) {
        val (uuid, angle) = pendingLink ?: return@LaunchedEffect
        angle?.let { KilterSettings.setAngle(context, it) }
        // Open the climb if it resolves (catalog or created); otherwise fall through to the scanner's
        // "not in your catalog" handling by opening detail, which already renders a created/missing case.
        selectedUuid = uuid
        screen = KilterScreen.DETAIL
        KilterDeepLinkBus.consume()
    }

    // Issue #86: system back pops one level, mirroring each sub-screen's onExit (all of them —
    // including DETAIL when entered from CREATE — return to ROOT). At ROOT the handler is disabled
    // so back falls through to the app-level NavHost (→ app grid).
    BackHandler(enabled = screen != KilterScreen.ROOT) { screen = KilterScreen.ROOT }

    // Issue #97: Kilter's sub-screen swaps (ROOT ↔ detail/history/settings/create) slide+fade like the
    // rest of the suite instead of hard-cutting; ROOT is the "home" so any move off it reads forward and
    // a move back to it reads backward. Gated on reduce-motion.
    val reduceMotion = LocalReduceMotion.current
    androidx.compose.animation.AnimatedContent(
        targetState = screen,
        transitionSpec = {
            snappetSurfaceTransition(reduceMotion, forward = targetState != KilterScreen.ROOT)
        },
        label = "kilterScreen",
    ) { target ->
    when (target) {
        KilterScreen.PLAN -> KilterPlanScreen(
            catalog = cat, dao = dao,
            onOpenClimb = { uuid, siblings -> selectedUuid = uuid; browseSiblings = siblings; screen = KilterScreen.DETAIL },
            onExit = { screen = KilterScreen.ROOT },
        )
        KilterScreen.HISTORY -> KilterHistoryScreen(
            dao = dao,
            onOpenSession = { id -> selectedSessionId = id; screen = KilterScreen.SESSION },
            onExit = { screen = KilterScreen.ROOT },
        )
        KilterScreen.SESSION -> selectedSessionId?.let { id ->
            KilterSessionDetailScreen(
                sessionId = id, dao = dao, catalog = cat,
                onExit = { screen = KilterScreen.HISTORY },
            )
        }
        KilterScreen.SCAN -> KilterScannerScreen(
            onResolved = { uuid -> selectedUuid = uuid; screen = KilterScreen.DETAIL },
            onExit = { screen = KilterScreen.ROOT },
        )
        KilterScreen.SETTINGS -> KilterSettingsScreen(
            catalog = cat, dao = dao,
            onCatalogChanged = { reloadToken++; screen = KilterScreen.ROOT },
            onExit = { screen = KilterScreen.ROOT })
        KilterScreen.DETAIL -> selectedUuid?.let { uuid ->
            KilterDetailScreen(
                uuid = uuid,
                siblings = browseSiblings,
                onSelectSibling = { selectedUuid = it },
                catalog = cat, board = board, sessions = sessions,
                onExit = { screen = KilterScreen.ROOT },
            )
        }
        KilterScreen.CREATE -> CreateClimbScreen(
            catalog = cat, dao = dao, board = board,
            onCreated = { selectedUuid = it; browseSiblings = emptyList(); screen = KilterScreen.DETAIL },
            onExit = { screen = KilterScreen.ROOT },
        )
        KilterScreen.ROOT -> KilterCatalogScreen(
            catalog = cat,
            dao = dao,
            sessions = sessions,
            onOpenClimb = { uuid, siblings -> selectedUuid = uuid; browseSiblings = siblings; screen = KilterScreen.DETAIL },
            onOpenHistory = { screen = KilterScreen.HISTORY },
            onOpenSettings = { screen = KilterScreen.SETTINGS },
            onOpenCreate = { screen = KilterScreen.CREATE },
            onOpenScan = { screen = KilterScreen.SCAN },
            onOpenPlan = { screen = KilterScreen.PLAN },
            onExit = onExit,
        )
    }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KilterCatalogScreen(
    catalog: KilterCatalog,
    dao: KilterDao,
    sessions: KilterSessionManager,
    onOpenClimb: (String, List<String>) -> Unit,
    onOpenHistory: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenCreate: () -> Unit,
    onOpenScan: () -> Unit,
    onOpenPlan: () -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val favorites by dao.favoritesFlow().collectAsState(initial = emptyList())
    val logs by dao.logsFlow().collectAsState(initial = emptyList())
    val createdClimbs by dao.createdFlow().collectAsState(initial = emptyList())
    val favoriteUuids = remember(favorites) { favorites.map { it.climbUuid }.toSet() }
    val gradeFormat = remember { KilterSettings.gradeFormat(context) }

    val layouts = remember { catalog.layouts() }
    val angles = remember { catalog.angles() }
    val gradeScale = remember { catalog.gradeScale() }

    var layoutId by remember { mutableStateOf(KilterSettings.layout(context)) }
    var angle by remember { mutableStateOf(KilterSettings.angle(context)) }
    var minGrade by remember { mutableStateOf(KilterSettings.minGrade(context)) }
    var maxGrade by remember { mutableStateOf(KilterSettings.maxGrade(context)) }
    // The user's physical board size (product_size_id) — drives the on-screen render size + the LED map.
    // Picked inline beside Layout (when the layout has >1 size), cached, seeded/reset per layout.
    var productSizeId by remember { mutableStateOf(KilterSettings.productSizeId(context)) }
    val sizes = remember(layoutId) { catalog.sizes(layoutId) }
    // Keep the size valid for the layout — seed the default when unset, reset on a layout switch.
    androidx.compose.runtime.LaunchedEffect(layoutId) {
        if (sizes.none { it.id == productSizeId }) {
            productSizeId = catalog.defaultSizeId(layoutId)
            KilterSettings.setProductSizeId(context, productSizeId)
        }
    }
    var savedOnly by rememberSaveable { mutableStateOf(false) }
    var mineOnly by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    var sort by rememberSaveable { mutableStateOf(KilterSort.POPULAR) }
    var benchmarksOnly by rememberSaveable { mutableStateOf(false) }
    var minAscents by rememberSaveable { mutableStateOf(0) }
    var minQuality by rememberSaveable { mutableStateOf(0.0) }
    var showFilters by rememberSaveable { mutableStateOf(false) }
    var moreMenu by remember { mutableStateOf(false) }
    var climbs by remember { mutableStateOf<List<KilterListItem>>(emptyList()) }
    var cotd by remember { mutableStateOf<KilterListItem?>(null) }
    // True number of climbs matching the current search + filters (not capped by the list) — shown live.
    var resultCount by remember { mutableStateOf(0) }

    val showDiscovery = search.isBlank() && !savedOnly && !mineOnly
    val filter = KilterFilter(layoutId, angle, minGrade.toDouble(), maxGrade.toDouble(),
        search, sort, benchmarksOnly, minAscents, minQuality)

    androidx.compose.runtime.LaunchedEffect(filter, savedOnly, mineOnly, favorites, createdClimbs) {
        val result: Triple<List<KilterListItem>, KilterListItem?, Int> = withContext(Dispatchers.IO) {
            if (!catalog.isAvailable) Triple(emptyList(), null, 0)
            else if (mineOnly) {
                val term = search.trim().lowercase()
                val mine = createdClimbs.filter { it.layoutId == layoutId }
                    .filter { term.isEmpty() || it.name.lowercase().contains(term) || it.setterUsername.lowercase().contains(term) }
                    .map {
                        KilterListItem(it.uuid, it.name, it.setterUsername,
                            it.predictedGrade ?: 0.0,
                            it.predictedGrade?.let { g -> catalog.gradeLabel(g) } ?: "—", 0.0, 0)
                    }
                Triple(mine, null, mine.size)
            } else if (savedOnly) {
                val all = catalog.climbsByUuid(favorites.map { it.climbUuid })
                val term = search.trim().lowercase()
                val filtered = if (term.isEmpty()) all
                    else all.filter { it.name.lowercase().contains(term) || it.setter.lowercase().contains(term) }
                Triple(filtered, null, filtered.size)
            } else {
                Triple(catalog.list(filter),
                    if (showDiscovery) catalog.climbOfTheDay(layoutId, angle) else null,
                    catalog.count(filter))
            }
        }
        climbs = result.first; cotd = result.second; resultCount = result.third
    }

    ModuleScaffold(
        title = "Kilter Board",
        onExit = onExit,
        actions = {
            IconButton(onClick = { showFilters = true }, modifier = Modifier.testTag("kilter.filtersButton")) {
                Icon(Icons.Filled.FilterAlt, contentDescription = "Filters",
                    tint = if (filter.activeExtras > 0) MaterialTheme.colorScheme.primary else Color.Unspecified)
            }
            IconButton(onClick = onOpenHistory, modifier = Modifier.testTag("kilter.history")) {
                Icon(Icons.Filled.History, contentDescription = "History")
            }
            Box {
                IconButton(onClick = { moreMenu = true }, modifier = Modifier.testTag("kilter.more")) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "More")
                }
                DropdownMenu(expanded = moreMenu, onDismissRequest = { moreMenu = false }) {
                    if (sessions.currentSessionId != null) {
                        DropdownMenuItem(text = { Text("End session") },
                            leadingIcon = { Icon(Icons.Filled.StopCircle, null) },
                            onClick = { moreMenu = false; scope.launch { sessions.end() } })
                    } else {
                        DropdownMenuItem(text = { Text("Start session") },
                            leadingIcon = { Icon(Icons.Filled.PlayCircle, null) },
                            onClick = { moreMenu = false; scope.launch { sessions.start(angle, "manual") } })
                    }
                    // Issue #93: the guided "what should I climb today" entry point (iOS parity).
                    DropdownMenuItem(text = { Text("Plan a session") },
                        leadingIcon = { Icon(Icons.Filled.EventNote, null) },
                        modifier = Modifier.testTag("kilter.plan"),
                        onClick = { moreMenu = false; onOpenPlan() })
                    DropdownMenuItem(text = { Text("Surprise me") },
                        leadingIcon = { Icon(Icons.Filled.Casino, null) },
                        modifier = Modifier.testTag("kilter.surprise"),
                        onClick = {
                            moreMenu = false
                            scope.launch {
                                val pick = withContext(Dispatchers.IO) { catalog.randomClimb(filter) }
                                pick?.let { onOpenClimb(it.uuid, emptyList()) }
                            }
                        })
                    // Issue #91: scan a shared QR (from iOS or Android) to open the climb.
                    DropdownMenuItem(text = { Text("Scan QR") },
                        leadingIcon = { Icon(Icons.Filled.QrCodeScanner, null) },
                        modifier = Modifier.testTag("kilter.scanQr"),
                        onClick = { moreMenu = false; onOpenScan() })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("Settings") },
                        leadingIcon = { Icon(Icons.Filled.Settings, null) },
                        onClick = { moreMenu = false; onOpenSettings() })
                }
            }
        },
        floatingActionButton = {
            // Issue #94: climb authoring is a flagship feature — a visible FAB, not a kebab item.
            ExtendedFloatingActionButton(
                onClick = onOpenCreate,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("Create climb") },
                modifier = Modifier.testTag("kilter.create"),
            )
        },
    ) { padding ->
        if (!catalog.isAvailable) {
            // Defensive: KilterRoot already gates on availability and shows the opt-in import screen.
            EmptyState(padding, "Catalog unavailable", "The Kilter catalog couldn't be opened.")
            return@ModuleScaffold
        }
        Column(Modifier.fillMaxSize().padding(padding)) {
            OutlinedTextField(
                value = search, onValueChange = { search = it },
                placeholder = { Text("Search climbs or setters") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = {
                    if (search.isNotEmpty()) IconButton(onClick = { search = "" }) {
                        Icon(Icons.Filled.Close, contentDescription = "Clear")
                    }
                },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("kilter.search"),
            )
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilterDropdown("Layout", layouts.firstOrNull { it.id == layoutId }?.name ?: "—",
                    layouts.map { it.id to it.name }, "kilter.layout") { layoutId = it; KilterSettings.setLayout(context, it) }
                // Board size, right beside Layout — only when the layout offers a choice.
                if (sizes.size > 1) {
                    FilterDropdown("Size", sizes.firstOrNull { it.id == productSizeId }?.name ?: "—",
                        sizes.map { it.id to it.label }, "kilter.size") {
                        productSizeId = it; KilterSettings.setProductSizeId(context, it)
                    }
                }
                FilterDropdown("Angle", "$angle°", angles.map { it to "$it°" }, "kilter.angle") {
                    angle = it; KilterSettings.setAngle(context, it)
                }
                FilterDropdown("From", catalog.gradeLabel(minGrade.toDouble()),
                    gradeScale.map { it.first to it.second }, "kilter.minGrade") { minGrade = it; KilterSettings.setMinGrade(context, it) }
                FilterDropdown("To", catalog.gradeLabel(maxGrade.toDouble()),
                    gradeScale.map { it.first to it.second }, "kilter.maxGrade") { maxGrade = it; KilterSettings.setMaxGrade(context, it) }
                AssistChip(
                    onClick = { mineOnly = !mineOnly; if (mineOnly) savedOnly = false },
                    label = { Text("Mine") },
                    leadingIcon = { Icon(Icons.Filled.Build, contentDescription = null) },
                    colors = if (mineOnly) AssistChipDefaults.assistChipColors(
                        containerColor = MaterialTheme.colorScheme.primary,
                        labelColor = MaterialTheme.colorScheme.onPrimary,
                        leadingIconContentColor = MaterialTheme.colorScheme.onPrimary,
                    ) else AssistChipDefaults.assistChipColors(),
                    modifier = Modifier.testTag("kilter.mineToggle"),
                )
                AssistChip(
                    onClick = { savedOnly = !savedOnly; if (savedOnly) mineOnly = false },
                    label = { Text("Saved") },
                    leadingIcon = {
                        Icon(if (savedOnly) Icons.Filled.Star else Icons.Outlined.StarBorder, contentDescription = null)
                    },
                    colors = if (savedOnly) AssistChipDefaults.assistChipColors(
                        containerColor = MaterialTheme.colorScheme.primary,
                        labelColor = MaterialTheme.colorScheme.onPrimary,
                        leadingIconContentColor = MaterialTheme.colorScheme.onPrimary,
                    ) else AssistChipDefaults.assistChipColors(),
                    modifier = Modifier.testTag("kilter.savedToggle"),
                )
            }

            // Issue #97: the live-session banner springs in/out (slide-from-top + fade) rather than
            // popping, gated on reduce-motion.
            val reduceMotionBanner = LocalReduceMotion.current
            val sid = sessions.currentSessionId
            androidx.compose.animation.AnimatedVisibility(
                visible = sid != null,
                enter = androidx.compose.animation.expandVertically(
                    com.snappet.mobile.ui.theme.gated(reduceMotionBanner, com.snappet.mobile.ui.theme.SnappetMotion.standard())) +
                    androidx.compose.animation.fadeIn(com.snappet.mobile.ui.theme.gated(reduceMotionBanner, com.snappet.mobile.ui.theme.SnappetMotion.quick())),
                exit = androidx.compose.animation.shrinkVertically(
                    com.snappet.mobile.ui.theme.gated(reduceMotionBanner, com.snappet.mobile.ui.theme.SnappetMotion.quick())) +
                    androidx.compose.animation.fadeOut(com.snappet.mobile.ui.theme.gated(reduceMotionBanner, com.snappet.mobile.ui.theme.SnappetMotion.quick())),
            ) {
                val count = logs.count { it.sessionId == sid }
                val live = com.snappet.mobile.ui.theme.pulseSuccess()
                Row(
                    Modifier.fillMaxWidth().background(live.copy(alpha = 0.12f))
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Filled.FiberManualRecord, contentDescription = null, tint = live, modifier = Modifier.size(10.dp))
                    Text("Session · $count climb${if (count == 1) "" else "s"}",
                        style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                    androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                    // Issue #92: live HR pill when a strap is streaming (device-pending capture).
                    sessions.hr?.let { hr ->
                        if (hr.isStreaming || hr.latestBpm != null) {
                            KilterHRPill(bpm = hr.latestBpm, contactLost = hr.isContactLost, compact = true)
                        }
                    }
                    TextButton(onClick = { scope.launch { sessions.end() } }, modifier = Modifier.testTag("kilter.session.end")) {
                        Text("End")
                    }
                }
            }

            // Live count of matching climbs + a quick Clear when search/Saved/extra filters are active.
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Issue #97: the count rolls to its new value as filters/search change, gated on reduce-motion.
                val reduceMotion = LocalReduceMotion.current
                val animatedCount by androidx.compose.animation.core.animateIntAsState(
                    targetValue = resultCount,
                    animationSpec = com.snappet.mobile.ui.theme.gated(reduceMotion, com.snappet.mobile.ui.theme.SnappetMotion.standard()),
                    label = "kilter.count",
                )
                Text(if (animatedCount == 0) "No climbs" else "$animatedCount climb${if (animatedCount == 1) "" else "s"}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("kilter.count"))
                androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                if (search.isNotBlank() || savedOnly || mineOnly || filter.activeExtras > 0) {
                    TextButton(onClick = {
                        search = ""; savedOnly = false; mineOnly = false; sort = KilterSort.POPULAR
                        benchmarksOnly = false; minAscents = 0; minQuality = 0.0
                    }, modifier = Modifier.testTag("kilter.clearFilters")) { Text("Clear") }
                }
            }

            if (climbs.isEmpty() && cotd == null) {
                EmptyState(PaddingValues(0.dp),
                    when { search.isNotBlank() -> "No matches"; mineOnly -> "No climbs yet"; savedOnly -> "No saved climbs"; else -> "No climbs match" },
                    when {
                        search.isNotBlank() -> "No climbs match “$search” with the current filters."
                        mineOnly -> "Tap Create climb to design your first one for this layout."
                        savedOnly -> "Star climbs to find them here."
                        else -> "Try a wider grade range or fewer filters."
                    })
            } else {
                // Issue #93: the swipe-able sibling list is exactly what's on screen, in order — the
                // Climb-of-the-day first (when shown) then the filtered rows. Opening any climb hands
                // detail this list so left/right swipes move through the same set.
                val browseUuids = remember(cotd, climbs) {
                    (listOfNotNull(cotd?.uuid) + climbs.map { it.uuid })
                }
                // Bottom padding keeps the Create-climb FAB clear of the last row.
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 88.dp)) {
                    cotd?.let { c ->
                        item(key = "cotd") {
                            Text("CLIMB OF THE DAY", style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(start = 16.dp, top = 8.dp))
                            KilterClimbRow(c, favoriteUuids.contains(c.uuid), gradeFormat, featured = true,
                                modifier = Modifier.testTag("kilter.cotd")) { onOpenClimb(c.uuid, browseUuids) }
                            HorizontalDivider()
                        }
                    }
                    items(climbs, key = { it.uuid }) { item ->
                        // Issue #97: rows fade/slide into place as the filtered list changes (Compose's
                        // built-in item placement animation; it no-ops visually under reduce-motion since
                        // the list is rebuilt rather than reordered in that case).
                        KilterClimbRow(item, favoriteUuids.contains(item.uuid), gradeFormat,
                            modifier = Modifier.animateItem()) { onOpenClimb(item.uuid, browseUuids) }
                    }
                }
            }
        }
        if (showFilters) {
            KilterFiltersSheet(
                sort = sort, benchmarksOnly = benchmarksOnly, minAscents = minAscents, minQuality = minQuality,
                onChange = { s, b, a, q -> sort = s; benchmarksOnly = b; minAscents = a; minQuality = q },
                onDismiss = { showFilters = false },
            )
        }
    }
}

/** Bottom sheet of advanced browse criteria — sort, classics/benchmarks, min ascents/quality. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KilterFiltersSheet(
    sort: KilterSort,
    benchmarksOnly: Boolean,
    minAscents: Int,
    minQuality: Double,
    onChange: (KilterSort, Boolean, Int, Double) -> Unit,
    onDismiss: () -> Unit,
) {
    var s by remember { mutableStateOf(sort) }
    var b by remember { mutableStateOf(benchmarksOnly) }
    var a by remember { mutableStateOf(minAscents) }
    var q by remember { mutableStateOf(minQuality) }
    val ascentChoices = listOf(0, 10, 50, 100, 500, 1000)

    ModalBottomSheet(onDismissRequest = { onChange(s, b, a, q); onDismiss() }) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Filters", style = MaterialTheme.typography.titleLarge)

            Text("Sort by", style = MaterialTheme.typography.labelLarge)
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KilterSort.entries.forEach { opt ->
                    FilterChip(selected = s == opt, onClick = { s = opt }, label = { Text(opt.label) })
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Classics only", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                Switch(checked = b, onCheckedChange = { b = it }, modifier = Modifier.testTag("kilter.filter.benchmarks"))
            }

            Text("Min ascents", style = MaterialTheme.typography.labelLarge)
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ascentChoices.forEach { n ->
                    FilterChip(selected = a == n, onClick = { a = n }, label = { Text(if (n == 0) "Any" else "$n+") })
                }
            }

            Text("Min quality", style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(0.0 to "Any", 1.0 to "★ 1+", 2.0 to "★ 2+", 3.0 to "★ 3").forEach { (v, lbl) ->
                    FilterChip(selected = q == v, onClick = { q = v }, label = { Text(lbl) })
                }
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { s = KilterSort.POPULAR; b = false; a = 0; q = 0.0 }) { Text("Reset") }
                Button(onClick = { onChange(s, b, a, q); onDismiss() },
                    modifier = Modifier.weight(1f).testTag("kilter.filter.done")) { Text("Done") }
            }
        }
    }
}

@Composable
private fun FilterDropdown(
    label: String,
    value: String,
    options: List<Pair<Int, String>>,
    testTag: String,
    onSelect: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        AssistChip(
            onClick = { expanded = true },
            label = { Text("$label: $value") },
            modifier = Modifier.testTag(testTag),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (id, name) ->
                DropdownMenuItem(text = { Text(name) }, onClick = { onSelect(id); expanded = false })
            }
        }
    }
}

@Composable
private fun KilterClimbRow(
    item: KilterListItem,
    isFavorite: Boolean,
    gradeFormat: KilterGradeFormat = KilterGradeFormat.BOTH,
    featured: Boolean = false,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Row(
        (if (featured) modifier else modifier.testTag("kilter.climbRow"))
            .fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (featured) {
            Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = com.snappet.mobile.ui.theme.pulseWarning(),
                modifier = Modifier.padding(end = 8.dp).size(18.dp))
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(item.name, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                // Issue #97: the saved star reads in the Kilter module accent token (was raw 0xFFE8A800).
                if (isFavorite) Icon(Icons.Filled.Star, contentDescription = "Saved", tint = com.snappet.mobile.ui.theme.kilterAccent(), modifier = Modifier.padding(start = 2.dp))
            }
            Text("by ${item.setter}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        Column(horizontalAlignment = Alignment.End) {
            Box(
                Modifier.background(MaterialTheme.colorScheme.secondaryContainer, RoundedCornerShape(10.dp))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            ) { Text(kilterDisplayGrade(item.gradeLabel, gradeFormat), style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold) }
            Text("★".repeat(item.quality.toInt().coerceIn(0, 3)) + "  ▲ ${item.ascents}",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun EmptyState(padding: PaddingValues, title: String, message: String) {
    Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(message, style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp))
        }
    }
}
