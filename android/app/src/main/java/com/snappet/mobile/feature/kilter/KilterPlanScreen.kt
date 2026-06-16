package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.kilterAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * "Plan a session" (iOS-parity planned-session lifecycle). Two modes off one screen:
 *  • **Generate** (no plan pinned to the live session): the pure [KilterRecommender] turns the user's
 *    logs into a *preview*; an Adjust sheet (selection strategies + knobs) + Shuffle tune it; **Start**
 *    snapshots it into a frozen [KilterPlanEntity] pinned to the session.
 *  • **Session home** (a plan is pinned): reads the **stored, frozen** plan — each pick's tick comes
 *    from [KilterPlanItem.status], never re-derived — with live progress, a "next up" highlight, and a
 *    **Finish plan** action. This is the re-enterable home a running session returns to.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KilterPlanScreen(
    catalog: KilterCatalog,
    dao: KilterDao,
    sessions: KilterSessionManager,
    onOpenClimb: (String, List<String>) -> Unit,
    onFinish: (String) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val logs by dao.logsFlow().collectAsState(initial = emptyList())
    val plans by dao.plansFlow().collectAsState(initial = emptyList())
    val layoutId = remember { KilterSettings.layout(context) }
    val angle = remember { KilterSettings.angle(context) }
    val gradeScale = remember { catalog.gradeScale() }

    var strategyRaw by remember { mutableStateOf(KilterSettings.planStrategy(context)) }
    var targetCount by remember { mutableIntStateOf(KilterSettings.planTargetCount(context)) }
    var gradeOffset by remember { mutableIntStateOf(KilterSettings.planGradeOffset(context)) }
    var preferUnsent by remember { mutableStateOf(KilterSettings.planPreferUnsent(context)) }
    var rerollSeed by remember { mutableIntStateOf(0) }
    var showConfig by remember { mutableStateOf(false) }
    val strategy = KilterRecommender.Strategy.entries.firstOrNull { it.name == strategyRaw }
        ?: KilterRecommender.Strategy.BALANCED

    // The active plan pinned to the live session → session-home. Newest-by-createdAt is deterministic.
    val activePlan = plans.filter { it.sessionId != null && it.sessionId == sessions.currentSessionId && it.completedAt == null }
        .maxByOrNull { it.createdAt }
    val isSessionHome = activePlan != null

    var preview by remember { mutableStateOf<KilterRecommender.Plan?>(null) }
    androidx.compose.runtime.LaunchedEffect(
        logs, layoutId, angle, strategyRaw, targetCount, gradeOffset, preferUnsent, rerollSeed, isSessionHome,
    ) {
        if (isSessionHome) return@LaunchedEffect
        preview = withContext(Dispatchers.IO) {
            if (!catalog.isAvailable) return@withContext KilterRecommender.Plan.EMPTY
            val working = KilterRecommender.workingDifficulty(logs)
            val base = working ?: run {
                val keys = gradeScale.map { it.first.toDouble() }.sorted()
                if (keys.isEmpty()) 18.0 else keys[keys.size / 2]   // match iOS median fallback
            }
            // Apply the grade offset to the anchor HERE so the candidate window + recommender bands stay
            // aligned (the recommender's contract).
            val anchor = base + gradeOffset
            val (lo, hi) = KilterRecommender.candidateWindow(anchor)
            val candidates = catalog.list(KilterFilter(layoutId, angle, lo, hi, sort = KilterSort.QUALITY), limit = 400)
            KilterRecommender.recommend(
                logs, candidates, anchor = anchor,
                options = KilterRecommender.Options(
                    targetCount = targetCount, preferUnsent = preferUnsent,
                    mix = KilterRecommender.config(strategy).mix, rerollSeed = rerollSeed,
                ),
            )
        }
    }

    fun startPlan(p: KilterRecommender.Plan) {
        if (p.isEmpty) return
        val items = KilterPlanProgress.items(p)
        val plan = KilterPlanEntity(
            id = UUID.randomUUID().toString(), createdAt = System.currentTimeMillis(),
            angle = angle, layoutId = layoutId,
            workingDifficulty = p.workingDifficulty, workingGradeLabel = p.workingGradeLabel,
            title = if (strategy == KilterRecommender.Strategy.BALANCED) null else strategy.label,
            optionsTargetCount = targetCount, optionsPreferUnsent = preferUnsent,
            optionsGradeOffset = gradeOffset, strategyRaw = strategyRaw,
            itemsJson = KilterPlanItemsCodec.encode(items),
        )
        scope.launch {
            if (sessions.currentSessionId == null) sessions.start(angle, "manual")
            sessions.startPlan(plan, items)   // re-enters an existing open plan or pins the new one
            // Open the next pick of whatever plan is now active (startPlan seeds the pending cache).
            val pending = sessions.planPendingUuids
            val target = pending.firstOrNull() ?: items.firstOrNull()?.climbUuid
            if (target != null) onOpenClimb(target, pending.ifEmpty { items.map { it.climbUuid } })
        }
    }

    ModuleScaffold(title = if (isSessionHome) "Session plan" else "Plan a session", onExit = onExit) { padding ->
        if (activePlan != null) {
            SessionHome(
                plan = activePlan, padding = padding, onOpenClimb = onOpenClimb,
                onSkip = { id -> scope.launch { sessions.skipPlanItem(id) } },
                onFinish = {
                    val sid = sessions.currentSessionId
                    scope.launch { sessions.end() }
                    if (sid != null) onFinish(sid)
                },
            )
        } else {
            GenerateMode(
                preview = preview, strategy = strategy, padding = padding,
                onAdjust = { showConfig = true }, onShuffle = { rerollSeed++ },
                onStart = { preview?.let { startPlan(it) } }, onOpenClimb = onOpenClimb,
            )
        }
    }

    if (showConfig) {
        PlanConfigSheet(
            strategy = strategy, targetCount = targetCount, gradeOffset = gradeOffset, preferUnsent = preferUnsent,
            onSelectStrategy = { s ->
                val c = KilterRecommender.config(s)
                strategyRaw = s.name; targetCount = c.targetCount; gradeOffset = c.gradeOffset; preferUnsent = c.preferUnsent
                KilterSettings.setPlanStrategy(context, s.name)
                KilterSettings.setPlanTargetCount(context, c.targetCount)
                KilterSettings.setPlanGradeOffset(context, c.gradeOffset)
                KilterSettings.setPlanPreferUnsent(context, c.preferUnsent)
            },
            onTargetCount = { v -> targetCount = v.coerceIn(3, 12); KilterSettings.setPlanTargetCount(context, targetCount) },
            onGradeOffset = { v -> gradeOffset = v.coerceIn(-3, 3); KilterSettings.setPlanGradeOffset(context, gradeOffset) },
            onPreferUnsent = { v -> preferUnsent = v; KilterSettings.setPlanPreferUnsent(context, v) },
            onDismiss = { showConfig = false },
        )
    }
}

