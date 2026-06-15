package com.snappet.mobile.feature.workout

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.SnappetAccents

private val Orange = SnappetAccents.Ember

/**
 * Authoring surfaces for the Workout Tracker (issue #87): create / edit a routine, pick exercises
 * from the full bundled catalog, and create a custom exercise. The data layer (DAO mutators +
 * `WorkoutCustomExercise` entity) already existed and had no caller — these screens are its UI.
 * Each is a full [ModuleScaffold] screen, navigated from [WorkoutRoot] via its local screen enum,
 * so state survives rotation the same way the rest of the module does. Mirrors the iOS
 * `RoutineEditorView` / `ExercisePickerView` / `ExerciseEditorView` sheets.
 */

// MARK: - A routine being edited (a Bundle-able draft, decoupled from the persisted entity)

/**
 * One exercise line in the routine editor. `weight` is an optional target (issue #95 prefill leans
 * on it). Mirrors [WorkoutRoutineExercise] but mutable-friendly for the form.
 */
internal data class RoutineDraftExercise(
    val exerciseId: String,
    val displayName: String,
    val sets: Int = 3,
    val reps: String = "10",
    val restSeconds: Int = 60,
    val weight: Double? = null,
) {
    fun toRoutineExercise() = WorkoutRoutineExercise(
        exerciseId = exerciseId, sets = sets, reps = reps,
        restSeconds = restSeconds, weight = weight, displayName = displayName,
    )
}

// MARK: - Exercise picker (full bundled catalog + search)

