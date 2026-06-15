package com.snappet.mobile.feature.workout

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import kotlinx.coroutines.delay

private val Orange = SnappetAccents.Ember

private enum class PlayerPhase { EXERCISE, REST, DONE }

/**
 * The live workout player: walks the user set-by-set through the session's exercises, runs a rest
 * timer between sets, and shows a summary when done. Works against a local mutable copy of the
 * session, persisting after every set via [persist] and reporting the final state to [onFinish].
 * Mirrors iOS `WorkoutPlayerView` (simplified — no HR overlay / step-back editing).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkoutPlayerScreen(
    session: WorkoutSession,
    resolver: WorkoutResolver,
    defaultUnit: WorkoutWeightUnit,
    history: List<WorkoutSession> = emptyList(),
    persist: (WorkoutSession) -> Unit,
    onFinish: (WorkoutSession, Boolean) -> Unit,
) {
    // Local working copy: list of exercises with their set logs, mutated as the user trains.
    // Deliberately plain remember (issue #86): every completed set is persisted via [persist], so
    // a recreated composition re-derives it from the Room session, not the size-limited Bundle.
    val haptics = com.snappet.mobile.ui.rememberSnappetHaptics()
    var exercises by remember { mutableStateOf(session.exercises) }
    // Fresh entry (no Bundle — e.g. a banner resume of an interrupted session) starts at the first
    // incomplete set, never back over already-logged sets: completeSet() replaces the set at the
    // current position, so a completion-blind start would invite silently overwriting real logs
    // (issue #86 review). All sets complete → straight to the summary.
    val startPosition = remember { firstIncomplete(session.exercises) }
    var phase by rememberSaveable {
        mutableStateOf(if (startPosition == null) PlayerPhase.DONE else PlayerPhase.EXERCISE)
    }
    var exerciseIndex by rememberSaveable {
        mutableStateOf(startPosition?.first ?: firstPlayable(session.exercises))
    }
    var setIndex by rememberSaveable { mutableStateOf(startPosition?.second ?: 0) }

    var repsText by rememberSaveable { mutableStateOf("") }
    var weightText by rememberSaveable { mutableStateOf("") }
    val unit = defaultUnit

    var restRemaining by rememberSaveable { mutableStateOf(0) }
    var restTotal by rememberSaveable { mutableStateOf(0) }

    var showEnd by rememberSaveable { mutableStateOf(false) }
    var confirmingSkip by rememberSaveable { mutableStateOf(false) }

    // Indices restore from the Bundle while `exercises` rebuilds from Room — clamp so a restored
    // position can never point past the rebuilt lists (issue #86). The fallback re-derives the
    // first incomplete position so it also never lands on an already-logged set.
    if (exerciseIndex >= exercises.size) {
        val pos = firstIncomplete(exercises)
        exerciseIndex = pos?.first ?: firstPlayable(exercises)
        setIndex = pos?.second ?: 0
    }
    exercises.getOrNull(exerciseIndex)?.let { ex ->
        if (setIndex >= ex.sets.size) setIndex = (ex.sets.size - 1).coerceAtLeast(0)
    }

    // System back mirrors the top-bar exit: the End/Discard dialog while training, a saving finish
    // from the summary. Always enabled — innermost-wins keeps it above WorkoutRoot's handler, so
    // back can never silently abandon the session (issue #86).
    BackHandler {
        if (phase == PlayerPhase.DONE) onFinish(session.withExercises(exercises), true)
        else showEnd = true
    }

    fun save() = persist(session.withExercises(exercises))

    val current = exercises.getOrNull(exerciseIndex)

    // Prefill the reps/weight fields whenever we land on a new set. The saveable key skips the
    // re-prefill after recreation so restored mid-edit text isn't clobbered (issue #86).
    //
    // Issue #95: carry the value forward instead of discarding it. Priority, most→least specific:
    //   1. the previous *completed* set of this exercise (what the user just lifted 30s ago),
    //   2. the routine's target weight / target reps,
    //   3. the most recent finished session's logged value for this exercise (last-time).
    // Empty targets no longer wipe a typed value the way the old null-target prefill did.
    var prefilledSetKey by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(exerciseIndex, setIndex, phase) {
        if (phase == PlayerPhase.EXERCISE && prefilledSetKey != "$exerciseIndex:$setIndex") {
            prefilledSetKey = "$exerciseIndex:$setIndex"
            val ex = exercises.getOrNull(exerciseIndex)
            val prevSet = ex?.sets?.getOrNull(setIndex - 1)?.takeIf { it.isCompleted }
            val lastTime = ex?.let { WorkoutAnalytics.lastSetFor(history, it.exerciseId) }
            val reps = prevSet?.actualReps
                ?: ex?.targetReps?.takeWhile { c -> c.isDigit() }?.toIntOrNull()
                ?: lastTime?.actualReps
            val weight = prevSet?.actualWeight
                ?: ex?.targetWeight
                ?: lastTime?.actualWeight
            repsText = reps?.toString() ?: ""
            weightText = weight?.let { formatWeight(it) } ?: ""
        }
    }

    fun nextPlayable(after: Int): Int? =
        (after + 1 until exercises.size).firstOrNull { !exercises[it].skipped }

    val isLastSetOfWorkout = run {
        val ex = current
        ex == null || (setIndex >= ex.sets.size - 1 && nextPlayable(exerciseIndex) == null)
    }

    fun advanceExercise() {
        val next = nextPlayable(exerciseIndex)
        if (next != null) {
            exerciseIndex = next
            setIndex = 0
            phase = PlayerPhase.EXERCISE
        } else {
            phase = PlayerPhase.DONE
        }
    }

    fun completeSet() {
        val ex = exercises.getOrNull(exerciseIndex) ?: return
        haptics.commit() // tactile confirmation on set complete (issue #89)
        val reps = repsText.trim().toIntOrNull()
        val weight = weightText.trim().replace(',', '.').toDoubleOrNull()
        val updatedSets = ex.sets.toMutableList()
        if (setIndex in updatedSets.indices) {
            updatedSets[setIndex] = WorkoutSetLog(
                actualReps = reps, actualWeight = weight, weightUnit = unit,
                completedAt = System.currentTimeMillis(),
            )
        }
        val updatedExercises = exercises.toMutableList()
        updatedExercises[exerciseIndex] = ex.copy(sets = updatedSets)
        exercises = updatedExercises
        save()

        if (setIndex + 1 < ex.sets.size) {
            if (ex.targetRestSeconds > 0) {
                restTotal = ex.targetRestSeconds
                restRemaining = ex.targetRestSeconds
                phase = PlayerPhase.REST
            } else {
                setIndex += 1
            }
        } else {
            advanceExercise()
        }
    }

    fun skipRest() {
        setIndex += 1
        phase = PlayerPhase.EXERCISE
    }

    fun skipExercise() {
        val ex = exercises.getOrNull(exerciseIndex) ?: return
        val updated = exercises.toMutableList()
        updated[exerciseIndex] = ex.copy(skipped = true)
        exercises = updated
        save()
        advanceExercise()
    }

    // Rest countdown ticker — advances automatically when it reaches zero.
    LaunchedEffect(phase, restRemaining) {
        if (phase == PlayerPhase.REST) {
            if (restRemaining <= 0) {
                skipRest()
            } else {
                delay(1000)
                if (phase == PlayerPhase.REST) restRemaining -= 1
            }
        }
    }

    ModuleScaffold(
        title = session.routineName,
        onExit = { if (phase == PlayerPhase.DONE) onFinish(session.withExercises(exercises), true) else showEnd = true },
        actions = {
            if (phase != PlayerPhase.DONE) {
                TextButton(onClick = { showEnd = true }, modifier = Modifier.testTag("workout.end")) {
                    Text("End")
                }
            }
        },
    ) { padding ->
        when (phase) {
            PlayerPhase.EXERCISE -> ExercisePhase(
                padding = padding,
                index = exerciseIndex, total = exercises.count { !it.skipped },
                playedSoFar = exercises.take(exerciseIndex).count { !it.skipped } + 1,
                exercise = current, setIndex = setIndex,
                name = current?.let { resolver.name(it.exerciseId, it.displayName) } ?: "",
                lastTimeHint = current?.let { lastTimeHint(history, it.exerciseId, unit) },
                repsText = repsText, onReps = { repsText = it },
                weightText = weightText, onWeight = { weightText = it },
                unit = unit,
                completeLabel = if (isLastSetOfWorkout) "Complete & finish" else "Complete set",
                onComplete = { completeSet() },
                onSkipExercise = { confirmingSkip = true },
            )

            PlayerPhase.REST -> RestPhase(
                padding = padding, remaining = restRemaining, total = restTotal,
                onSkip = { skipRest() },
            )

            PlayerPhase.DONE -> DonePhase(
                padding = padding, routineName = session.routineName,
                sets = exercises.sumOf { it.sets.count { s -> s.isCompleted } },
                exercisesDone = exercises.count { !it.skipped && it.sets.any { s -> s.isCompleted } },
                onFinish = { onFinish(session.withExercises(exercises), true) },
            )
        }
    }

    if (showEnd) {
        AlertDialog(
            onDismissRequest = { showEnd = false },
            title = { Text("End this workout?") },
            confirmButton = {
                TextButton(onClick = {
                    showEnd = false
                    onFinish(session.withExercises(exercises), true)
                }, modifier = Modifier.testTag("workout.saveExit")) { Text("Save & exit") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showEnd = false
                    onFinish(session.withExercises(exercises), false)
                }) { Text("Discard") }
            },
        )
    }

    if (confirmingSkip) {
        AlertDialog(
            onDismissRequest = { confirmingSkip = false },
            title = { Text("Skip this exercise?") },
            confirmButton = {
                TextButton(onClick = { confirmingSkip = false; skipExercise() }) { Text("Skip exercise") }
            },
            dismissButton = {
                TextButton(onClick = { confirmingSkip = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun ExercisePhase(
    padding: PaddingValues,
    index: Int, total: Int, playedSoFar: Int,
    exercise: WorkoutSessionExercise?, setIndex: Int, name: String,
    lastTimeHint: String?,
    repsText: String, onReps: (String) -> Unit,
    weightText: String, onWeight: (String) -> Unit,
    unit: WorkoutWeightUnit,
    completeLabel: String,
    onComplete: () -> Unit,
    onSkipExercise: () -> Unit,
) {
    if (exercise == null) {
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { Text("…") }
        return
    }
    Column(
        Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Exercise $playedSoFar of $total", color = Orange,
            style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
        Text(name, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text("Set ${setIndex + 1} of ${exercise.sets.size}",
            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(
            "Target: ${exercise.targetReps} reps" +
                (exercise.targetWeight?.let { " @ ${formatWeight(it)} ${unit.display}" } ?: "") +
                if (exercise.targetRestSeconds > 0) " · ${restText(exercise.targetRestSeconds)} rest" else "",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (lastTimeHint != null) {
            Text(
                lastTimeHint,
                style = MaterialTheme.typography.bodySmall, color = Orange, fontWeight = FontWeight.Medium,
                modifier = Modifier.testTag("workout.lastTime"),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            OutlinedTextField(
                value = repsText, onValueChange = onReps,
                label = { Text("Reps") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.size(width = 120.dp, height = 64.dp).testTag("workout.reps"),
            )
            OutlinedTextField(
                value = weightText, onValueChange = onWeight,
                label = { Text("Weight (${unit.display})") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.size(width = 150.dp, height = 64.dp).testTag("workout.weight"),
            )
        }
        Button(onClick = onComplete, modifier = Modifier.fillMaxWidth().testTag("workout.completeSet")) {
            Text(completeLabel)
        }
        OutlinedButton(onClick = onSkipExercise, modifier = Modifier.fillMaxWidth().testTag("workout.skipExercise")) {
            Text("Skip exercise")
        }
    }
}

@Composable
private fun RestPhase(padding: PaddingValues, remaining: Int, total: Int, onSkip: () -> Unit) {
    val reduceMotion = LocalReduceMotion.current
    val targetProgress = if (total > 0) remaining.toFloat() / total else 0f
    val progress by animateFloatAsState(
        targetValue = targetProgress,
        animationSpec = gated(reduceMotion, SnappetMotion.quick()),
        label = "workoutRestProgress",
    )
    Column(
        Modifier.fillMaxSize().padding(padding).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Rest", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(24.dp))
        Box(Modifier.size(200.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                val stroke = 14.dp.toPx()
                val inset = stroke / 2
                val arcSize = Size(size.width - stroke, size.height - stroke)
                drawArc(
                    color = Orange.copy(alpha = 0.15f), startAngle = 0f, sweepAngle = 360f, useCenter = false,
                    topLeft = Offset(inset, inset), size = arcSize, style = Stroke(width = stroke),
                )
                drawArc(
                    color = Orange, startAngle = -90f, sweepAngle = 360f * progress, useCenter = false,
                    topLeft = Offset(inset, inset), size = arcSize, style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
            Text(timeString(remaining), fontSize = 40.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(32.dp))
        OutlinedButton(onClick = onSkip, modifier = Modifier.fillMaxWidth().testTag("workout.skipRest")) {
            Text("Skip rest")
        }
    }
}

@Composable
private fun DonePhase(
    padding: PaddingValues, routineName: String, sets: Int, exercisesDone: Int,
    onFinish: () -> Unit,
) {
    // Reduce-motion-gated celebration entrance (issue #89): the check springs in, snaps when the
    // user has minimised animations.
    val reduceMotion = LocalReduceMotion.current
    val haptics = com.snappet.mobile.ui.rememberSnappetHaptics()
    var entered by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (entered) 1f else 0.4f,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "workoutDoneEntrance",
    )
    LaunchedEffect(Unit) { haptics.commit(); entered = true }
    Column(
        Modifier.fillMaxSize().padding(padding).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = Orange,
            modifier = Modifier.size(72.dp).graphicsLayer { scaleX = scale; scaleY = scale })
        Spacer(Modifier.height(16.dp))
        Text("Workout Complete", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text(routineName, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(32.dp)) {
            Stat("$sets", "Sets")
            Stat("$exercisesDone", "Exercises")
        }
        Spacer(Modifier.height(32.dp))
        Button(onClick = onFinish, modifier = Modifier.fillMaxWidth().testTag("workout.finish")) {
            Text("Finish")
        }
    }
}

@Composable
private fun Stat(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun firstPlayable(exercises: List<WorkoutSessionExercise>): Int =
    exercises.indexOfFirst { !it.skipped }.coerceAtLeast(0)

/** The first non-skipped exercise with an incomplete set, and that set's index — where a resumed
 *  session continues. Null when every non-skipped set is already logged (issue #86 review). */
private fun firstIncomplete(exercises: List<WorkoutSessionExercise>): Pair<Int, Int>? {
    exercises.forEachIndexed { i, ex ->
        if (!ex.skipped) {
            val s = ex.sets.indexOfFirst { !it.isCompleted }
            if (s >= 0) return i to s
        }
    }
    return null
}

private fun formatWeight(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()

/**
 * "Last time: 60 kg × 8" from the most recent finished session that logged this exercise, or null
 * when there's no history for it (issue #95). Pure-ish (reads only the passed history).
 */
internal fun lastTimeHint(
    history: List<WorkoutSession>, exerciseId: String, fallbackUnit: WorkoutWeightUnit,
): String? {
    val last = WorkoutAnalytics.lastSetFor(history, exerciseId) ?: return null
    val reps = last.actualReps
    val weight = last.actualWeight
    val unit = last.weightUnit ?: fallbackUnit
    return when {
        weight != null && reps != null -> "Last time: ${formatWeight(weight)} ${unit.display} × $reps"
        reps != null -> "Last time: $reps reps"
        weight != null -> "Last time: ${formatWeight(weight)} ${unit.display}"
        else -> null
    }
}

private fun timeString(seconds: Int): String = "%d:%02d".format(seconds / 60, seconds % 60)
