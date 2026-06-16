package com.snappet.mobile.feature.workout

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.filled.Delete
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.SnappetAccents
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit

private val Orange = SnappetAccents.Ember

private enum class WorkoutScreen {
    ROOT, EXERCISE_DETAIL, ROUTINE_DETAIL, PLAYER, SESSION_DETAIL,
    ROUTINE_EDITOR, EXERCISE_PICKER, CUSTOM_EXERCISE_EDITOR,
}
private enum class WorkoutSection(val title: String) {
    EXERCISES("Exercises"), ROUTINES("Routines"), HISTORY("History"), SETTINGS("Settings")
}

/**
 * Root entry for the Workout Tracker mini-app (module id `workout-log`). A dashboard with headline
 * stats sits above a 4-way section selector (Exercises / Routines / History / Settings). Deeper
 * screens — exercise detail, routine detail, the live player and session detail — are managed with
 * local navigation state, each in its own [ModuleScaffold]. An interrupted active session surfaces
 * a Resume/Discard banner above the selector (issue #86). Mirrors iOS `WorkoutHomeView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkoutRoot(onExit: () -> Unit) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val dao = container.database.workoutDao()
    val core = container.core
    val scope = rememberCoroutineScope()

    // Null until Room's first emission. A sub-screen restored by rotation / process death / tab
    // retention composes before that emission; the row-gone guards in the `when` below must not
    // self-heal to ROOT against a list that simply hasn't loaded yet (issue #86).
    val routinesOrNull by dao.routinesFlow().collectAsState(initial = null)
    val sessionsOrNull by dao.sessionsFlow().collectAsState(initial = null)
    val customExercisesOrNull by dao.customExercisesFlow().collectAsState(initial = null)
    val routines = routinesOrNull ?: emptyList()
    val sessions = sessionsOrNull ?: emptyList()
    val customExercises = customExercisesOrNull ?: emptyList()

    var unit by rememberSaveable { mutableStateOf(WorkoutSettings.preferredUnit(context)) }
    var screen by rememberSaveable { mutableStateOf(WorkoutScreen.ROOT) }
    // Open on Routines (issue #95): starting a workout was buried behind the read-only Exercises
    // catalog. Routines is where the daily loop begins.
    var section by rememberSaveable { mutableStateOf(WorkoutSection.ROUTINES) }

    var selectedExerciseId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedRoutineRow by rememberSaveable { mutableStateOf<Long?>(null) }
    var selectedSessionRow by rememberSaveable { mutableStateOf<Long?>(null) }
    var playingSessionRow by rememberSaveable { mutableStateOf<Long?>(null) }

    // Routine-authoring draft (issue #87). Held in plain state (the draft-line list isn't trivially
    // Bundle-able and editing is a transient flow); navigation position is still saveable. The row
    // id being edited is null for a brand-new routine. The draft survives a round-trip into the
    // exercise picker so picking appends a line and returns to the editor.
    var editorName by remember { mutableStateOf("") }
    var editorLines by remember { mutableStateOf<List<RoutineDraftExercise>>(emptyList()) }
    var editingRoutineRow by remember { mutableStateOf<Long?>(null) }
    // True when the custom-exercise editor was opened from the picker (mid-authoring) vs. standalone
    // from the Exercises section — governs where Save returns and whether a routine line is appended.
    var cameFromPickerForCustom by rememberSaveable { mutableStateOf(false) }

    // System back pops one level (issue #86). Disabled at ROOT so back falls through to the
    // app-level NavHost, and for PLAYER, which registers its own handler (End/Discard dialog;
    // innermost-wins keeps it above this one anyway).
    BackHandler(
        enabled = screen == WorkoutScreen.EXERCISE_DETAIL ||
            screen == WorkoutScreen.ROUTINE_DETAIL ||
            screen == WorkoutScreen.SESSION_DETAIL ||
            screen == WorkoutScreen.ROUTINE_EDITOR ||
            screen == WorkoutScreen.CUSTOM_EXERCISE_EDITOR,
    ) { screen = WorkoutScreen.ROOT }
    // The picker pops back into the editor (it's a sub-step of authoring), not all the way to ROOT.
    BackHandler(enabled = screen == WorkoutScreen.EXERCISE_PICKER) { screen = WorkoutScreen.ROUTINE_EDITOR }

    // Flips true once the full bundled catalog (~873 exercises) is parsed in, recomposing the
    // catalog below off the curated subset. The picker / browse search work either way (#87).
    var catalogLoaded by remember { mutableStateOf(WorkoutCatalog.isFullyLoaded) }

    val resolver = remember(customExercises, catalogLoaded) { WorkoutResolver(customExercises) }
    val history = remember(sessions) { sessions.filter { !it.isActive } }
    val activeSessions = remember(sessions) { sessions.filter { it.isActive } }
    val catalog = remember(customExercises, catalogLoaded) {
        (WorkoutCatalog.all + customExercises.map { it.asExercise() }).sortedBy { it.name.lowercase() }
    }

    // Seed starter routines on first open if the store is empty, and parse the bundled catalog.
    LaunchedEffect(Unit) {
        WorkoutStarters.seedIfNeeded(dao, WorkoutSettings.dismissedStarters(context))
        WorkoutCatalog.load(context)
        catalogLoaded = WorkoutCatalog.isFullyLoaded
    }

    val selectedExercise = selectedExerciseId?.let { id -> catalog.firstOrNull { it.id == id } }
    val selectedRoutine = routines.firstOrNull { it.id == selectedRoutineRow }
    val selectedSession = sessions.firstOrNull { it.id == selectedSessionRow }
    val playingSession = sessions.firstOrNull { it.id == playingSessionRow }

    // Issue #86 resume policy: an unfinished session (finishedAt == null) is only ever finalized
    // by the user — resumed and finished, or explicitly discarded — never auto-deleted, never
    // auto-finished. Surface the newest; resuming/discarding it reveals the next. Suppressed while
    // playingSessionRow is set so the session being finalized never flashes a banner.
    val resumableSession =
        if (playingSessionRow == null) activeSessions.maxByOrNull { it.startedAt } else null

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

    // --- Routine authoring (issue #87) -------------------------------------

    fun draftFrom(routine: WorkoutRoutine): List<RoutineDraftExercise> =
        routine.exercises.map { re ->
            RoutineDraftExercise(
                exerciseId = re.exerciseId,
                displayName = resolver.name(re.exerciseId, re.displayName),
                sets = re.sets, reps = re.reps, restSeconds = re.restSeconds, weight = re.weight,
            )
        }

    fun openNewRoutine() {
        editingRoutineRow = null
        editorName = ""
        editorLines = emptyList()
        screen = WorkoutScreen.ROUTINE_EDITOR
    }

    fun openEditRoutine(routine: WorkoutRoutine) {
        editingRoutineRow = routine.id
        editorName = routine.name
        editorLines = draftFrom(routine)
        screen = WorkoutScreen.ROUTINE_EDITOR
    }

    fun openDuplicateRoutine(routine: WorkoutRoutine) {
        editingRoutineRow = null // a duplicate is a brand-new routine
        editorName = "${routine.name} copy"
        editorLines = draftFrom(routine)
        screen = WorkoutScreen.ROUTINE_EDITOR
    }

    fun saveRoutine(name: String, lines: List<RoutineDraftExercise>) {
        val exercises = lines.map { it.toRoutineExercise() }
        val existing = editingRoutineRow?.let { row -> routines.firstOrNull { it.id == row } }
        scope.launch {
            if (existing != null) {
                dao.updateRoutine(
                    existing.copy(
                        name = name,
                        exercisesJson = WorkoutJson.encodeRoutineExercises(exercises),
                        updatedAt = System.currentTimeMillis(),
                    ),
                )
            } else {
                dao.insertRoutine(WorkoutRoutine.create(name = name, exercises = exercises))
            }
        }
        screen = WorkoutScreen.ROOT
        section = WorkoutSection.ROUTINES
    }

    when (screen) {
        WorkoutScreen.EXERCISE_DETAIL -> {
            val ex = selectedExercise
            if (ex == null) { if (customExercisesOrNull != null) screen = WorkoutScreen.ROOT }
            else ExerciseDetailScreen(ex, history, unit, onExit = { screen = WorkoutScreen.ROOT })
        }

        WorkoutScreen.ROUTINE_DETAIL -> {
            val r = selectedRoutine
            if (r == null) { if (routinesOrNull != null) screen = WorkoutScreen.ROOT }
            else RoutineDetailScreen(
                routine = r, resolver = resolver, unit = unit,
                onStart = { startWorkout(r) },
                onEdit = { openEditRoutine(r) },
                onDuplicate = { openDuplicateRoutine(r) },
                onDelete = {
                    // Tombstone a starter so seedIfNeeded can't resurrect it (review fix).
                    r.starterKey?.let { WorkoutSettings.dismissStarter(context, it) }
                    scope.launch { dao.deleteRoutine(r) }
                    screen = WorkoutScreen.ROOT
                },
                onExit = { screen = WorkoutScreen.ROOT },
            )
        }

        WorkoutScreen.SESSION_DETAIL -> {
            val s = selectedSession
            if (s == null) { if (sessionsOrNull != null) screen = WorkoutScreen.ROOT }
            else SessionDetailScreen(
                s, resolver, unit,
                onDelete = {
                    scope.launch { dao.deleteSession(s) }
                    screen = WorkoutScreen.ROOT
                },
                onExit = { screen = WorkoutScreen.ROOT },
            )
        }

        WorkoutScreen.PLAYER -> {
            val s = playingSession
            if (s == null) {
                // Row genuinely gone (vs. not yet loaded): clear the id too so the resume banner
                // isn't suppressed by a dangling reference (issue #86).
                if (sessionsOrNull != null) {
                    playingSessionRow = null
                    screen = WorkoutScreen.ROOT
                }
            } else {
                WorkoutPlayerScreen(
                    session = s, resolver = resolver, defaultUnit = unit, history = history,
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

        WorkoutScreen.ROUTINE_EDITOR -> RoutineEditorScreen(
            titleText = if (editingRoutineRow != null) "Edit routine" else "New routine",
            name = editorName,
            exercises = editorLines,
            unit = unit,
            // Hoist the FULL working state (name + every per-line edit) into the host on each change,
            // so a round-trip into the exercise picker preserves it (review fix).
            onNameChange = { editorName = it },
            onLinesChange = { editorLines = it },
            onAddExercise = { screen = WorkoutScreen.EXERCISE_PICKER },
            onSave = { name, lines -> saveRoutine(name, lines) },
            onExit = { screen = WorkoutScreen.ROOT },
        )

        WorkoutScreen.EXERCISE_PICKER -> ExercisePickerScreen(
            catalog = catalog,
            onPick = { ex ->
                editorLines = editorLines + RoutineDraftExercise(
                    exerciseId = ex.id, displayName = ex.name,
                )
                screen = WorkoutScreen.ROUTINE_EDITOR
            },
            onCreateCustom = { cameFromPickerForCustom = true; screen = WorkoutScreen.CUSTOM_EXERCISE_EDITOR },
            onExit = { screen = WorkoutScreen.ROUTINE_EDITOR },
        )

        WorkoutScreen.CUSTOM_EXERCISE_EDITOR -> ExerciseEditorScreen(
            onSave = { custom ->
                scope.launch { dao.insertCustomExercise(custom) }
                if (cameFromPickerForCustom) {
                    // Authoring a routine: drop the new exercise in as a line and return to the editor.
                    editorLines = editorLines + RoutineDraftExercise(
                        exerciseId = custom.exerciseId, displayName = custom.name,
                    )
                    screen = WorkoutScreen.ROUTINE_EDITOR
                } else {
                    // Standalone: it just joins the catalog (root merges customExercisesFlow).
                    screen = WorkoutScreen.ROOT
                }
            },
            onExit = { screen = if (cameFromPickerForCustom) WorkoutScreen.EXERCISE_PICKER else WorkoutScreen.ROOT },
        )

        WorkoutScreen.ROOT -> ModuleScaffold(title = "Workout", onExit = onExit) { padding ->
            RootContent(
                padding = padding,
                section = section,
                onSection = { section = it },
                history = history,
                activeSession = resumableSession,
                onResumeActive = { playingSessionRow = it.id; screen = WorkoutScreen.PLAYER },
                onDiscardActive = { session -> scope.launch { dao.deleteSession(session) } },
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
                onNewRoutine = { openNewRoutine() },
                onStartRoutine = { startWorkout(it) },
                onCreateCustomExercise = { cameFromPickerForCustom = false; screen = WorkoutScreen.CUSTOM_EXERCISE_EDITOR },
                onDeleteCustomExercise = { custom -> scope.launch { dao.deleteCustomExercise(custom) } },
                customExercises = customExercises,
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
    activeSession: WorkoutSession?,
    onResumeActive: (WorkoutSession) -> Unit,
    onDiscardActive: (WorkoutSession) -> Unit,
    routines: List<WorkoutRoutine>,
    catalog: List<WorkoutExercise>,
    resolver: WorkoutResolver,
    unit: WorkoutWeightUnit,
    onUnitChange: (WorkoutWeightUnit) -> Unit,
    onOpenExercise: (WorkoutExercise) -> Unit,
    onOpenRoutine: (WorkoutRoutine) -> Unit,
    onOpenSession: (WorkoutSession) -> Unit,
    onNewRoutine: () -> Unit,
    onStartRoutine: (WorkoutRoutine) -> Unit,
    onCreateCustomExercise: () -> Unit,
    onDeleteCustomExercise: (WorkoutCustomExercise) -> Unit,
    customExercises: List<WorkoutCustomExercise>,
) {
    Column(Modifier.fillMaxSize().padding(padding)) {
        DashboardStrip(history)
        if (activeSession != null) {
            ActiveSessionBanner(
                session = activeSession,
                onResume = { onResumeActive(activeSession) },
                onDiscard = { onDiscardActive(activeSession) },
            )
        }
        SectionSelector(section, onSection)
        when (section) {
            WorkoutSection.EXERCISES -> ExercisesSection(catalog, customExercises, onOpenExercise, onCreateCustomExercise, onDeleteCustomExercise)
            WorkoutSection.ROUTINES -> RoutinesSection(routines, history, resolver, onOpenRoutine, onStartRoutine, onNewRoutine)
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
    // Volume trend + PRs (issue #95) — only once there's any logged tonnage to show.
    val weekly = remember(history) { WorkoutAnalytics.weeklyVolume(history, System.currentTimeMillis()) }
    val prs = remember(history) { WorkoutAnalytics.personalRecords(history) }
    if (weekly.any { it.volumeKg > 0 }) {
        VolumeTrendChart(weekly)
    }
    if (prs.isNotEmpty()) {
        PersonalRecordsStrip(prs)
    }
}

/** An 8-week tonnage bar chart (kg). Mirrors the iOS dashboard's volume chart. */
@Composable
private fun VolumeTrendChart(weeks: List<WorkoutAnalytics.WeeklyVolume>) {
    val max = (weeks.maxOfOrNull { it.volumeKg } ?: 0.0).coerceAtLeast(1.0)
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).testTag("workout.volumeChart"),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("Weekly volume (kg)", style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(
            Modifier.fillMaxWidth().height(80.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            weeks.forEach { w ->
                val frac = (w.volumeKg / max).toFloat().coerceIn(0f, 1f)
                Box(
                    Modifier
                        .weight(1f)
                        .androidFractionHeight(frac)
                        .clip(RoundedCornerShape(topStart = 4.dp, topEnd = 4.dp))
                        .background(Orange.copy(alpha = if (w.volumeKg > 0) 0.85f else 0.18f)),
                )
            }
        }
    }
}

