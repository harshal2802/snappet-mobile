package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
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
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.kilterAccent
import com.snappet.mobile.ui.theme.pulseNeutral
import com.snappet.mobile.ui.theme.pulseSuccess
import com.snappet.mobile.ui.theme.pulseWarning
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * **Your Climbs** (Kilter Improvement Wave C, P2): the first-class gallery of the climbs you authored —
 * promoting the buried, layout-scoped, text-only "Mine" filter into a board-thumbnail grid that is
 * **global across layouts** (a climb you set on another board still shows). The lit-holds render *is* the
 * climb's identity, so the grid leads with thumbnails. Mirrors the iOS `KilterCreatedView`.
 *
 * Header = a "N climbs set" hero + a coral "Set a climb" CTA. A Saved/Drafts/All status segment, filter +
 * sort chips (status segment · layout · angle · source; Recently-set [default] / Grade / Most-climbed).
 * Per card: the mini board, a grade badge, provenance (Hand-set / Generated), angle, and the user's OWN
 * logbook status (Sent / Project / Attempt / Untried — never community signals). Per-card overflow
 * actions (Edit / Duplicate / Share / Delete). Delete keeps logged ascents. Tap → [onOpenClimb].
 *
 * ALL query/sort/filter/own-status logic lives in the pure [KilterCreatedGallery]; this screen feeds it
 * device-free snapshots of its DB rows and renders the ordered items — a thin renderer, no aggregation.
 *
 * @param onOpenClimb open the existing climb detail for a uuid (the normal render / logging / BLE path).
 * @param onCreate start authoring a new climb (the hero CTA + the empty state). Edit/Duplicate also route
 *   here, since the author screen owns that flow.
 * @param onExit return to the catalog (the [ModuleScaffold] back arrow).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KilterCreatedGalleryScreen(
    onOpenClimb: (String) -> Unit,
    onCreate: () -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val dao = container.database.kilterDao()
    val scope = rememberCoroutineScope()

    // The app ships no catalog (issue #42); the user-installed reader is needed to render thumbnails.
    // Open it off the main thread, mirroring KilterRoot. Null while loading or when no catalog is present
    // (the gallery still works without it — thumbnails fall back to a placeholder tile).
    val catalog by produceState<KilterCatalog?>(initialValue = null) {
        value = withContext(Dispatchers.IO) { KilterCatalog.get(context) }
    }

    val created by dao.createdFlow().collectAsState(initial = emptyList())
    val logs by dao.logsFlow().collectAsState(initial = emptyList())

    // UI filter / sort / segment state. Facets are nullable — null = "any" (the global default).
    var segment by rememberSaveable { mutableStateOf(KilterCreatedGallery.Segment.ALL) }
    var sort by rememberSaveable { mutableStateOf(KilterCreatedGallery.Sort.RECENT) }
    var layoutFacet by rememberSaveable { mutableStateOf<Int?>(null) }
    var angleFacet by rememberSaveable { mutableStateOf<Int?>(null) }
    var sourceFacet by rememberSaveable { mutableStateOf<String?>(null) }

    // Open dropdown / dialog / sheet state.
    var sortMenu by remember { mutableStateOf(false) }
    var layoutMenu by remember { mutableStateOf(false) }
    var angleMenu by remember { mutableStateOf(false) }
    var sourceMenu by remember { mutableStateOf(false) }
    var sharingUuid by remember { mutableStateOf<String?>(null) }
    var deletingUuid by remember { mutableStateOf<String?>(null) }

    // Device-free engine snapshots. Draft = a climb whose holds fail the save floor (`kilterValidate`) —
    // NO schema field, derived from the stored `frames` (the same floor the author screen enforces). The
    // O(holds) parse is memoized per (uuid, frames) so it isn't re-run on every recomposition.
    val createdRows = remember(created) {
        created.map { c ->
            KilterCreatedGallery.CreatedRow(
                uuid = c.uuid, name = c.name, setterUsername = c.setterUsername,
                layoutId = c.layoutId, angle = c.angle, predictedGrade = c.predictedGrade,
                source = c.source, isValid = isSavableFrames(c.frames), createdAt = c.createdAt,
            )
        }
    }
    val logRows = remember(logs) {
        logs.map { KilterCreatedGallery.LogRow(climbUuid = it.climbUuid, status = KilterAscentStatus.from(it.status)) }
    }

    val items = remember(createdRows, logRows, segment, sort, layoutFacet, angleFacet, sourceFacet) {
        KilterCreatedGallery.items(
            created = createdRows, logs = logRows, segment = segment, sort = sort,
            layoutId = layoutFacet, angle = angleFacet, source = sourceFacet,
        )
    }
    // The angle facet options — the DISTINCT angles in the user's climbs (NOT the catalog), so an
    // off-catalog angle stays reachable. Pure.
    val availableAngles = remember(createdRows) { KilterCreatedGallery.angleFacets(createdRows) }
    val layouts = remember(catalog) { catalog?.layouts() ?: emptyList() }

    // The delete confirmation reads a value snapshot (name + ascent count), captured BEFORE the row
    // leaves the store, so the keep-ascents guarantee is visible and the dialog never dereferences a gone row.
    val deletingClimb = remember(deletingUuid, created) { created.firstOrNull { it.uuid == deletingUuid } }
    val deletingAscentCount by produceState(initialValue = 0, deletingUuid) {
        value = deletingUuid?.let { withContext(Dispatchers.IO) { dao.ascentCountForClimb(it) } } ?: 0
    }

    deletingClimb?.let { climb ->
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete this climb?",
            message = if (deletingAscentCount == 0)
                "“${climb.name}” will be removed. It can't be undone."
            else
                "“${climb.name}” will be removed — but your $deletingAscentCount logged " +
                    "ascent${if (deletingAscentCount == 1) "" else "s"} stay in History.",
            confirmLabel = "Delete climb",
            onConfirm = {
                val uuid = climb.uuid
                val name = climb.name
                deletingUuid = null
                scope.launch {
                    // Canonical delete — removes only the created row, never the logged ascents (keep-ascents).
                    dao.deleteCreated(uuid)
                    container.core.log("kilter", "deleted", "Deleted $name")
                }
            },
            onDismiss = { deletingUuid = null },
        )
    }

    sharingUuid?.let { uuid ->
        created.firstOrNull { it.uuid == uuid }?.let { climb ->
            com.snappet.mobile.feature.kilter.share.KilterShareSheet(
                uuid = climb.uuid, angle = climb.angle, frames = climb.frames,
                onDismiss = { sharingUuid = null },
            )
        }
    }

    ModuleScaffold(title = "Your Climbs", onExit = onExit) { padding ->
        if (created.isEmpty()) {
            EmptyCreatedState(onCreate = onCreate, modifier = Modifier.fillMaxSize().padding(padding))
            return@ModuleScaffold
        }

        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // The header (hero + CTA + segment + facet chips) spans both columns above the grid.
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    GalleryHeader(
                        count = created.size,
                        onCreate = onCreate,
                    )
                    SegmentRow(segment = segment, onSelect = { segment = it })
                    FacetChips(
                        sort = sort, sortMenu = sortMenu, onSortMenu = { sortMenu = it },
                        onSort = { sort = it; sortMenu = false },
                        layouts = layouts, layoutFacet = layoutFacet, layoutMenu = layoutMenu,
                        onLayoutMenu = { layoutMenu = it }, onLayout = { layoutFacet = it; layoutMenu = false },
                        angles = availableAngles, angleFacet = angleFacet, angleMenu = angleMenu,
                        onAngleMenu = { angleMenu = it }, onAngle = { angleFacet = it; angleMenu = false },
                        sourceFacet = sourceFacet, sourceMenu = sourceMenu,
                        onSourceMenu = { sourceMenu = it }, onSource = { sourceFacet = it; sourceMenu = false },
                    )
                }
            }

            if (items.isEmpty()) {
                item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                    Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Nothing here", style = MaterialTheme.typography.titleMedium)
                            Text(
                                "No climbs in this view — try another status or clear the filters.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 4.dp, start = 24.dp, end = 24.dp),
                            )
                        }
                    }
                }
            } else {
                items(items, key = { it.uuid }) { item ->
                    CreatedCard(
                        item = item,
                        catalog = catalog,
                        framesFor = { uuid -> created.firstOrNull { it.uuid == uuid } },
                        onOpen = { onOpenClimb(item.uuid) },
                        onEdit = onCreate,
                        onDuplicate = onCreate,
                        onShare = { sharingUuid = item.uuid },
                        onDelete = { deletingUuid = item.uuid },
                    )
                }
            }
        }
    }
}

