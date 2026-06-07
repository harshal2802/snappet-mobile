package com.snappet.mobile.feature.kilter

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
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayCircle
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private enum class KilterScreen { ROOT, DETAIL, HISTORY, SETTINGS }

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
    val sessions = remember { KilterSessionManager(dao) }
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

    var screen by remember { mutableStateOf(KilterScreen.ROOT) }
    var selectedUuid by remember { mutableStateOf<String?>(null) }

    when (screen) {
        KilterScreen.HISTORY -> KilterHistoryScreen(dao = dao, onExit = { screen = KilterScreen.ROOT })
        KilterScreen.SETTINGS -> KilterSettingsScreen(
            catalog = cat, dao = dao,
            onCatalogChanged = { reloadToken++; screen = KilterScreen.ROOT },
            onExit = { screen = KilterScreen.ROOT })
        KilterScreen.DETAIL -> selectedUuid?.let { uuid ->
            KilterDetailScreen(
                uuid = uuid, catalog = cat, board = board, sessions = sessions,
                onExit = { screen = KilterScreen.ROOT },
            )
        }
        KilterScreen.ROOT -> KilterCatalogScreen(
            catalog = cat,
            dao = dao,
            sessions = sessions,
            onOpenClimb = { selectedUuid = it; screen = KilterScreen.DETAIL },
            onOpenHistory = { screen = KilterScreen.HISTORY },
            onOpenSettings = { screen = KilterScreen.SETTINGS },
            onExit = onExit,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KilterCatalogScreen(
    catalog: KilterCatalog,
    dao: KilterDao,
    sessions: KilterSessionManager,
    onOpenClimb: (String) -> Unit,
    onOpenHistory: () -> Unit,
    onOpenSettings: () -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val favorites by dao.favoritesFlow().collectAsState(initial = emptyList())
    val logs by dao.logsFlow().collectAsState(initial = emptyList())
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
    var savedOnly by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var sort by remember { mutableStateOf(KilterSort.POPULAR) }
    var benchmarksOnly by remember { mutableStateOf(false) }
    var minAscents by remember { mutableStateOf(0) }
    var minQuality by remember { mutableStateOf(0.0) }
    var showFilters by remember { mutableStateOf(false) }
    var moreMenu by remember { mutableStateOf(false) }
    var climbs by remember { mutableStateOf<List<KilterListItem>>(emptyList()) }
    var cotd by remember { mutableStateOf<KilterListItem?>(null) }

    val showDiscovery = search.isBlank() && !savedOnly
    val filter = KilterFilter(layoutId, angle, minGrade.toDouble(), maxGrade.toDouble(),
        search, sort, benchmarksOnly, minAscents, minQuality)

    androidx.compose.runtime.LaunchedEffect(filter, savedOnly, favorites) {
        val result = withContext(Dispatchers.IO) {
            if (!catalog.isAvailable) emptyList<KilterListItem>() to null
            else if (savedOnly) {
                val all = catalog.climbsByUuid(favorites.map { it.climbUuid })
                val term = search.trim().lowercase()
                val filtered = if (term.isEmpty()) all
                    else all.filter { it.name.lowercase().contains(term) || it.setter.lowercase().contains(term) }
                filtered to null
            } else {
                catalog.list(filter) to (if (showDiscovery) catalog.climbOfTheDay(layoutId, angle) else null)
            }
        }
        climbs = result.first; cotd = result.second
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
                    DropdownMenuItem(text = { Text("Surprise me") },
                        leadingIcon = { Icon(Icons.Filled.Casino, null) },
                        modifier = Modifier.testTag("kilter.surprise"),
                        onClick = {
                            moreMenu = false
                            scope.launch {
                                val pick = withContext(Dispatchers.IO) { catalog.randomClimb(filter) }
                                pick?.let { onOpenClimb(it.uuid) }
                            }
                        })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("Settings") },
                        leadingIcon = { Icon(Icons.Filled.Settings, null) },
                        onClick = { moreMenu = false; onOpenSettings() })
                }
            }
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
                    onClick = { savedOnly = !savedOnly },
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

            sessions.currentSessionId?.let { sid ->
                val count = logs.count { it.sessionId == sid }
                Row(
                    Modifier.fillMaxWidth().background(Color(0xFF30A46C).copy(alpha = 0.12f))
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Filled.FiberManualRecord, contentDescription = null, tint = Color(0xFF30A46C), modifier = Modifier.size(10.dp))
                    Text("Session · $count climb${if (count == 1) "" else "s"}",
                        style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                    androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                    TextButton(onClick = { scope.launch { sessions.end() } }, modifier = Modifier.testTag("kilter.session.end")) {
                        Text("End")
                    }
                }
            }

            if (climbs.isEmpty() && cotd == null) {
                EmptyState(PaddingValues(0.dp),
                    if (search.isNotBlank()) "No matches" else if (savedOnly) "No saved climbs" else "No climbs match",
                    if (search.isNotBlank()) "No climbs match “$search” with the current filters."
                    else if (savedOnly) "Star climbs to find them here." else "Try a wider grade range or fewer filters.")
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    cotd?.let { c ->
                        item(key = "cotd") {
                            Text("CLIMB OF THE DAY", style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(start = 16.dp, top = 8.dp))
                            KilterClimbRow(c, favoriteUuids.contains(c.uuid), gradeFormat, featured = true,
                                modifier = Modifier.testTag("kilter.cotd")) { onOpenClimb(c.uuid) }
                            HorizontalDivider()
                        }
                    }
                    items(climbs, key = { it.uuid }) { item ->
                        KilterClimbRow(item, favoriteUuids.contains(item.uuid), gradeFormat) { onOpenClimb(item.uuid) }
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
            Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = Color(0xFFD97706),
                modifier = Modifier.padding(end = 8.dp).size(18.dp))
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(item.name, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                if (isFavorite) Icon(Icons.Filled.Star, contentDescription = "Saved", tint = Color(0xFFE8A800), modifier = Modifier.padding(start = 2.dp))
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