/** Modifier helper: a bar's height as a fraction of the row, with a small floor so empty reads. */
private fun Modifier.androidFractionHeight(fraction: Float): Modifier =
    this.fillMaxHeight(fraction.coerceAtLeast(0.04f))

@Composable
private fun PersonalRecordsStrip(prs: List<WorkoutAnalytics.PersonalRecord>) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).testTag("workout.prs"),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("Personal records", style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        prs.take(3).forEach { pr ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    pr.displayName ?: pr.exerciseId.replace('_', ' '),
                    style = MaterialTheme.typography.bodyMedium, maxLines = 1, modifier = Modifier.weight(1f),
                )
                Text(
                    "${formatTarget(pr.weight)} ${pr.unit.display} × ${pr.reps}",
                    style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = Orange,
                )
            }
        }
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

// MARK: - Active-session resume banner

/**
 * Issue #86: an interrupted session (`finishedAt == null`) is hidden from History and used to be
 * unrecoverable. The banner offers Resume (back into the player) or Discard (confirmed delete) —
 * the only two ways an unfinished session is ever finalized.
 */
@Composable
private fun ActiveSessionBanner(
    session: WorkoutSession,
    onResume: () -> Unit,
    onDiscard: () -> Unit,
) {
    var confirmingDiscard by remember { mutableStateOf(false) }
    if (confirmingDiscard) {
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Discard this workout?",
            message = "\u201C${session.routineName}\u201D and its logged sets are deleted.",
            confirmLabel = "Discard",
            onConfirm = { confirmingDiscard = false; onDiscard() },
            onDismiss = { confirmingDiscard = false },
        )
    }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Orange.copy(alpha = 0.12f))
            .padding(14.dp)
            .testTag("workout.resumeBanner"),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("Active workout", style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold, color = Orange)
        Text(session.routineName, style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold, maxLines = 1)
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(onClick = onResume, modifier = Modifier.testTag("workout.resume")) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Resume")
            }
            TextButton(onClick = { confirmingDiscard = true }, modifier = Modifier.testTag("workout.discardActive")) {
                Text("Discard")
            }
        }
    }
}