/**
 * Search the full catalog (~873 bundled + any custom) and pick an exercise. Returns the chosen
 * [WorkoutExercise] via [onPick]; the routine editor turns it into a draft line. Search is the pure
 * [WorkoutExerciseParser.search] over name / muscle / equipment / category.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ExercisePickerScreen(
    catalog: List<WorkoutExercise>,
    onPick: (WorkoutExercise) -> Unit,
    onCreateCustom: () -> Unit,
    onExit: () -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    val results = remember(catalog, query) { WorkoutExerciseParser.search(catalog, query) }

    ModuleScaffold(
        title = "Add exercise",
        onExit = onExit,
        actions = {
            IconButton(onClick = onCreateCustom, modifier = Modifier.testTag("workout.picker.createCustom")) {
                Icon(Icons.Filled.Add, contentDescription = "Create custom exercise")
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                    .testTag("workout.picker.search"),
                placeholder = { Text("Search ${catalog.size} exercises") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = {
                    if (query.isNotEmpty()) {
                        IconButton(onClick = { query = "" }, modifier = Modifier.testTag("workout.picker.search.clear")) {
                            Icon(Icons.Filled.Clear, contentDescription = "Clear search")
                        }
                    }
                },
            )
            if (results.isEmpty()) {
                Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("No exercises match “$query”", style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = onCreateCustom, modifier = Modifier.testTag("workout.picker.createCustom.empty")) {
                            Icon(Icons.Filled.Add, contentDescription = null)
                            Text("  Create “$query”")
                        }
                    }
                }
            } else {
                LazyColumn(
                    Modifier.fillMaxSize().padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(results, key = { it.id }) { ex ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(14.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .clickable { onPick(ex) }
                                .padding(16.dp)
                                .testTag("workout.picker.row"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(ex.name, style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold, maxLines = 1)
                                Text(ex.subtitle, style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(Icons.Filled.Add, contentDescription = "Add ${ex.name}", tint = Orange)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Routine editor (create / edit)

/**
 * Create or edit a routine: a name + an ordered list of exercise lines (sets × reps, rest, optional
 * target weight), with add / remove. [initial] is null for a new routine, or the existing rows when
 * editing. On Save, [onSave] receives the assembled name + lines; the host persists.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RoutineEditorScreen(
    titleText: String,
    initialName: String,
    initialExercises: List<RoutineDraftExercise>,
    unit: WorkoutWeightUnit,
    onAddExercise: () -> Unit,
    onSave: (String, List<RoutineDraftExercise>) -> Unit,
    onExit: () -> Unit,
) {
    var name by rememberSaveable { mutableStateOf(initialName) }
    // The draft lines are held by the host (they need to survive a round-trip into the picker), so
    // this screen receives them as [initialExercises] and edits in place via [onSave] on commit.
    var lines by remember { mutableStateOf(initialExercises) }

    fun update(index: Int, transform: (RoutineDraftExercise) -> RoutineDraftExercise) {
        lines = lines.toMutableList().also { it[index] = transform(it[index]) }
    }

    ModuleScaffold(
        title = titleText,
        onExit = onExit,
        actions = {
            TextButton(
                onClick = { onSave(name.trim(), lines) },
                enabled = name.isNotBlank() && lines.isNotEmpty(),
                modifier = Modifier.testTag("workout.editor.save"),
            ) { Text("Save") }
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }
            item {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Routine name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("workout.editor.name"),
                )
            }
            item {
                Text("Exercises", style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
            }
            if (lines.isEmpty()) {
                item {
                    Text("No exercises yet — add one below.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            items(lines.size) { index ->
                val line = lines[index]
                Column(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(14.dp)
                        .testTag("workout.editor.line"),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(line.displayName, style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f))
                        IconButton(
                            onClick = { lines = lines.toMutableList().also { it.removeAt(index) } },
                            modifier = Modifier.testTag("workout.editor.removeLine"),
                        ) { Icon(Icons.Filled.Delete, contentDescription = "Remove ${line.displayName}") }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        SmallNumberField(
                            label = "Sets", value = line.sets.toString(), tag = "workout.editor.sets",
                            modifier = Modifier.weight(1f),
                        ) { update(index) { e -> e.copy(sets = it.toIntOrNull()?.coerceIn(1, 20) ?: e.sets) } }
                        SmallTextField(
                            label = "Reps", value = line.reps, tag = "workout.editor.reps",
                            modifier = Modifier.weight(1f),
                        ) { update(index) { e -> e.copy(reps = it) } }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        SmallNumberField(
                            label = "Rest (s)", value = line.restSeconds.toString(), tag = "workout.editor.rest",
                            modifier = Modifier.weight(1f),
                        ) { update(index) { e -> e.copy(restSeconds = it.toIntOrNull()?.coerceIn(0, 600) ?: e.restSeconds) } }
                        SmallTextField(
                            label = "Weight (${unit.display})",
                            value = line.weight?.let { formatTarget(it) } ?: "",
                            tag = "workout.editor.weight",
                            decimal = true,
                            modifier = Modifier.weight(1f),
                        ) { raw ->
                            update(index) { e -> e.copy(weight = raw.trim().replace(',', '.').toDoubleOrNull()) }
                        }
                    }
                }
            }
            item {
                OutlinedButton(
                    onClick = onAddExercise,
                    modifier = Modifier.fillMaxWidth().testTag("workout.editor.addExercise"),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null)
                    Text("  Add exercise")
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

// MARK: - Custom exercise editor

/**
 * Create a custom exercise (name + category + equipment level). Feeds [WorkoutCustomExercise], which
 * the root already merges into the browse list and the picker. Returns the assembled entity via
 * [onSave].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ExerciseEditorScreen(
    onSave: (WorkoutCustomExercise) -> Unit,
    onExit: () -> Unit,
) {
    var name by rememberSaveable { mutableStateOf("") }
    var categoryRaw by rememberSaveable { mutableStateOf(WorkoutCategory.STRENGTH.raw) }
    var levelRaw by rememberSaveable { mutableStateOf(WorkoutLevel.BEGINNER.raw) }
    var equipmentRaw by rememberSaveable { mutableStateOf<String?>(null) }

    ModuleScaffold(
        title = "New exercise",
        onExit = onExit,
        actions = {
            TextButton(
                onClick = {
                    onSave(
                        WorkoutCustomExercise(
                            name = name.trim(),
                            categoryRaw = categoryRaw,
                            levelRaw = levelRaw,
                            equipmentRaw = equipmentRaw,
                        )
                    )
                },
                enabled = name.isNotBlank(),
                modifier = Modifier.testTag("workout.customEditor.save"),
            ) { Text("Save") }
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }
            item {
                OutlinedTextField(
                    value = name, onValueChange = { name = it },
                    label = { Text("Name") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("workout.customEditor.name"),
                )
            }
            item { ChipGroup("Category", WorkoutCategory.entries.map { it.raw to it.display }, categoryRaw) { categoryRaw = it } }
            item { ChipGroup("Level", WorkoutLevel.entries.map { it.raw to it.display }, levelRaw) { levelRaw = it } }
            item {
                ChipGroup(
                    "Equipment",
                    listOf<Pair<String?, String>>(null to "None") + WorkoutEquipment.entries.map { it.raw to it.display },
                    equipmentRaw,
                ) { equipmentRaw = it }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

// MARK: - Small form helpers

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SmallNumberField(
    label: String, value: String, tag: String, modifier: Modifier = Modifier, onChange: (String) -> Unit,
) = SmallTextField(label, value, tag, modifier = modifier, number = true, onChange = onChange)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SmallTextField(
    label: String, value: String, tag: String, modifier: Modifier = Modifier,
    number: Boolean = false, decimal: Boolean = false, onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value, onValueChange = onChange,
        label = { Text(label) }, singleLine = true,
        keyboardOptions = KeyboardOptions(
            keyboardType = when {
                decimal -> KeyboardType.Decimal
                number -> KeyboardType.Number
                else -> KeyboardType.Text
            },
        ),
        modifier = modifier.testTag(tag),
    )
}

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun <T> ChipGroup(label: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        androidx.compose.foundation.layout.FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            options.forEach { (value, text) ->
                FilterChip(
                    selected = value == selected,
                    onClick = { onSelect(value) },
                    label = { Text(text) },
                )
            }
        }
    }
}

/** Trim a trailing ".0" off a whole-number target weight. */
internal fun formatTarget(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
