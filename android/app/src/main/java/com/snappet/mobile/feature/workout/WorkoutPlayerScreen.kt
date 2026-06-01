package com.snappet.mobile.feature.workout

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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.delay

private val Orange = Color(0xFFF76808)

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
    persist: (WorkoutSession) -> Unit,
    onFinish: (WorkoutSession, Boolean) -> Unit,
) {
    // Local working copy: list of exercises with their set logs, mutated as the user trains.
    var exercises by remember { mutableStateOf(session.exercises) }
    var phase by remember { mutableStateOf(PlayerPhase.EXERCISE) }
    var exerciseIndex by remember { mutableStateOf(firstPlayable(session.exercises)) }
    var setIndex by remember { mutableStateOf(0) }

    var repsText by remember { mutableStateOf("") }
    var weightText by remember { mutableStateOf("") }
    val unit = defaultUnit

    var restRemaining by remember { mutableStateOf(0) }
    var restTotal by remember { mutableStateOf(0) }

    var showEnd by remember { mutableStateOf(false) }
    var confirmingSkip by remember { mutableStateOf(false) }

    fun save() = persist(session.withExercises(exercises))

    val current = exercises.getOrNull(exerciseIndex)

    // Prefill the rep target whenever we land on a new set.
    LaunchedEffect(exerciseIndex, setIndex, phase) {
        if (phase == PlayerPhase.EXERCISE) {
            val ex = exercises.getOrNull(exerciseIndex)
            repsText = ex?.targetReps?.takeWhile { it.isDigit() }?.ifEmpty { "" } ?: ""
            weightText = ex?.targetWeight?.let { formatWeight(it) } ?: ""
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
                if (exercise.targetRestSeconds > 0) " · ${restText(exercise.targetRestSeconds)} rest" else "",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
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
                val progress = if (total > 0) remaining.toFloat() / total else 0f
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
    Column(
        Modifier.fillMaxSize().padding(padding).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = Orange, modifier = Modifier.size(72.dp))
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

private fun formatWeight(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()

private fun timeString(seconds: Int): String = "%d:%02d".format(seconds / 60, seconds % 60)
