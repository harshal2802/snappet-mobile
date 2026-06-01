package com.snappet.mobile.feature.workout

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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit

private val Orange = Color(0xFFF76808)

private enum class WorkoutScreen { ROOT, EXERCISE_DETAIL, ROUTINE_DETAIL, PLAYER, SESSION_DETAIL }
private enum class WorkoutSection(val title: String) {
    EXERCISES("Exercises"), ROUTINES("Routines"), HISTORY("History"), SETTINGS("Settings")
}

/**
 * Root entry for the Workout Tracker mini-app (module id `workout-log`). A dashboard with headline
 * stats sits above a 4-way section selector (Exercises / Routines / History / Settings). Deeper
 * screens — exercise detail, routine detail, the live player and session detail — are managed with
 * local navigation state, each in its own [ModuleScaffold]. Mirrors iOS `WorkoutHomeView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkoutRoot(onExit: () -> Unit) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val dao = container.database.workoutDao()
    val core = container.core
    val scope = rememberCoroutineScope()

    val routines by dao.routinesFlow().collectAsState(initial = emptyList())
    val sessions by dao.sessionsFlow().collectAsState(initial = emptyList())
    val customExercises by dao.customExercisesFlow().collectAsState(initial = emptyList())

    var unit by remember { mutableStateOf(WorkoutSettings.preferredUnit(context)) }
    var screen by remember { mutableStateOf(WorkoutScreen.ROOT) }
    var section by remember { mutableStateOf(WorkoutSection.EXERCISES) }

    var selectedExerciseId by remember { mutableStateOf<String?>(null) }
    var selectedRoutineRow by remember { mutableStateOf<Long?>(null) }
    var selectedSessionRow by remember { mutableStateOf<Long?>(null) }
    var playingSessionRow by remember { mutableStateOf<Long?>(null) }

    val resolver = remember(customExercises) { WorkoutResolver(customExercises) }
    val history = remember(sessions) { sessions.filter { !it.isActive } }
    val catalog = remember(customExercises) {
        (WorkoutCatalog.all + customExercises.map { it.asExercise() }).sortedBy { it.name.lowercase() }
    }

    // Seed starter routines on first open if the store is empty.
    LaunchedEffect(Unit) { WorkoutStarters.seedIfNeeded(dao) }

    val selectedExercise = selectedExerciseId?.let { id -> catalog.firstOrNull { it.id == id } }
    val selectedRoutine = routines.firstOrNull { it.id == selectedRoutineRow }
    val selectedSession = sessions.firstOrNull { it.id == selectedSessionRow }
    val playingSession = sessions.firstOrNull { it.id == playingSessionRow }

    fun startWorkout(routine: WorkoutRoutine) {
        scope.launch {
            val exercises = routine.exercises.map { re ->
                WorkoutSessionExercise(
                    exerciseId = re.exerciseId,
                    targetSets = re.sets,
                    targetReps = re.reps,
                    targetRestSeconds = re.restSeconds,
                    targetWeight = re.weight,
                    sets = List(maxOf(1, re.sets)) { WorkoutSetLog(weightUnit = unit) },
                    displayName = re.displayName,
                )
            }
            val rowId = dao.insertSession(
                WorkoutSession.create(routine.routineId, routine.name, exercises),
            )
            playingSessionRow = rowId
            screen = WorkoutScreen.PLAYER
        }
    }

    when (screen) {
        WorkoutScreen.EXERCISE_DETAIL -> {
            val ex = selectedExercise
            if (ex == null) screen = WorkoutScreen.ROOT
            else ExerciseDetailScreen(ex, onExit = { screen = WorkoutScreen.ROOT })
        }

        WorkoutScreen.ROUTINE_DETAIL -> {
            val r = selectedRoutine
            if (r == null) screen = WorkoutScreen.ROOT
            else RoutineDetailScreen(
                routine = r, resolver = resolver,
                onStart = { startWorkout(r) },
                onExit = { screen = WorkoutScreen.ROOT },
            )
        }

        WorkoutScreen.SESSION_DETAIL -> {
            val s = selectedSession
            if (s == null) screen = WorkoutScreen.ROOT
            else SessionDetailScreen(s, resolver, unit, onExit = { screen = WorkoutScreen.ROOT })
        }

        WorkoutScreen.PLAYER -> {
            val s = playingSession
            if (s == null) {
                screen = WorkoutScreen.ROOT
            } else {
                WorkoutPlayerScreen(
                    session = s, resolver = resolver, defaultUnit = unit,
                    persist = { updated -> scope.launch { dao.updateSession(updated) } },
                    onFinish = { finalSession, saved ->
                        scope.launch {
                            if (saved && finalSession.completedSetCount > 0) {
                                val done = finalSession.copy(finishedAt = System.currentTimeMillis())
                                dao.updateSession(done)
                                val mins = TimeUnit.MILLISECONDS.toMinutes(done.durationMillis).toInt()
                                core.log("workout-log", "session",
                                    "Completed ${done.routineName}", mins.toDouble())
                            } else {
                                dao.deleteSession(finalSession)
                            }
                            playingSessionRow = null
                            screen = WorkoutScreen.ROOT
                        }
                    },
                )
            }
        }

        WorkoutScreen.ROOT -> ModuleScaffold(title = "Workout", onExit = onExit) { padding ->
            RootContent(
                padding = padding,
                section = section,
                onSection = { section = it },
                history = history,
                routines = routines,
                catalog = catalog,
                resolver = resolver,
                unit = unit,
                onUnitChange = {
                    unit = it
                    WorkoutSettings.setPreferredUnit(context, it)
                },
                onOpenExercise = { selectedExerciseId = it.id; screen = WorkoutScreen.EXERCISE_DETAIL },
                onOpenRoutine = { selectedRoutineRow = it.id; screen = WorkoutScreen.ROUTINE_DETAIL },
                onOpenSession = { selectedSessionRow = it.id; screen = WorkoutScreen.SESSION_DETAIL },
            )
        }
    }
}

@Composable
private fun RootContent(
    padding: PaddingValues,
    section: WorkoutSection,
    onSection: (WorkoutSection) -> Unit,
    history: List<WorkoutSession>,
    routines: List<WorkoutRoutine>,
    catalog: List<WorkoutExercise>,
    resolver: WorkoutResolver,
    unit: WorkoutWeightUnit,
    onUnitChange: (WorkoutWeightUnit) -> Unit,
    onOpenExercise: (WorkoutExercise) -> Unit,
    onOpenRoutine: (WorkoutRoutine) -> Unit,
    onOpenSession: (WorkoutSession) -> Unit,
) {
    Column(Modifier.fillMaxSize().padding(padding)) {
        DashboardStrip(history)
        SectionSelector(section, onSection)
        when (section) {
            WorkoutSection.EXERCISES -> ExercisesSection(catalog, onOpenExercise)
            WorkoutSection.ROUTINES -> RoutinesSection(routines, resolver, onOpenRoutine)
            WorkoutSection.HISTORY -> HistorySection(history, unit, onOpenSession)
            WorkoutSection.SETTINGS -> SettingsSection(unit, onUnitChange)
        }
    }
}

// MARK: - Dashboard headline stats (markers the test asserts after a finish)

@Composable
private fun DashboardStrip(history: List<WorkoutSession>) {
    val streak = currentStreak(history)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        StatTile("${history.size}", "Workouts", Modifier.weight(1f))
        StatTile("$streak", "Day streak", Modifier.weight(1f))
        StatTile("${thisWeekCount(history)}", "This week", Modifier.weight(1f))
    }
}

@Composable
private fun StatTile(value: String, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Orange.copy(alpha = 0.12f))
            .padding(vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Orange)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SectionSelector(section: WorkoutSection, onSection: (WorkoutSection) -> Unit) {
    SingleChoiceSegmentedButtonRow(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        WorkoutSection.entries.forEachIndexed { index, s ->
            SegmentedButton(
                selected = section == s,
                onClick = { onSection(s) },
                shape = SegmentedButtonDefaults.itemShape(index, WorkoutSection.entries.size),
                modifier = Modifier.testTag("workout.section.${s.title}"),
            ) {
                Text(s.title, maxLines = 1, style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

// MARK: - Exercises section

@Composable
private fun ExercisesSection(catalog: List<WorkoutExercise>, onOpen: (WorkoutExercise) -> Unit) {
    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item { SectionTitle("Exercises") }
        items(catalog, key = { it.id }) { ex ->
            RowCard(
                onClick = { onOpen(ex) },
                modifier = Modifier.testTag("exerciseRow"),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(ex.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Text(ex.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

// MARK: - Routines section

@Composable
private fun RoutinesSection(
    routines: List<WorkoutRoutine>,
    resolver: WorkoutResolver,
    onOpen: (WorkoutRoutine) -> Unit,
) {
    if (routines.isEmpty()) {
        EmptyState("No routines yet", "Starter routines load on first open.")
        return
    }
    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item { SectionTitle("Routines") }
        items(routines, key = { it.id }) { r ->
            RowCard(
                onClick = { onOpen(r) },
                modifier = Modifier.testTag("routineRow"),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(r.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Text(
                        "${r.exercises.size} exercises · ${r.totalSets} sets",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// MARK: - History section

@Composable
private fun HistorySection(
    history: List<WorkoutSession>,
    unit: WorkoutWeightUnit,
    onOpen: (WorkoutSession) -> Unit,
) {
    if (history.isEmpty()) {
        EmptyState("No workouts yet", "Finish a session and it will appear here.")
        return
    }
    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item { SectionTitle("History") }
        items(history, key = { it.id }) { s ->
            RowCard(
                onClick = { onOpen(s) },
                modifier = Modifier.testTag("historyRow"),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(s.routineName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Text(
                        "${s.completedSetCount} sets · ${s.completedExerciseCount} exercises",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// MARK: - Settings section

@Composable
private fun SettingsSection(unit: WorkoutWeightUnit, onUnitChange: (WorkoutWeightUnit) -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SectionTitle("Settings")
        Text("Weight unit", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            WorkoutWeightUnit.entries.forEach { u ->
                val selected = u == unit
                if (selected) {
                    Button(onClick = { onUnitChange(u) }, modifier = Modifier.testTag("workout.unit.${u.raw}")) {
                        Text(u.display)
                    }
                } else {
                    OutlinedButton(onClick = { onUnitChange(u) }, modifier = Modifier.testTag("workout.unit.${u.raw}")) {
                        Text(u.display)
                    }
                }
            }
        }
    }
}

// MARK: - Shared building blocks

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleLarge,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp),
    )
}

@Composable
private fun RowCard(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .padding(16.dp)
            .then(modifier),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

@Composable
private fun EmptyState(title: String, message: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.FitnessCenter, contentDescription = null, tint = Orange, modifier = Modifier.size(40.dp))
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// MARK: - Detail screens

@Composable
private fun ExerciseDetailScreen(exercise: WorkoutExercise, onExit: () -> Unit) {
    ModuleScaffold(title = exercise.name, onExit = onExit) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }
            item { LabeledRow("Category", exercise.category.display) }
            item { LabeledRow("Level", exercise.level.display) }
            exercise.equipment?.let { eq -> item { LabeledRow("Equipment", eq.display) } }
            if (exercise.primaryMuscles.isNotEmpty()) {
                item {
                    LabeledRow("Primary muscles", exercise.primaryMuscles.joinToString(", ") {
                        it.replaceFirstChar(Char::uppercase)
                    })
                }
            }
            if (exercise.instructions.isNotEmpty()) {
                item {
                    Text("Instructions", style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
                }
                itemsIndexed(exercise.instructions) { i, step ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("${i + 1}", color = Orange, fontWeight = FontWeight.Bold)
                        Text(step, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }
    }
}

@Composable
private fun LabeledRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun RoutineDetailScreen(
    routine: WorkoutRoutine,
    resolver: WorkoutResolver,
    onStart: () -> Unit,
    onExit: () -> Unit,
) {
    ModuleScaffold(title = routine.name, onExit = onExit) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                routine.detail?.takeIf { it.isNotBlank() }?.let { detail ->
                    item { Text(detail, style = MaterialTheme.typography.bodyMedium) }
                }
                item {
                    Text(
                        "${routine.exercises.size} exercises · ${routine.totalSets} sets",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
                items(routine.exercises, key = { it.exerciseId + it.reps }) { re ->
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(14.dp),
                    ) {
                        Text(resolver.name(re.exerciseId, re.displayName),
                            style = MaterialTheme.typography.titleMedium, maxLines = 1)
                        Text(
                            "${re.sets} × ${re.reps}" +
                                if (re.restSeconds > 0) " · ${restText(re.restSeconds)} rest" else "",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            Button(
                onClick = onStart,
                enabled = routine.exercises.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().padding(16.dp).testTag("workout.startWorkout"),
            ) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Start Workout")
            }
        }
    }
}

@Composable
private fun SessionDetailScreen(
    session: WorkoutSession,
    resolver: WorkoutResolver,
    unit: WorkoutWeightUnit,
    onExit: () -> Unit,
) {
    ModuleScaffold(title = session.routineName, onExit = onExit) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                Text(
                    "${session.completedSetCount} sets · ${session.completedExerciseCount} exercises",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
            items(session.exercises, key = { it.exerciseId }) { se ->
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(14.dp),
                ) {
                    Text(resolver.name(se.exerciseId, se.displayName),
                        style = MaterialTheme.typography.titleMedium, maxLines = 1)
                    Text(
                        if (se.skipped) "Skipped"
                        else "${se.completedSetCount}/${se.sets.size} sets · target ${se.targetReps}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// MARK: - Dashboard derived stats

private const val DAY_MILLIS = 24L * 60 * 60 * 1000

private fun startOfDay(millis: Long): Long {
    val cal = java.util.Calendar.getInstance()
    cal.timeInMillis = millis
    cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
    cal.set(java.util.Calendar.MINUTE, 0)
    cal.set(java.util.Calendar.SECOND, 0)
    cal.set(java.util.Calendar.MILLISECOND, 0)
    return cal.timeInMillis
}

private fun currentStreak(history: List<WorkoutSession>): Int {
    if (history.isEmpty()) return 0
    val days = history.map { startOfDay(it.startedAt) }.toSet()
    val today = startOfDay(System.currentTimeMillis())
    var cursor = if (days.contains(today)) today else today - DAY_MILLIS
    if (!days.contains(cursor)) return 0
    var count = 0
    while (days.contains(cursor)) {
        count++
        cursor -= DAY_MILLIS
    }
    return count
}

private fun thisWeekCount(history: List<WorkoutSession>): Int {
    val weekStart = startOfDay(System.currentTimeMillis()) - 6 * DAY_MILLIS
    return history.count { it.startedAt >= weekStart }
}

/** "90s" or "1m 30s" for a rest duration. Mirrors iOS `restText`. */
internal fun restText(seconds: Int): String {
    if (seconds < 60) return "${seconds}s"
    val m = seconds / 60
    val s = seconds % 60
    return if (s == 0) "${m}m" else "${m}m ${s}s"
}
