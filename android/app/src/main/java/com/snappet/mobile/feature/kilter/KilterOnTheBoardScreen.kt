package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.kilterAccent
import com.snappet.mobile.ui.theme.pulseNeutral
import com.snappet.mobile.ui.theme.pulseSuccess
import com.snappet.mobile.ui.theme.pulseWarning
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * **On the Board** (Kilter Improvement, Wave C / P5): a history of every climb the user *lit on the board* —
 * including the ones pulled up and worked but never formally logged as an ascent. A hero "N climbs worked"
 * count, filter chips (status / angle / board), a timeline grouped by day/session with "N lit · M sent"
 * roll-ups, and one row per deduped lit climb — a mini board thumbnail + name + grade/angle/time + a status
 * chip (Lit / Attempt / Sent, joined from the ascent log) + a one-tap **re-light** that re-sends the holds.
 *
 * Mirrors the iOS `KilterOnTheBoardView`. **All dedup / day-session grouping / roll-ups / status-join / the
 * chip vocabulary come from the pure [KilterOnTheBoard] engine (Wave A)** — this screen is a dumb renderer
 * over its [KilterOnTheBoard.DisplayModel]. Reads `litEventsFlow()` + `logsFlow()` from the [KilterDao]
 * (the container-DAO pattern), maps Room rows into the engine's value types via [KilterLitEvent.asLitEvent],
 * and resolves a row's thumbnail + re-light holds from the shared [KilterCatalog] (each render memoized
 * internally by `layout#size`, so a re-render or a repeated climb doesn't re-hit SQLite).
 *
 * The re-light leg is **device-pending**: a board must be connected to actually light. With no board the tap
 * is a no-op that shows a snackbar nudge to connect — the engine's history is untouched.
 *
 * `onOpenClimb` opens the climb's detail; `onExit` returns to the catalog.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun KilterOnTheBoardScreen(onOpenClimb: (String) -> Unit, onExit: () -> Unit) {
    val context = LocalContext.current
    val dao = LocalAppContainer.current.database.kilterDao()
    // The board controller is created locally for the re-light path (the root owns the shared one; this
    // screen is reached via its own route and only ever *sends* a re-light, never opens a session).
    val board = remember { KilterBoardController(context) }
    val catalog = remember { KilterCatalog.get(context) }
    val gradeFormat = remember { KilterSettings.gradeFormat(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    val litEvents by dao.litEventsFlow().collectAsState(initial = emptyList())
    val logs by dao.logsFlow().collectAsState(initial = emptyList())

    // Active filter selections (at most one value per facet). Re-tapping a chip clears it.
    var selections by rememberSaveable(
        stateSaver = facetSelectionSaver,
    ) { mutableStateOf<Map<KilterOnTheBoard.Facet, String>>(emptyMap()) }

    // Map Room rows → the engine's plain value types, then build the whole grouped/filtered timeline.
    val model = remember(litEvents, logs, selections) {
        KilterOnTheBoard.build(
            events = litEvents.map { it.asLitEvent() },
            logs = logs.map { KilterOnTheBoard.LogRow(it.climbUuid, KilterAscentStatus.from(it.status)) },
            selections = selections,
            nowMillis = System.currentTimeMillis(),
            layoutName = { id -> catalog.layouts().firstOrNull { it.id == id }?.name },
        )
    }

    // One-tap re-light: re-resolve the climb's holds and send them to the board. A board must be connected
    // to actually light; with none, nudge the user to connect (history is untouched).
    fun relight(e: KilterOnTheBoard.LitEvent) {
        val climb = catalog.climb(e.climbUuid)
        if (climb != null && board.isConnected) {
            board.illuminate(catalog.holds(climb, e.sizeId))
        } else if (!board.isConnected) {
            scope.launch { snackbar.showSnackbar("Connect a board to re-light this climb.") }
        }
    }

    Box(Modifier.fillMaxSize()) {
        ModuleScaffold(title = "On the Board", onExit = onExit) { barPadding ->
            if (litEvents.isEmpty()) {
                Box(
                    Modifier.fillMaxSize().padding(barPadding).testTag("kilter.board.empty"),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 32.dp),
                    ) {
                        Text("Nothing lit yet", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Light a climb on the board and it shows up here — even the ones you work " +
                                "but never log.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp),
                        )
                    }
                }
                return@ModuleScaffold
            }

            LazyColumn(
                Modifier.fillMaxSize().padding(barPadding),
                contentPadding = PaddingValues(vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { Hero(model.climbsWorked) }
                item { ChipRail(model, selections) { facet, value -> selections = toggle(selections, facet, value) } }
                if (model.groups.isEmpty()) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                            Text(
                                "No lit climbs match the current filters.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                for (group in model.groups) {
                    item(key = "header.${group.id}") { GroupHeader(group) }
                    items(group.rows, key = { it.id }) { row ->
                        LitRow(
                            row = row,
                            catalog = catalog,
                            gradeFormat = gradeFormat,
                            onOpenClimb = { onOpenClimb(row.event.climbUuid) },
                            onReLight = { relight(row.event) },
                        )
                    }
                }
            }
        }
        SnackbarHost(snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }
}

/** The hero "N climbs worked" — the climber's whole body of work over the deduped set. */
@Composable
private fun Hero(climbsWorked: Int) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("kilter.board.hero"),
    ) {
        Text(
            "$climbsWorked",
            fontSize = 52.sp,
            fontWeight = FontWeight.Bold,
            color = kilterAccent(),
        )
        Text(
            "CLIMBS WORKED",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** The filter chip rail (status / angle / board). "All" clears; a re-tap of an active chip clears it. */
@Composable
private fun ChipRail(
    model: KilterOnTheBoard.DisplayModel,
    selections: Map<KilterOnTheBoard.Facet, String>,
    onToggle: (KilterOnTheBoard.Facet, String) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Chip(title = "All", selected = selections.isEmpty(), onClick = { onToggle(CLEAR_FACET, "") })
        for (facet in KilterOnTheBoard.Facet.entries) {
            for (value in model.facetValues[facet].orEmpty()) {
                Chip(title = value, selected = selections[facet] == value, onClick = { onToggle(facet, value) })
            }
        }
    }
}

@Composable
private fun Chip(title: String, selected: Boolean, onClick: () -> Unit) {
    val accent = kilterAccent()
    Box(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selected) accent else MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .testTag("kilter.board.chip")
            .padding(horizontal = 14.dp, vertical = 7.dp),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) Color.White else MaterialTheme.colorScheme.onSurface,
        )
    }
}

