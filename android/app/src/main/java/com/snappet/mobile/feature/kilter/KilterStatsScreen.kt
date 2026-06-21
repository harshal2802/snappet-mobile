package com.snappet.mobile.feature.kilter

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.snappet.mobile.feature.kilter.KilterSessionStats.GradeCount
import com.snappet.mobile.feature.kilter.KilterSessionStats.SessionLog
import com.snappet.mobile.ui.ChartAccessibility
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.kilterAccent
import com.snappet.mobile.ui.theme.pulseSuccess
import com.snappet.mobile.ui.theme.pulseWarning
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/**
 * The Kilter **climbing analytics dashboard** (Kilter Improvement P3) — a tiered Pulse Pro screen
 * rendered entirely on the pure, tested [KilterAllTimeStats] aggregate (Wave A). The screen does **no**
 * math: it reads logs + sessions from the DAO, builds the aggregate once, and draws it.
 *
 * Tiers, top to bottom:
 *  1. the **Climbing Level** hero (one big numeral) + a perf-ramp delta vs 90 days ago, then a 3-stat
 *     ribbon (Sent / Flash rate / This week);
 *  2. the signature **segmented grade pyramid** — flash vs redpoint-send segments per grade bar drawn
 *     with a Compose [Canvas], a send-count label, and a dashed current-max marker. Colorblind-safe:
 *     the segments use the Okabe-Ito palette AND a spelled-out legend (never hue alone). Tapping a grade
 *     filters an in-screen ascent log;
 *  3. send / flash **ring gauges** (Canvas arcs), a **sends-per-week** bar trend, **max-grade
 *     progression**, the **angle distribution**, and a kindly **consistency** strip.
 *
 * Colour discipline: ONE hero numeral; amber ([kilterAccent]) is wayfinding (module accent, trend
 * bars, current-max marker); the perf ramp ([pulseSuccess]/[pulseWarning]) carries effort/state
 * (the level delta, the send ring). Tiles are doorways — inline sections for v1; [onOpenTrend] is an
 * optional hook a host can wire to push a full trend screen later.
 *
 * **Kilter-board data only.** [onExit] returns to the catalog. Mirrors the iOS `KilterStatsView`.
 */
@Composable
fun KilterStatsScreen(
    onExit: () -> Unit,
    onOpenTrend: (KilterTrendKind) -> Unit = {},
) {
    val container = LocalAppContainer.current
    val dao = remember(container) { container.database.kilterDao() }
    val entries by dao.logsFlow().collectAsState(initial = emptyList())
    val allSessions by dao.sessionsFlow().collectAsState(initial = emptyList())

    // The grade the user tapped in the pyramid — filters the in-page ascent log. null = no filter.
    var gradeFilter by rememberSaveable { mutableStateOf<String?>(null) }

    // Build the all-time aggregate from the pure Wave A engine. Memoized on the cheap input signature
    // (counts + newest row) so a grade-filter tap doesn't re-walk the whole log every recomposition.
    val signature = Triple(entries.size, allSessions.size, entries.firstOrNull()?.let { it.id to it.status })
    val stats = remember(signature) {
        KilterAllTimeStats.make(
            logs = entries.map { it.asSessionLog() },
            sessions = allSessions.map { KilterAllTimeStats.SessionSummary.from(it) },
            nowMillis = System.currentTimeMillis(),
        )
    }

    ModuleScaffold(title = "Stats", onExit = onExit) { padding ->
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding).testTag("kilter.stats.empty"), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No stats yet", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Log climbs on the board and your analytics build here.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp),
                    )
                }
            }
            return@ModuleScaffold
        }

        LazyColumn(
            Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Tier 1 — hero + perf-ramp delta.
            item { HeroTier(stats) }

            // Tier 1 — stat ribbon (≤3: Sent / Flash rate / This week).
            item { StatRibbon(stats) }

            // Tier 2 — the signature segmented grade pyramid (tap a grade → filter the log below).
            if (stats.pyramid.isNotEmpty()) {
                item {
                    PyramidCard(
                        stats = stats,
                        selectedGrade = gradeFilter,
                        onSelectGrade = { label -> gradeFilter = if (gradeFilter == label) null else label },
                    )
                }
            }

            // Tier 2 — the in-screen filtered ascent log (the tap-a-grade target).
            gradeFilter?.let { grade ->
                item {
                    // `remember` must run inside the composable `item {}` scope, not in LazyListScope.
                    val filtered = remember(entries, grade) {
                        entries.filter { KilterAscentStatus.from(it.status).isSend && it.gradeLabel == grade }
                    }
                    AscentLogSection(grade = grade, sends = filtered, onClear = { gradeFilter = null })
                }
            }

            // Tier 2 — send / flash ring gauges.
            if (stats.pyramid.isNotEmpty()) {
                item { RingsRow(stats) }
            }

            // Tier 2 — sends-per-week volume trend (a doorway tile; inline for v1).
            if (stats.sendsPerWeek.isNotEmpty()) {
                item { VolumeTile(stats, onClick = { onOpenTrend(KilterTrendKind.VOLUME) }) }
            }

            // Tier 2 — max-grade progression.
            if (stats.maxGradeProgression.size >= 2) {
                item { ProgressionTile(stats, onClick = { onOpenTrend(KilterTrendKind.PROGRESSION) }) }
            }

            // Tier 2 — sends by angle.
            if (stats.angleDistribution.isNotEmpty()) {
                item { AngleTile(stats, onClick = { onOpenTrend(KilterTrendKind.ANGLE) }) }
            }

            // Tier 2 — a kindly consistency strip.
            if (stats.sendsPerWeek.isNotEmpty()) {
                item { ConsistencyStrip(stats, onClick = { onOpenTrend(KilterTrendKind.CONSISTENCY) }) }
            }

            item { Spacer(Modifier.height(8.dp)) }
        }
    }
}