/** The hero: a big "N climbs set" headline + the coral "Set a climb" primary action. */
@Composable
private fun GalleryHeader(count: Int, onCreate: () -> Unit) {
    val accent = kilterAccent()
    Row(
        Modifier.fillMaxWidth().testTag("kilter.yourClimbs.hero"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column {
            Text(
                "$count",
                style = MaterialTheme.typography.displaySmall,
                fontWeight = FontWeight.Bold,
                color = accent,
            )
            Text(
                if (count == 1) "CLIMB SET" else "CLIMBS SET",
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Button(
            onClick = onCreate,
            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            modifier = Modifier.testTag("kilter.yourClimbs.setClimb"),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.width(18.dp))
            Text("  Set a climb")
        }
    }
}

/** The Saved / Drafts / All status segment. */
@Composable
private fun SegmentRow(
    segment: KilterCreatedGallery.Segment,
    onSelect: (KilterCreatedGallery.Segment) -> Unit,
) {
    // Stable visual order Saved · Drafts · All (mirrors the iOS picker), not the enum's declaration order.
    val order = listOf(
        KilterCreatedGallery.Segment.SAVED,
        KilterCreatedGallery.Segment.DRAFTS,
        KilterCreatedGallery.Segment.ALL,
    )
    Row(
        Modifier.fillMaxWidth().testTag("kilter.yourClimbs.segment"),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        order.forEach { seg ->
            FilterChip(
                selected = segment == seg,
                onClick = { onSelect(seg) },
                label = { Text(seg.label) },
                modifier = Modifier.weight(1f).testTag("kilter.yourClimbs.segment.${seg.name}"),
            )
        }
    }
}

/** Sort + layout + angle + source filter chips (each `null` facet reads "All" / "Any"). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FacetChips(
    sort: KilterCreatedGallery.Sort, sortMenu: Boolean, onSortMenu: (Boolean) -> Unit,
    onSort: (KilterCreatedGallery.Sort) -> Unit,
    layouts: List<KilterLayout>, layoutFacet: Int?, layoutMenu: Boolean,
    onLayoutMenu: (Boolean) -> Unit, onLayout: (Int?) -> Unit,
    angles: List<Int>, angleFacet: Int?, angleMenu: Boolean,
    onAngleMenu: (Boolean) -> Unit, onAngle: (Int?) -> Unit,
    sourceFacet: String?, sourceMenu: Boolean,
    onSourceMenu: (Boolean) -> Unit, onSource: (String?) -> Unit,
) {
    androidx.compose.foundation.lazy.LazyRow(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Box {
                FilterChip(
                    selected = false, onClick = { onSortMenu(true) },
                    label = { Text(sort.label) },
                    modifier = Modifier.testTag("kilter.yourClimbs.sort"),
                )
                DropdownMenu(expanded = sortMenu, onDismissRequest = { onSortMenu(false) }) {
                    KilterCreatedGallery.Sort.entries.forEach { s ->
                        DropdownMenuItem(text = { Text(s.label) }, onClick = { onSort(s) })
                    }
                }
            }
        }
        item {
            Box {
                val label = layoutFacet?.let { id -> layouts.firstOrNull { it.id == id }?.name } ?: "All boards"
                FilterChip(
                    selected = layoutFacet != null, onClick = { onLayoutMenu(true) },
                    label = { Text(label) },
                    modifier = Modifier.testTag("kilter.yourClimbs.layoutFacet"),
                )
                DropdownMenu(expanded = layoutMenu, onDismissRequest = { onLayoutMenu(false) }) {
                    DropdownMenuItem(text = { Text("All boards") }, onClick = { onLayout(null) })
                    layouts.forEach { l ->
                        DropdownMenuItem(text = { Text(l.name) }, onClick = { onLayout(l.id) })
                    }
                }
            }
        }
        item {
            Box {
                FilterChip(
                    selected = angleFacet != null, onClick = { onAngleMenu(true) },
                    label = { Text(angleFacet?.let { "$it°" } ?: "Angle") },
                    modifier = Modifier.testTag("kilter.yourClimbs.angleFacet"),
                )
                DropdownMenu(expanded = angleMenu, onDismissRequest = { onAngleMenu(false) }) {
                    DropdownMenuItem(text = { Text("All angles") }, onClick = { onAngle(null) })
                    angles.forEach { a ->
                        DropdownMenuItem(text = { Text("$a°") }, onClick = { onAngle(a) })
                    }
                }
            }
        }
        item {
            Box {
                val label = when (sourceFacet) {
                    "generated" -> "Generated"; "manual" -> "Hand-set"; else -> "Source"
                }
                FilterChip(
                    selected = sourceFacet != null, onClick = { onSourceMenu(true) },
                    label = { Text(label) },
                    modifier = Modifier.testTag("kilter.yourClimbs.sourceFacet"),
                )
                DropdownMenu(expanded = sourceMenu, onDismissRequest = { onSourceMenu(false) }) {
                    DropdownMenuItem(text = { Text("Any source") }, onClick = { onSource(null) })
                    DropdownMenuItem(text = { Text("Hand-set") }, onClick = { onSource("manual") })
                    DropdownMenuItem(text = { Text("Generated") }, onClick = { onSource("generated") })
                }
            }
        }
    }
}

/**
 * A grid card: the board thumbnail (the lit-holds render that *is* the climb) with a grade badge, then
 * the name, provenance · angle, and the user's OWN logbook status. Tap → open; overflow → Edit / Duplicate
 * / Share / Delete.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CreatedCard(
    item: KilterCreatedGallery.Item,
    catalog: KilterCatalog?,
    framesFor: (String) -> KilterCreatedClimb?,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
    onDuplicate: () -> Unit,
    onShare: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val accent = kilterAccent()
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .clickable { onOpen() }
            .padding(10.dp)
            .testTag("kilter.yourClimbs.card"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Thumbnail with the grade badge overlaid top-trailing.
        Box(Modifier.fillMaxWidth()) {
            CardThumbnail(uuid = item.uuid, catalog = catalog, framesFor = framesFor)
            // Grade badge.
            Box(
                Modifier.align(Alignment.TopEnd).padding(6.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(accent.copy(alpha = 0.18f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            ) {
                Text(
                    item.predictedGrade?.let { catalog?.gradeLabel(it) ?: "—" } ?: "—",
                    style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = accent,
                )
            }
            // DRAFT pill, top-leading.
            if (item.isDraft) {
                Box(
                    Modifier.align(Alignment.TopStart).padding(6.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                ) {
                    Text("DRAFT", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(item.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                maxLines = 1, modifier = Modifier.weight(1f))
            Box {
                IconButton(onClick = { menu = true }, modifier = Modifier
                    .width(32.dp).testTag("kilter.yourClimbs.cardMenu")) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "Climb actions")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Edit") },
                        modifier = Modifier.testTag("kilter.yourClimbs.edit"),
                        onClick = { menu = false; onEdit() })
                    DropdownMenuItem(text = { Text("Duplicate") },
                        modifier = Modifier.testTag("kilter.yourClimbs.duplicate"),
                        onClick = { menu = false; onDuplicate() })
                    DropdownMenuItem(text = { Text("Share") },
                        modifier = Modifier.testTag("kilter.yourClimbs.share"),
                        onClick = { menu = false; onShare() })
                    DropdownMenuItem(
                        text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                        modifier = Modifier.testTag("kilter.yourClimbs.delete"),
                        onClick = { menu = false; onDelete() },
                    )
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(item.provenance.label, style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Text("· ${item.angle}°", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            OwnStatusChip(status = item.ownStatus, count = item.logCount)
        }
    }
}

/**
 * The cached board thumbnail for a created climb (the lit-holds render). Resolves the created row →
 * [KilterCreatedClimb.asClimb] → catalog holds + geometry off the main thread, keyed by uuid so the grid
 * doesn't re-hit SQLite on every scroll frame. Falls back to a muted placeholder tile when the catalog
 * is absent or the climb can't be resolved.
 */
@Composable
private fun CardThumbnail(
    uuid: String,
    catalog: KilterCatalog?,
    framesFor: (String) -> KilterCreatedClimb?,
) {
    val render by produceState<Pair<KilterBoardGeometry, List<KilterHold>>?>(
        initialValue = null, uuid, catalog,
    ) {
        val cat = catalog
        val climb = framesFor(uuid)
        value = if (cat != null && climb != null) {
            withContext(Dispatchers.IO) {
                val c = climb.asClimb()
                val size = if (cat.sizes(c.layoutId).any { it.id == climb.sizeId }) climb.sizeId
                else cat.defaultSizeId(c.layoutId)
                cat.boardGeometry(c.layoutId, size) to cat.holds(c, size)
            }
        } else null
    }
    val r = render
    if (r != null && r.second.isNotEmpty()) {
        KilterBoard(geometry = r.first, holds = r.second, modifier = Modifier.fillMaxWidth())
    } else {
        // Placeholder while loading / when unresolved — keep the card height stable.
        Box(
            Modifier.fillMaxWidth().aspectRatio(0.62f)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
        )
    }
}

/** The user's OWN status chip — glyph-free label + count in the perf-ramp colours (Sent shows ×count). */
@Composable
private fun OwnStatusChip(status: KilterCreatedGallery.OwnStatus, count: Int) {
    val tint: Color = when (status) {
        KilterCreatedGallery.OwnStatus.SENT -> pulseSuccess()
        KilterCreatedGallery.OwnStatus.PROJECT -> pulseWarning()
        KilterCreatedGallery.OwnStatus.ATTEMPT -> pulseNeutral()
        KilterCreatedGallery.OwnStatus.UNTRIED -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val text = if (status == KilterCreatedGallery.OwnStatus.SENT && count > 1) "${status.label} ×$count"
    else status.label
    Box(
        Modifier.clip(RoundedCornerShape(8.dp)).background(tint.copy(alpha = 0.15f))
            .padding(horizontal = 7.dp, vertical = 2.dp)
            .testTag("kilter.yourClimbs.ownStatus"),
    ) {
        Text(text, style = MaterialTheme.typography.labelSmall, color = tint, fontWeight = FontWeight.SemiBold)
    }
}

/** Empty state — no climbs authored yet; the one action is "Set a climb". */
@Composable
private fun EmptyCreatedState(onCreate: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.testTag("kilter.yourClimbs.empty"),
        ) {
            Text("No climbs yet", style = MaterialTheme.typography.titleMedium)
            Text(
                "Set your first climb — design it hold by hold, or generate one on-device.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 32.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            Spacer(Modifier.height(4.dp))
            Button(
                onClick = onCreate,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
                modifier = Modifier.testTag("kilter.yourClimbs.setClimb"),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.width(18.dp))
                Text("  Set a climb")
            }
        }
    }
}

/**
 * Re-derive the Draft state from a climb's holds: a climb that would fail the save floor ([kilterValidate])
 * is incomplete → a Draft. Keeps "Draft" a *derived* facet (the same rule the author screen enforces),
 * never a schema column — mirroring the iOS `KilterCreatedView.isSavable`. Pure.
 */
internal fun isSavableFrames(frames: String): Boolean =
    kilterValidate(parseFramesToAssignments(frames)) == null