// MARK: - Exercises section (search + custom create/delete — issue #87)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ExercisesSection(
    catalog: List<WorkoutExercise>,
    customExercises: List<WorkoutCustomExercise>,
    onOpen: (WorkoutExercise) -> Unit,
    onCreateCustom: () -> Unit,
    onDeleteCustom: (WorkoutCustomExercise) -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    val results = remember(catalog, query) { WorkoutExerciseParser.search(catalog, query) }
    val customById = remember(customExercises) { customExercises.associateBy { it.exerciseId } }
    var confirmingDelete by remember { mutableStateOf<WorkoutCustomExercise?>(null) }

    confirmingDelete?.let { custom ->
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete “${custom.name}”?",
            message = "Routines that reference it keep the name; new pickers won't show it.",
            onConfirm = { onDeleteCustom(custom); confirmingDelete = null },
            onDismiss = { confirmingDelete = null },
        )
    }

    Column(Modifier.fillMaxSize()) {
        androidx.compose.material3.OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                .testTag("workout.exercises.search"),
            placeholder = { Text("Search ${catalog.size} exercises") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (query.isNotEmpty()) {
                    IconButton(onClick = { query = "" }, modifier = Modifier.testTag("workout.exercises.search.clear")) {
                        Icon(Icons.Filled.Clear, contentDescription = "Clear search")
                    }
                }
            },
        )
        LazyColumn(
            Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    SectionTitle("Exercises")
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onCreateCustom, modifier = Modifier.testTag("workout.exercises.createCustom")) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text(" Custom")
                    }
                }
            }
            if (results.isEmpty()) {
                item {
                    TextButton(onClick = onCreateCustom, modifier = Modifier.testTag("workout.exercises.createCustom.empty")) {
                        Icon(Icons.Filled.Add, contentDescription = null)
                        Text("  Create “$query”")
                    }
                }
            }
            items(results, key = { it.id }) { ex ->
                val custom = customById[ex.id]
                RowCard(
                    onClick = { onOpen(ex) },
                    modifier = Modifier.testTag("exerciseRow"),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(ex.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        Text(ex.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (custom != null) {
                        IconButton(onClick = { confirmingDelete = custom }, modifier = Modifier.testTag("workout.exercises.deleteCustom")) {
                            Icon(Icons.Filled.Delete, contentDescription = "Delete ${ex.name}")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Routines section (one-tap start + repeat-last + new — issues #87 & #95)

@Composable
private fun RoutinesSection(
    routines: List<WorkoutRoutine>,
    history: List<WorkoutSession>,
    resolver: WorkoutResolver,
    onOpen: (WorkoutRoutine) -> Unit,
    onStart: (WorkoutRoutine) -> Unit,
    onNew: () -> Unit,
) {
    // Repeat-last card (#95): the routine behind the most recent finished session, one-tap restart.
    val lastRoutine = remember(routines, history) {
        history.maxByOrNull { it.startedAt }?.let { last ->
            routines.firstOrNull { it.routineId == last.routineId || it.name == last.routineName }
        }
    }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                SectionTitle("Routines")
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onNew, modifier = Modifier.testTag("workout.routines.new")) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text(" New")
                }
            }
        }
        if (lastRoutine != null) {
            item {
                Column(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(Orange.copy(alpha = 0.12f))
                        .padding(14.dp)
                        .testTag("workout.repeatLast"),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text("Pick up where you left off", style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold, color = Orange)
                    Text(lastRoutine.name, style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Button(onClick = { onStart(lastRoutine) }, modifier = Modifier.testTag("workout.repeatLast.start")) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text("Repeat ${lastRoutine.name}")
                    }
                }
            }
        }
        if (routines.isEmpty()) {
            item { EmptyState("No routines yet", "Tap New to build one, or starters load on first open.") }
        }
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
                IconButton(
                    onClick = { onStart(r) },
                    enabled = r.exercises.isNotEmpty(),
                    modifier = Modifier.testTag("workout.routine.start"),
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = "Start ${r.name}", tint = Orange)
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
private fun ExerciseDetailScreen(
    exercise: WorkoutExercise,
    history: List<WorkoutSession>,
    unit: WorkoutWeightUnit,
    onExit: () -> Unit,
) {
    val progress = remember(history, exercise.id) {
        WorkoutAnalytics.exerciseProgress(history, exercise.id)
    }
    ModuleScaffold(title = exercise.name, onExit = onExit) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }
            if (progress.isNotEmpty()) {
                item {
                    Text("Progress", style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 4.dp))
                }
                item { ExerciseProgressChart(progress, unit) }
            }
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

/** Best-set-weight-over-time bars for one exercise (issue #95). Mirrors iOS `ExerciseProgressView`. */
@Composable
private fun ExerciseProgressChart(points: List<WorkoutAnalytics.ProgressPoint>, unit: WorkoutWeightUnit) {
    val max = (points.maxOfOrNull { it.weight } ?: 0.0).coerceAtLeast(1.0)
    val best = points.maxByOrNull { it.weight }
    Column(
        Modifier.fillMaxWidth().testTag("workout.progressChart"),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        best?.let {
            Text("Best: ${formatTarget(it.weight)} ${it.unit.display} × ${it.reps}",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Row(
            Modifier.fillMaxWidth().height(72.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            points.takeLast(12).forEach { p ->
                val frac = (p.weight / max).toFloat().coerceIn(0f, 1f)
                Box(
                    Modifier
                        .weight(1f)
                        .androidFractionHeight(frac)
                        .clip(RoundedCornerShape(topStart = 3.dp, topEnd = 3.dp))
                        .background(Orange.copy(alpha = 0.8f)),
                )
            }
        }
    }
}

@Composable
private fun RoutineDetailScreen(
    routine: WorkoutRoutine,
    resolver: WorkoutResolver,
    unit: WorkoutWeightUnit,
    onStart: () -> Unit,
    onEdit: () -> Unit,
    onDuplicate: () -> Unit,
    onDelete: () -> Unit,
    onExit: () -> Unit,
) {
    // Issue #88: routines are deletable (starters can be re-seeded; custom ones were stuck forever).
    var confirmingDelete by remember { mutableStateOf(false) }
    if (confirmingDelete) {
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete \u201C${routine.name}\u201D?",
            message = "Past sessions you ran from it stay in History.",
            onConfirm = { confirmingDelete = false; onDelete() },
            onDismiss = { confirmingDelete = false },
        )
    }
    ModuleScaffold(title = routine.name, onExit = onExit, actions = {
        IconButton(onClick = onEdit, modifier = Modifier.testTag("workout.editRoutine")) {
            Icon(Icons.Filled.Edit, contentDescription = "Edit routine")
        }
        IconButton(onClick = onDuplicate, modifier = Modifier.testTag("workout.duplicateRoutine")) {
            Icon(Icons.Filled.ContentCopy, contentDescription = "Duplicate routine")
        }
        IconButton(onClick = { confirmingDelete = true }, modifier = Modifier.testTag("workout.deleteRoutine")) {
            Icon(Icons.Filled.Delete, contentDescription = "Delete routine")
        }
    }) { padding ->
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
                                (re.weight?.let { " @ ${formatTarget(it)} ${unit.display}" } ?: "") +
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
    onDelete: () -> Unit,
    onExit: () -> Unit,
) {
    // Issue #88: a finished session is deletable; dashboard stats recompute from what's left.
    var confirmingDelete by remember { mutableStateOf(false) }
    if (confirmingDelete) {
        com.snappet.mobile.ui.ConfirmDeleteDialog(
            title = "Delete this session?",
            message = "It's removed from History and your stats recompute.",
            onConfirm = { confirmingDelete = false; onDelete() },
            onDismiss = { confirmingDelete = false },
        )
    }
    ModuleScaffold(title = session.routineName, onExit = onExit, actions = {
        IconButton(onClick = { confirmingDelete = true }, modifier = Modifier.testTag("workout.deleteSession")) {
            Icon(Icons.Filled.Delete, contentDescription = "Delete session")
        }
    }) { padding ->
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
                        .padding(14.dp)
                        .testTag("workout.session.exercise"),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(resolver.name(se.exerciseId, se.displayName),
                        style = MaterialTheme.typography.titleMedium, maxLines = 1)
                    Text(
                        if (se.skipped) "Skipped"
                        else "${se.completedSetCount}/${se.sets.size} sets · target ${se.targetReps}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    // Per-set actuals (issue #95): the data was persisted but never shown.
                    if (!se.skipped) {
                        se.sets.forEachIndexed { i, set ->
                            if (set.isCompleted) {
                                Text(
                                    "Set ${i + 1}: ${setSummary(set, unit)}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.testTag("workout.session.setRow"),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dashboard derived stats

private fun startOfDay(millis: Long): Long {
    val cal = java.util.Calendar.getInstance()
    cal.timeInMillis = millis
    cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
    cal.set(java.util.Calendar.MINUTE, 0)
    cal.set(java.util.Calendar.SECOND, 0)
    cal.set(java.util.Calendar.MILLISECOND, 0)
    return cal.timeInMillis
}

internal fun currentStreak(history: List<WorkoutSession>): Int =
    currentStreakAt(history, System.currentTimeMillis())

/**
 * Day-streak ending at [now]. Steps the cursor back one *calendar* day at a time
 * (`WorkoutAnalytics.addDays`) instead of subtracting a fixed 24h, so a 23h/25h DST day never
 * skips or double-counts a day (DST fix). [now]-injectable for unit tests.
 */
internal fun currentStreakAt(history: List<WorkoutSession>, now: Long): Int {
    if (history.isEmpty()) return 0
    val days = history.map { startOfDay(it.startedAt) }.toSet()
    val today = startOfDay(now)
    var cursor = if (days.contains(today)) today else startOfDay(WorkoutAnalytics.addDays(today, -1))
    if (!days.contains(cursor)) return 0
    var count = 0
    while (days.contains(cursor)) {
        count++
        cursor = startOfDay(WorkoutAnalytics.addDays(cursor, -1))
    }
    return count
}

internal fun thisWeekCount(history: List<WorkoutSession>): Int =
    thisWeekCountAt(history, System.currentTimeMillis())

/** Count of sessions in the trailing 7 calendar days ending at [now] (DST-correct day step). */
internal fun thisWeekCountAt(history: List<WorkoutSession>, now: Long): Int {
    val weekStart = startOfDay(WorkoutAnalytics.addDays(startOfDay(now), -6))
    return history.count { it.startedAt >= weekStart }
}

/**
 * A logged set's summary, e.g. "8 reps × 60 kg" or "12 reps" (bodyweight). Shown in the set's own
 * unit if it carries one, else the screen's [fallbackUnit]. Pure — unit-tested (issue #95).
 */
internal fun setSummary(set: WorkoutSetLog, fallbackUnit: WorkoutWeightUnit): String {
    val reps = set.actualReps
    val weight = set.actualWeight
    val unit = set.weightUnit ?: fallbackUnit
    return when {
        reps != null && weight != null -> "$reps reps × ${formatTarget(weight)} ${unit.display}"
        reps != null -> "$reps reps"
        weight != null -> "${formatTarget(weight)} ${unit.display}"
        else -> "Done"
    }
}

/** "90s" or "1m 30s" for a rest duration. Mirrors iOS `restText`. */
internal fun restText(seconds: Int): String {
    if (seconds < 60) return "${seconds}s"
    val m = seconds / 60
    val s = seconds % 60
    return if (s == 0) "${m}m" else "${m}m ${s}s"
}