/** The tier-2 trend screens a doorway tile can open (host-wired; inline sections render here for v1). */
enum class KilterTrendKind { VOLUME, PROGRESSION, ANGLE, CONSISTENCY }

// MARK: - Tier 1: hero + delta -------------------------------------------------------------------

@Composable
private fun HeroTier(stats: KilterAllTimeStats.Stats) {
    Card(testTag = "kilter.stats.hero") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // ONE hero numeral — the Climbing Level, in the module accent (amber = wayfinding).
            Text(
                stats.climbingLevelLabel ?: "—",
                style = MaterialTheme.typography.displayMedium,
                fontWeight = FontWeight.Black,
                color = kilterAccent(),
                modifier = Modifier.clearAndSetSemantics {
                    contentDescription = "Climbing level ${stats.climbingLevelLabel ?: "not set"}"
                },
            )
            Spacer(Modifier.width(16.dp))
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "CLIMBING LEVEL",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                stats.maxGradeLabel?.let {
                    Text(
                        "All-time best $it",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                LevelDeltaChip(stats)
            }
        }
    }
}

/**
 * The perf-ramp level delta vs ~90 days ago — read from the pre-built monthly progression series (no
 * math). Perf-ramp coloured (effort/state axis): up = success-green, down = warning-amber. Hidden when
 * there isn't enough history to compute a step.
 */
@Composable
private fun LevelDeltaChip(stats: KilterAllTimeStats.Stats) {
    val prog = stats.maxGradeProgression
    if (prog.size < 2) return
    // Compare the latest month's best send against the one closest to ~3 months earlier in the series.
    val latest = prog.last()
    val baseline = prog.getOrNull((prog.size - 4).coerceAtLeast(0)) ?: return
    val steps = latest.difficulty.roundToInt() - baseline.difficulty.roundToInt()
    if (steps == 0) return
    val up = steps > 0
    val color = if (up) pulseSuccess() else pulseWarning()
    Box(
        Modifier.clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.16f))
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .clearAndSetSemantics {
                contentDescription =
                    "Climbing level ${if (up) "up" else "down"} ${kotlin.math.abs(steps)} grades versus 90 days ago"
            },
    ) {
        Text(
            "${if (up) "▲ +" else "▼ "}$steps vs 90d",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = color,
        )
    }
}

// MARK: - Tier 1: stat ribbon --------------------------------------------------------------------

@Composable
private fun StatRibbon(stats: KilterAllTimeStats.Stats) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StatTile("${stats.totalSends}", "Sent", Modifier.weight(1f))
        StatTile("${(stats.flashRate * 100).roundToInt()}%", "Flash rate", Modifier.weight(1f))
        StatTile("${stats.sendsPerWeek.lastOrNull()?.sends ?: 0}", "This week", Modifier.weight(1f))
    }
}

@Composable
private fun StatTile(value: String, label: String, modifier: Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(vertical = 12.dp, horizontal = 14.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 1)
        Text(
            label.uppercase(Locale.getDefault()),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
        )
    }
}

// MARK: - Tier 2: segmented pyramid (Canvas) -----------------------------------------------------

/**
 * Okabe-Ito colorblind-safe segment colours (NOT theme hue): orange for flashes, bluish-green for
 * redpoint sends. Distinguishable by everyone; the spelled-out legend makes the meaning explicit so
 * the chart never relies on hue alone.
 */
