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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import kotlinx.coroutines.withContext

private enum class KilterScreen { ROOT, DETAIL, HISTORY }

/**
 * Root entry for the Kilter Board mini-app. Browse the bundled read-only catalog (filtered by
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

    // Opening the catalog copies a ~5 MB asset out of the APK on first launch — do it off the main
    // thread, showing a brief loading state, so the suite never janks/ANRs entering the module.
    var catalog by remember { mutableStateOf<KilterCatalog?>(null) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        catalog = withContext(Dispatchers.IO) { KilterCatalog.get(context) }
    }
    val cat = catalog
    if (cat == null) {
        ModuleScaffold(title = "Kilter Board", onExit = onExit) { padding ->
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                androidx.compose.material3.CircularProgressIndicator()
            }
        }
        return
    }

    var screen by remember { mutableStateOf(KilterScreen.ROOT) }
    var selectedUuid by remember { mutableStateOf<String?>(null) }

    when (screen) {
        KilterScreen.HISTORY -> KilterHistoryScreen(dao = dao, onExit = { screen = KilterScreen.ROOT })
        KilterScreen.DETAIL -> selectedUuid?.let { uuid ->
            KilterDetailScreen(
                uuid = uuid, catalog = cat, board = board, sessions = sessions,
                onExit = { screen = KilterScreen.ROOT },
            )
        }
        KilterScreen.ROOT -> KilterCatalogScreen(
            catalog = cat,
            dao = dao,
            onOpenClimb = { selectedUuid = it; screen = KilterScreen.DETAIL },
            onOpenHistory = { screen = KilterScreen.HISTORY },
            onExit = onExit,
        )
    }
}

@Composable
private fun KilterCatalogScreen(
    catalog: KilterCatalog,
    dao: KilterDao,
    onOpenClimb: (String) -> Unit,
    onOpenHistory: () -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val favorites by dao.favoritesFlow().collectAsState(initial = emptyList())
    val favoriteUuids = remember(favorites) { favorites.map { it.climbUuid }.toSet() }

    val layouts = remember { catalog.layouts() }
    val angles = remember { catalog.angles() }
    val gradeScale = remember { catalog.gradeScale() }

    var layoutId by remember { mutableStateOf(KilterSettings.layout(context)) }
    var angle by remember { mutableStateOf(KilterSettings.angle(context)) }
    var minGrade by remember { mutableStateOf(KilterSettings.minGrade(context)) }
    var maxGrade by remember { mutableStateOf(KilterSettings.maxGrade(context)) }
    var savedOnly by remember { mutableStateOf(false) }
    var climbs by remember { mutableStateOf<List<KilterListItem>>(emptyList()) }

    androidx.compose.runtime.LaunchedEffect(layoutId, angle, minGrade, maxGrade, savedOnly, favorites) {
        climbs = withContext(Dispatchers.IO) {
            if (!catalog.isAvailable) emptyList()
            else if (savedOnly) catalog.climbsByUuid(favorites.map { it.climbUuid })
            else catalog.list(layoutId, angle,
                minOf(minGrade, maxGrade).toDouble(), maxOf(minGrade, maxGrade).toDouble())
        }
    }

    ModuleScaffold(
        title = "Kilter Board",
        onExit = onExit,
        actions = {
            IconButton(onClick = onOpenHistory, modifier = Modifier.testTag("kilter.history")) {
                Icon(Icons.Filled.History, contentDescription = "History")
            }
        },
    ) { padding ->
        if (!catalog.isAvailable) {
            EmptyState(padding, "Catalog unavailable", "The bundled Kilter catalog couldn't be opened.")
            return@ModuleScaffold
        }
        Column(Modifier.fillMaxSize().padding(padding)) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilterDropdown("Layout", layouts.firstOrNull { it.id == layoutId }?.name ?: "—",
                    layouts.map { it.id to it.name }, "kilter.layout") { layoutId = it; KilterSettings.setLayout(context, it) }
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

            if (climbs.isEmpty()) {
                EmptyState(PaddingValues(0.dp),
                    if (savedOnly) "No saved climbs" else "No climbs match",
                    if (savedOnly) "Star climbs to find them here." else "Try a wider grade range or another angle.")
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(climbs, key = { it.uuid }) { item ->
                        KilterClimbRow(item, favoriteUuids.contains(item.uuid)) { onOpenClimb(item.uuid) }
                    }
                }
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
private fun KilterClimbRow(item: KilterListItem, isFavorite: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).testTag("kilter.climbRow").padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
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
            ) { Text(item.gradeLabel, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold) }
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
