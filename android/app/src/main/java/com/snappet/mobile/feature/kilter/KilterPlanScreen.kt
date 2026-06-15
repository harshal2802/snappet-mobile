package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.kilterAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Issue #93: "Plan a session" — the guided **what should I climb today** entry point (iOS parity). Reads
 * the user's logged ascents, detects a working grade, fetches a catalog candidate pool over the
 * recommender's difficulty window, and renders a warm-up → send → project set grouped by goal. The
 * decision logic is the pure, unit-tested [KilterRecommender]; this screen is only the I/O + layout.
 * Tapping a pick opens it in detail (within the same browsed set so swipe still works). `onExit` returns
 * to the catalog.
 */
@Composable
fun KilterPlanScreen(
    catalog: KilterCatalog,
    dao: KilterDao,
    onOpenClimb: (String, List<String>) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val logs by dao.logsFlow().collectAsState(initial = emptyList())
    val layoutId = remember { KilterSettings.layout(context) }
    val angle = remember { KilterSettings.angle(context) }
    val gradeScale = remember { catalog.gradeScale() }

    var plan by remember { mutableStateOf<KilterRecommender.Plan?>(null) }

    // Recompute whenever the history changes. The anchor is the detected working grade, or — for a cold
    // start — the median of the layout's grade scale, so a brand-new climber still gets a spread. The
    // candidate query uses the SAME anchor's window so every recommender band is populated.
    androidx.compose.runtime.LaunchedEffect(logs, layoutId, angle) {
        val result = withContext(Dispatchers.IO) {
            if (!catalog.isAvailable) return@withContext KilterRecommender.Plan.EMPTY
            val working = KilterRecommender.workingDifficulty(logs)
            val anchor = working ?: run {
                val keys = gradeScale.map { it.first.toDouble() }.sorted()
                if (keys.isEmpty()) 0.0 else keys[keys.size / 2]
            }
            val (lo, hi) = KilterRecommender.candidateWindow(anchor)
            val candidates = catalog.list(
                KilterFilter(layoutId, angle, lo, hi, sort = KilterSort.QUALITY),
                limit = 400,
            )
            KilterRecommender.recommend(logs, candidates, anchor = anchor)
        }
        plan = result
    }

    ModuleScaffold(title = "Plan a session", onExit = onExit) { padding ->
        val p = plan
        when {
            p == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            p.isEmpty -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Not enough to plan yet", style = MaterialTheme.typography.titleMedium)
                    Text("Log a few climbs (or widen your grade range) and we'll suggest a warm-up, sends, and a project.",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp))
                }
            }
            else -> {
                val allUuids = p.picks.map { it.item.uuid }
                LazyColumn(
                    Modifier.fillMaxSize().padding(padding).testTag("kilter.plan.list"),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    item {
                        val anchor = p.workingGradeLabel
                        Text(
                            if (anchor != null) "Built around your working grade, $anchor."
                            else "A starter spread to get you climbing.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 8.dp),
                        )
                    }
                    for (goal in KilterRecommender.Goal.entries) {
                        val picks = p.picks(goal)
                        if (picks.isEmpty()) continue
                        item(key = "header.${goal.name}") {
                            Text(goal.label, style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
                        }
                        items(picks, key = { it.item.uuid }) { pick ->
                            PlanRow(pick) { onOpenClimb(pick.item.uuid, allUuids) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PlanRow(pick: KilterRecommender.Pick, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .testTag("kilter.plan.row"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(pick.item.name, style = MaterialTheme.typography.titleSmall, maxLines = 1)
            Text("by ${pick.item.setter}", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        Box(
            Modifier.background(kilterAccent().copy(alpha = 0.16f), CircleShape)
                .padding(horizontal = 8.dp, vertical = 2.dp),
        ) {
            Text(pick.item.gradeLabel, style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold, color = kilterAccent())
        }
    }
}