/** A day/session group header: its headline + the "N lit · M sent" roll-up summary. */
@Composable
private fun GroupHeader(group: KilterOnTheBoard.Group) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            group.headline,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.testTag("kilter.board.groupHeader"),
        )
        Box(Modifier.weight(1f))
        Text(
            group.summary,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** A single lit-climb row: mini board thumbnail + name + grade/angle/time + status chip + re-light. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LitRow(
    row: KilterOnTheBoard.Row,
    catalog: KilterCatalog,
    gradeFormat: KilterGradeFormat,
    onOpenClimb: () -> Unit,
    onReLight: () -> Unit,
) {
    val e = row.event
    var relit by remember(row.id) { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onOpenClimb, onLongClick = {})
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .testTag("kilter.board.row"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Thumbnail(e, catalog)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                e.climbName,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                metaLine(e, gradeFormat),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        StatusChip(row.status)
        IconButton(
            onClick = { relit = true; onReLight() },
            modifier = Modifier.testTag("kilter.board.relight"),
        ) {
            Icon(
                if (relit) Icons.Filled.Check else Icons.Filled.Refresh,
                contentDescription = "Re-light ${e.climbName}",
                tint = kilterAccent(),
            )
        }
    }
}

/**
 * A mini board render of the climb's holds, resolved from the shared [KilterCatalog] at the event's
 * layout/size (memoized internally by `layout#size`). A created climb (or one the local catalog lacks)
 * falls back to a neutral placeholder tile.
 */
@Composable
private fun Thumbnail(e: KilterOnTheBoard.LitEvent, catalog: KilterCatalog) {
    val climb = remember(e.climbUuid) { catalog.climb(e.climbUuid) }
    Box(Modifier.width(48.dp).height(56.dp)) {
        if (climb != null) {
            KilterBoard(
                geometry = catalog.boardGeometry(climb.layoutId, e.sizeId),
                holds = catalog.holds(climb, e.sizeId),
                modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp)),
            )
        } else {
            Box(
                Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.GridView,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

/** The joined-status chip (Sent = success + check, Attempt = warning, Lit = neutral). */
@Composable
private fun StatusChip(status: KilterOnTheBoard.Status) {
    val (tint, showCheck) = when (status) {
        KilterOnTheBoard.Status.SENT -> pulseSuccess() to true
        KilterOnTheBoard.Status.ATTEMPT -> pulseWarning() to false
        KilterOnTheBoard.Status.LIT -> pulseNeutral() to false
    }
    Row(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.16f))
            .padding(horizontal = 8.dp, vertical = 4.dp)
            .testTag("kilter.board.statusChip"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        if (showCheck) {
            Icon(Icons.Filled.Check, contentDescription = null, tint = tint, modifier = Modifier.size(12.dp))
        }
        Text(status.label, style = MaterialTheme.typography.labelSmall, color = tint, fontWeight = FontWeight.SemiBold)
    }
}

/** "V6 · 40° · 7:24 PM" — grade (per the user's format), angle, the light time. */
private fun metaLine(e: KilterOnTheBoard.LitEvent, gradeFormat: KilterGradeFormat): String {
    val grade = if (e.gradeLabel.isEmpty()) "" else kilterDisplayGrade(e.gradeLabel, gradeFormat)
    val time = timeFmt.format(Date(e.litAt))
    return listOf(grade, "${e.angle}°", time).filter { it.isNotEmpty() }.joinToString(" · ")
}

private val timeFmt = SimpleDateFormat("h:mm a", Locale.getDefault())

// ── Recent rail ────────────────────────────────────────────────────────────────────────────────────

/**
 * The reusable "Recently on the board" horizontal rail (Kilter root, Wave C). Renders the most-recent lit
 * climbs — fed from [KilterDao.recentLitEventsFlow] and the [KilterOnTheBoard.recent] engine ordering — as a
 * one-tap re-light rail. Each tile is a mini board thumbnail + name + grade/angle + status chip; a tap opens
 * the climb, the re-light button re-sends its holds.
 *
 * Defined here parameterized by data + callbacks so the integration step can place it on the root without
 * this file knowing the root's layout. Pass the engine [KilterOnTheBoard.Row]s (built from
 * `recentLitEventsFlow` + the status join) plus the [KilterCatalog] for thumbnails / re-light hold lookup.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun KilterRecentOnBoardRail(
    rows: List<KilterOnTheBoard.Row>,
    catalog: KilterCatalog,
    gradeFormat: KilterGradeFormat,
    onOpenClimb: (String) -> Unit,
    onReLight: (KilterOnTheBoard.Row) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (rows.isEmpty()) return
    Column(modifier.fillMaxWidth().testTag("kilter.board.recentRail")) {
        Text(
            "Recently on the board",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(rows, key = { it.id }) { row ->
                RecentTile(
                    row = row,
                    catalog = catalog,
                    gradeFormat = gradeFormat,
                    onOpenClimb = { onOpenClimb(row.event.climbUuid) },
                    onReLight = { onReLight(row) },
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RecentTile(
    row: KilterOnTheBoard.Row,
    catalog: KilterCatalog,
    gradeFormat: KilterGradeFormat,
    onOpenClimb: () -> Unit,
    onReLight: () -> Unit,
) {
    val e = row.event
    Column(
        Modifier
            .width(120.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .combinedClickable(onClick = onOpenClimb, onLongClick = {})
            .padding(8.dp)
            .testTag("kilter.board.recentTile"),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(Modifier.fillMaxWidth().height(72.dp)) {
            val climb = remember(e.climbUuid) { catalog.climb(e.climbUuid) }
            if (climb != null) {
                KilterBoard(
                    geometry = catalog.boardGeometry(climb.layoutId, e.sizeId),
                    holds = catalog.holds(climb, e.sizeId),
                    modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp)),
                )
            } else {
                Box(
                    Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surface),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.GridView, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
        Text(
            e.climbName,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                shortMeta(e, gradeFormat),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Box(
                Modifier
                    .clip(CircleShape)
                    .background(kilterAccent().copy(alpha = 0.16f))
                    .combinedClickable(onClick = onReLight, onLongClick = {})
                    .testTag("kilter.board.relight")
                    .padding(4.dp),
            ) {
                Icon(
                    Icons.Filled.Refresh,
                    contentDescription = "Re-light ${e.climbName}",
                    tint = kilterAccent(),
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

/** "V6 · 40°" — grade (per the user's format) + angle, for the compact recent tile. */
private fun shortMeta(e: KilterOnTheBoard.LitEvent, gradeFormat: KilterGradeFormat): String {
    val grade = if (e.gradeLabel.isEmpty()) "" else kilterDisplayGrade(e.gradeLabel, gradeFormat)
    return listOf(grade, "${e.angle}°").filter { it.isNotEmpty() }.joinToString(" · ")
}

// ── filter-selection helpers ─────────────────────────────────────────────────────────────────────────

/** Sentinel passed from the "All" chip to clear every selection. */
private val CLEAR_FACET = KilterOnTheBoard.Facet.STATUS

/**
 * Toggle a facet selection: "All" (sentinel + blank value) clears everything; re-tapping the active value
 * for a facet clears just that facet; otherwise the facet's value is set (at most one per facet).
 */
private fun toggle(
    current: Map<KilterOnTheBoard.Facet, String>,
    facet: KilterOnTheBoard.Facet,
    value: String,
): Map<KilterOnTheBoard.Facet, String> {
    if (value.isEmpty()) return emptyMap()   // the "All" chip
    val next = current.toMutableMap()
    if (next[facet] == value) next.remove(facet) else next[facet] = value
    return next
}

/** Saver so the chip selections survive process death (the map's keys are an enum). */
private val facetSelectionSaver = androidx.compose.runtime.saveable.listSaver<Map<KilterOnTheBoard.Facet, String>, String>(
    save = { it.entries.flatMap { (k, v) -> listOf(k.name, v) } },
    restore = { flat ->
        flat.chunked(2).mapNotNull { pair ->
            if (pair.size == 2) KilterOnTheBoard.Facet.entries.firstOrNull { it.name == pair[0] }?.let { it to pair[1] }
            else null
        }.toMap()
    },
)