@Composable
private fun GenerateMode(
    preview: KilterRecommender.Plan?,
    strategy: KilterRecommender.Strategy,
    padding: PaddingValues,
    onAdjust: () -> Unit,
    onShuffle: () -> Unit,
    onStart: () -> Unit,
    onOpenClimb: (String, List<String>) -> Unit,
) {
    when {
        preview == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        preview.isEmpty -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Not enough to plan yet", style = MaterialTheme.typography.titleMedium)
                Text(
                    "Log a few climbs (or widen your grade range) and we'll suggest a warm-up, sends, and a project.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp),
                )
                OutlinedButton(onClick = onAdjust, modifier = Modifier.padding(top = 12.dp).testTag("kilter.plan.adjust")) {
                    Text("Adjust: ${strategy.label}")
                }
            }
        }
        else -> {
            val allUuids = preview.picks.map { it.item.uuid }
            LazyColumn(
                Modifier.fillMaxSize().padding(padding).testTag("kilter.plan.list"),
                contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            val a = preview.workingGradeLabel
                            Text(
                                if (a != null) "Built around your working grade, $a." else "A starter spread to get you climbing.",
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        TextButton(onClick = onShuffle, modifier = Modifier.testTag("kilter.plan.shuffle")) { Text("Shuffle") }
                        OutlinedButton(onClick = onAdjust, modifier = Modifier.testTag("kilter.plan.adjust")) { Text(strategy.label) }
                    }
                }
                for (goal in KilterRecommender.Goal.entries) {
                    val picks = preview.picks(goal)
                    if (picks.isEmpty()) continue
                    item(key = "header.${goal.name}") {
                        Text(goal.label, style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
                    }
                    items(picks, key = { it.item.uuid }) { pick ->
                        PreviewRow(pick) { onOpenClimb(pick.item.uuid, allUuids) }
                    }
                }
                item {
                    Button(onClick = onStart, modifier = Modifier.fillMaxWidth().padding(top = 12.dp).testTag("kilter.plan.start")) {
                        Text("Start session")
                    }
                }
            }
        }
    }
}

@Composable
private fun SessionHome(
    plan: KilterPlanEntity,
    padding: PaddingValues,
    onOpenClimb: (String, List<String>) -> Unit,
    onSkip: (String) -> Unit,
    onFinish: () -> Unit,
) {
    val items = remember(plan.itemsJson) { KilterPlanItemsCodec.decode(plan.itemsJson) }
    val (done, total) = KilterPlanProgress.progress(items)
    val nextId = KilterPlanProgress.nextPending(items)?.id
    val allUuids = items.map { it.climbUuid }
    LazyColumn(
        Modifier.fillMaxSize().padding(padding).testTag("kilter.plan.list"),
        contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Column {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Plan in progress", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.weight(1f))
                    Text("$done of $total done", style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("kilter.plan.progress"))
                }
                LinearProgressIndicator(
                    progress = { if (total == 0) 0f else done.toFloat() / total },
                    color = kilterAccent(), modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                )
                plan.workingGradeLabel?.let {
                    Text("Working grade ~ $it · ${plan.angle}°", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
                }
            }
        }
        for (goal in KilterRecommender.Goal.entries) {
            val goalItems = items.filter { it.goal == goal }.sortedBy { it.order }
            if (goalItems.isEmpty()) continue
            item(key = "header.${goal.name}") {
                Text(goal.label, style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
            }
            items(goalItems, key = { it.id }) { item ->
                PlanItemRow(item, isNext = item.id == nextId,
                    onClick = { onOpenClimb(item.climbUuid, allUuids) },
                    onSkip = if (item.status == KilterPlanItemStatus.PENDING) ({ onSkip(item.id) }) else null)
            }
        }
        item {
            Button(onClick = onFinish, modifier = Modifier.fillMaxWidth().padding(top = 12.dp).testTag("kilter.plan.finish")) {
                Text("Finish plan")
            }
        }
    }
}