private val FlashColor = Color(0xFFE69F00)   // Okabe-Ito orange
private val SendColor = Color(0xFF009E73)    // Okabe-Ito bluish-green

@Composable
private fun PyramidCard(
    stats: KilterAllTimeStats.Stats,
    selectedGrade: String?,
    onSelectGrade: (String) -> Unit,
) {
    val bars = stats.pyramid
    // The widest bar (by send total) sets the full-width scale; every other bar is proportional.
    val maxSends = bars.maxOf { it.sends }.coerceAtLeast(1)
    val trackColor = MaterialTheme.colorScheme.surfaceVariant
    val accent = kilterAccent()
    val markerColor = pulseWarning()
    val selectedBg = accent.copy(alpha = 0.12f)

    Card(testTag = "kilter.stats.pyramid") {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Grade pyramid", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)

            // Easiest at the bottom (hardest at top) — the pyramid orientation. The engine returns
            // easiest→hardest, so reverse for top-down render.
            bars.asReversed().forEach { bar ->
                val isMax = stats.maxGradeLabel == bar.gradeLabel
                val selected = selectedGrade == bar.gradeLabel
                Row(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (selected) selectedBg else Color.Transparent)
                        .clickable { onSelectGrade(bar.gradeLabel) }
                        .padding(vertical = 3.dp, horizontal = 4.dp)
                        .testTag("kilter.stats.pyramidBar.${bar.gradeLabel}")
                        .clearAndSetSemantics {
                            contentDescription = barDescription(bar, isMax, selected)
                        },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        bar.gradeLabel,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                        modifier = Modifier.width(40.dp),
                    )
                    Canvas(
                        Modifier.weight(1f).height(20.dp),
                    ) {
                        val full = size.width
                        val h = size.height
                        val radius = h / 2f
                        // Track behind the bar (so short bars still read on the row).
                        drawRoundRect(
                            color = trackColor,
                            cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius),
                            size = androidx.compose.ui.geometry.Size(full, h),
                        )
                        val barWidth = full * (bar.sends.toFloat() / maxSends)
                        if (barWidth > 0f) {
                            // Flash segment (Okabe-Ito orange) then redpoint-send segment (bluish-green).
                            val flashW = barWidth * (bar.flashes.toFloat() / bar.sends.coerceAtLeast(1))
                            val sendW = barWidth - flashW
                            // Draw the whole bar as the send colour, then overlay the flash portion, so a
                            // single rounded-rect outline reads cleanly with two segments inside it.
                            drawRoundRect(
                                color = SendColor,
                                cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius),
                                size = androidx.compose.ui.geometry.Size(barWidth.coerceAtLeast(radius * 2), h),
                            )
                            if (flashW > 0f) {
                                // Flash leads the bar (left), clipped to the rounded left cap.
                                drawRoundRect(
                                    color = FlashColor,
                                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius),
                                    size = androidx.compose.ui.geometry.Size(
                                        flashW.coerceAtLeast(radius * 2), h,
                                    ),
                                )
                                if (sendW > 0f) {
                                    // Square off the flash segment's right edge where the send segment meets it.
                                    drawRect(
                                        color = FlashColor,
                                        topLeft = Offset(flashW - radius, 0f),
                                        size = androidx.compose.ui.geometry.Size(radius, h),
                                    )
                                }
                            }
                        }
                        // Dashed current-max marker — a vertical guide at the all-time-best grade row.
                        if (isMax) {
                            drawLine(
                                color = markerColor,
                                start = Offset(0f, 0f),
                                end = Offset(full, 0f),
                                strokeWidth = 2f,
                                cap = StrokeCap.Round,
                                pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f), 0f),
                            )
                        }
                    }
                    Text(
                        "${bar.sends}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.End,
                        modifier = Modifier.width(40.dp).padding(start = 8.dp),
                    )
                }
            }

            // Colorblind-safe legend: a swatch AND the spelled-out meaning (never hue alone).
            Row(
                Modifier.padding(top = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                LegendSwatch(FlashColor, "Flash")
                LegendSwatch(SendColor, "Send")
                Text(
                    "— tap a grade to filter your sends",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun LegendSwatch(color: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.size(11.dp).clip(RoundedCornerShape(3.dp)).background(color))
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun barDescription(bar: GradeCount, isMax: Boolean, selected: Boolean): String {
    val flashClause = if (bar.flashes > 0) ", ${bar.flashes} flashed" else ""
    val maxClause = if (isMax) ", your current max grade" else ""
    val selClause = if (selected) ", selected" else ""
    return "${bar.gradeLabel}: ${bar.sends} send${if (bar.sends == 1) "" else "s"}$flashClause$maxClause$selClause"
}

// MARK: - Tier 2: in-page filtered ascent log ----------------------------------------------------

/** Cap on rendered rows — a heavily-climbed grade can have hundreds of sends; show the most recent. */
private const val FILTERED_ASCENT_CAP = 100

@Composable
private fun AscentLogSection(grade: String, sends: List<KilterLogEntry>, onClear: () -> Unit) {
    val dateFmt = remember { SimpleDateFormat("d MMM", Locale.getDefault()) }
    val visible = sends.take(FILTERED_ASCENT_CAP)
    val overflow = sends.size - visible.size
    Card(testTag = "kilter.stats.ascentLog") {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Sends · $grade",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onClear, modifier = Modifier.testTag("kilter.stats.clearGradeFilter")) {
                    Text("Clear")
                }
            }
            if (visible.isEmpty()) {
                Text(
                    "No sends at this grade yet.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                visible.forEach { entry ->
                    val status = KilterAscentStatus.from(entry.status)
                    val color = if (status == KilterAscentStatus.FLASH) FlashColor else pulseSuccess()
                    Row(
                        Modifier.fillMaxWidth().testTag("kilter.stats.filteredAscent"),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Box(
                            Modifier.clip(RoundedCornerShape(6.dp))
                                .background(color.copy(alpha = 0.20f))
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        ) {
                            Text(
                                status.label, style = MaterialTheme.typography.labelSmall,
                                color = color, fontWeight = FontWeight.SemiBold,
                            )
                        }
                        Text(
                            entry.climbName, style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium, maxLines = 1, modifier = Modifier.weight(1f),
                        )
                        Text(
                            "${entry.angle}°", style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            dateFmt.format(Date(entry.createdAt)),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                if (overflow > 0) {
                    Text(
                        "+$overflow more send${if (overflow == 1) "" else "s"} at this grade",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// MARK: - Tier 2: send / flash rings -------------------------------------------------------------

@Composable
private fun RingsRow(stats: KilterAllTimeStats.Stats) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        RingGauge(
            fraction = stats.sendRate, label = "Send rate", color = pulseSuccess(),
            testTag = "kilter.stats.ring.send", modifier = Modifier.weight(1f),
        )
        RingGauge(
            fraction = stats.flashRate, label = "Flash rate", color = FlashColor,
            testTag = "kilter.stats.ring.flash", modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun RingGauge(
    fraction: Double,
    label: String,
    color: Color,
    testTag: String,
    modifier: Modifier,
) {
    val pct = (fraction.coerceIn(0.0, 1.0) * 100).roundToInt()
    val track = MaterialTheme.colorScheme.surfaceVariant
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .padding(vertical = 14.dp)
            .testTag(testTag)
            .clearAndSetSemantics { contentDescription = "$label $pct percent" },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(92.dp)) {
                val stroke = 10.dp.toPx()
                val inset = stroke / 2f
                val arcSize = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
                val topLeft = Offset(inset, inset)
                drawArc(
                    color = track, startAngle = 0f, sweepAngle = 360f, useCenter = false,
                    topLeft = topLeft, size = arcSize, style = Stroke(width = stroke),
                )
                drawArc(
                    color = color, startAngle = -90f,
                    sweepAngle = (fraction.coerceIn(0.0, 1.0) * 360f).toFloat(), useCenter = false,
                    topLeft = topLeft, size = arcSize, style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
            Text("$pct%", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        }
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// MARK: - Tier 2: sends-per-week volume trend ----------------------------------------------------

@Composable
private fun VolumeTile(stats: KilterAllTimeStats.Stats, onClick: () -> Unit) {
    val weeks = stats.sendsPerWeek
    val accent = kilterAccent()
    val maxBar = weeks.maxOfOrNull { it.sends }?.coerceAtLeast(1) ?: 1
    val summary = remember(weeks) {
        ChartAccessibility.weekBarSummary("Sends per week", weeks.map { it.sends }, "send")
    }
    Card(testTag = "kilter.stats.tile.volume", onClick = onClick) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TileHeader("Sends / week", "${stats.totalSends} total sends")
            Row(
                Modifier.fillMaxWidth().height(80.dp)
                    .clearAndSetSemantics { contentDescription = summary },
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                weeks.forEach { w ->
                    val frac = (w.sends.toFloat() / maxBar).coerceIn(0.04f, 1f)
                    Box(
                        Modifier.weight(1f).fillMaxHeight(frac)
                            .clip(RoundedCornerShape(topStart = 5.dp, topEnd = 5.dp))
                            .background(if (w.sends > 0) accent else accent.copy(alpha = 0.25f)),
                    )
                }
            }
        }
    }
}

// MARK: - Tier 2: max-grade progression ----------------------------------------------------------

@Composable
private fun ProgressionTile(stats: KilterAllTimeStats.Stats, onClick: () -> Unit) {
    val points = stats.maxGradeProgression
    val accent = kilterAccent()
    val diffs = points.map { it.difficulty }
    val lo = (diffs.minOrNull() ?: 0.0) - 0.5
    val hi = (diffs.maxOrNull() ?: 1.0) + 0.5
    val range = (hi - lo).coerceAtLeast(1.0)
    Card(testTag = "kilter.stats.tile.progression", onClick = onClick) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TileHeader("Max grade progression", stats.maxGradeLabel?.let { "all-time best $it" } ?: "—")
            Row(
                Modifier.fillMaxWidth().height(72.dp),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                points.forEach { p ->
                    val frac = (((p.difficulty - lo) / range).toFloat()).coerceIn(0.08f, 1f)
                    Box(
                        Modifier.weight(1f).fillMaxHeight(frac)
                            .clip(RoundedCornerShape(topStart = 4.dp, topEnd = 4.dp))
                            .background(accent),
                    )
                }
            }
        }
    }
}

// MARK: - Tier 2: angle distribution -------------------------------------------------------------

@Composable
private fun AngleTile(stats: KilterAllTimeStats.Stats, onClick: () -> Unit) {
    val angles = stats.angleDistribution
    val top = angles.maxByOrNull { it.sends }
    val maxBar = angles.maxOf { it.sends }.coerceAtLeast(1)
    val barColor = pulseSuccess()
    val track = MaterialTheme.colorScheme.surfaceVariant
    Card(testTag = "kilter.stats.tile.angle", onClick = onClick) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            TileHeader("Sends by angle", top?.let { "top ${it.angle}°" } ?: "—")
            angles.forEach { a ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "${a.angle}°", style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.width(40.dp),
                    )
                    Box(Modifier.weight(1f).height(14.dp)) {
                        Box(Modifier.fillMaxWidth().fillMaxHeight().clip(RoundedCornerShape(7.dp)).background(track))
                        Box(
                            Modifier.fillMaxWidth(a.sends.toFloat() / maxBar).fillMaxHeight()
                                .clip(RoundedCornerShape(7.dp)).background(barColor),
                        )
                    }
                    Text(
                        "${a.sends}", style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.End, modifier = Modifier.width(36.dp).padding(start = 8.dp),
                    )
                }
            }
        }
    }
}

// MARK: - Tier 2: consistency strip --------------------------------------------------------------

@Composable
private fun ConsistencyStrip(stats: KilterAllTimeStats.Stats, onClick: () -> Unit) {
    val weeks = stats.sendsPerWeek
    val active = weeks.count { it.sends > 0 }
    val dotOn = pulseSuccess()
    val dotOff = MaterialTheme.colorScheme.surfaceVariant
    Card(testTag = "kilter.stats.tile.consistency", onClick = onClick) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TileHeader("Consistency", "$active of ${weeks.size} weeks active")
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                weeks.forEach { w ->
                    Column(
                        Modifier.weight(1f),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Box(
                            Modifier.size(14.dp).clip(RoundedCornerShape(50))
                                .background(if (w.sends > 0) dotOn else dotOff),
                        )
                        Text(
                            "${w.sends}", style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            Text(
                "Rest weeks are part of the plan — this is a streak you can be kind to.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// MARK: - Shared chrome --------------------------------------------------------------------------

@Composable
private fun TileHeader(title: String, caption: String) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        Text(caption, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A surface card matching the dashboard's tile look; an optional [onClick] makes it a doorway. */
@Composable
private fun Card(
    testTag: String,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val base = Modifier.fillMaxWidth()
        .clip(RoundedCornerShape(16.dp))
        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
    val clickable = if (onClick != null) base.clickable(onClick = onClick) else base
    Box(clickable.padding(16.dp).testTag(testTag)) { content() }
}

// MARK: - Bridge ---------------------------------------------------------------------------------

/** Adapt a Room [KilterLogEntry] to the pure-engine [SessionLog] the aggregator consumes. */
private fun KilterLogEntry.asSessionLog(): SessionLog = SessionLog(
    climbUuid = climbUuid,
    climbName = climbName,
    gradeLabel = gradeLabel,
    difficulty = difficulty,
    status = KilterAscentStatus.from(status),
    attempts = attempts,
    loggedAt = createdAt,
    angle = angle,
    sessionId = sessionId,
)