@Composable
private fun PlanItemRow(item: KilterPlanItem, isNext: Boolean, onClick: () -> Unit, onSkip: (() -> Unit)?) {
    Row(
        Modifier.fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp).testTag("kilter.plan.row"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatusDot(item.status)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                item.climbName, style = MaterialTheme.typography.titleSmall, maxLines = 1,
                textDecoration = if (item.status == KilterPlanItemStatus.SKIPPED) TextDecoration.LineThrough else null,
                color = if (item.status.isDone) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("by ${item.setter}", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                if (isNext) {
                    Spacer(Modifier.width(6.dp))
                    Text("NEXT UP", style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold, color = kilterAccent())
                }
            }
        }
        if (onSkip != null) {
            TextButton(onClick = onSkip, modifier = Modifier.testTag("kilter.plan.skip")) { Text("Skip") }
        }
        Box(Modifier.background(kilterAccent().copy(alpha = 0.16f), CircleShape).padding(horizontal = 8.dp, vertical = 2.dp)) {
            Text(item.gradeLabel, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = kilterAccent())
        }
    }
}

@Composable
private fun StatusDot(status: KilterPlanItemStatus) {
    val (symbol, color) = when (status) {
        KilterPlanItemStatus.SENT -> "✓" to Color(0xFF2E7D32)
        KilterPlanItemStatus.ATTEMPTED -> "◐" to Color(0xFFEF6C00)
        KilterPlanItemStatus.SKIPPED -> "–" to MaterialTheme.colorScheme.onSurfaceVariant
        KilterPlanItemStatus.PENDING -> "○" to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
        Text(symbol, style = MaterialTheme.typography.titleMedium, color = color)
    }
}

@Composable
private fun PreviewRow(pick: KilterRecommender.Pick, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp).testTag("kilter.plan.row"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(pick.item.name, style = MaterialTheme.typography.titleSmall, maxLines = 1)
            Text("by ${pick.item.setter}", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        Box(Modifier.background(kilterAccent().copy(alpha = 0.16f), CircleShape).padding(horizontal = 8.dp, vertical = 2.dp)) {
            Text(pick.item.gradeLabel, style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold, color = kilterAccent())
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlanConfigSheet(
    strategy: KilterRecommender.Strategy,
    targetCount: Int,
    gradeOffset: Int,
    preferUnsent: Boolean,
    onSelectStrategy: (KilterRecommender.Strategy) -> Unit,
    onTargetCount: (Int) -> Unit,
    onGradeOffset: (Int) -> Unit,
    onPreferUnsent: (Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("Adjust plan", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("Strategy", style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 12.dp))
            for (s in KilterRecommender.Strategy.entries) {
                Row(
                    Modifier.fillMaxWidth().clickable { onSelectStrategy(s) }
                        .padding(vertical = 8.dp).testTag("kilter.plan.strategy.${s.name}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(s.label, style = MaterialTheme.typography.bodyLarge,
                            fontWeight = if (s == strategy) FontWeight.SemiBold else FontWeight.Normal)
                        Text(s.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (s == strategy) Text("✓", color = kilterAccent(), style = MaterialTheme.typography.titleMedium)
                }
            }
            Stepper("Session length", "$targetCount climbs", { onTargetCount(targetCount - 1) }, { onTargetCount(targetCount + 1) })
            Stepper("Target grade", offsetLabel(gradeOffset), { onGradeOffset(gradeOffset - 1) }, { onGradeOffset(gradeOffset + 1) })
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Prefer climbs I haven't sent", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Switch(checked = preferUnsent, onCheckedChange = onPreferUnsent)
            }
            FilledTonalButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth().padding(top = 16.dp)) { Text("Done") }
        }
    }
}

private fun offsetLabel(o: Int): String = if (o == 0) "at grade" else if (o > 0) "+$o" else "$o"

@Composable
private fun Stepper(label: String, value: String, onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            Text(value, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        OutlinedButton(onClick = onMinus) { Text("–") }
        Spacer(Modifier.width(8.dp))
        OutlinedButton(onClick = onPlus) { Text("+") }
    }
}
