package com.snappet.mobile.feature.nutrition

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.SnappetAccents
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

@Composable
fun NutritionRoot(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val dao = container.database.nutritionDao()
    val context = LocalContext.current
    val catalog = remember { FoodCatalog(context) }
    DisposableEffect(Unit) { onDispose { catalog.close() } }

    val accent = SnappetAccents.forModule("nutrition")
    var tab by remember { mutableIntStateOf(0) }
    val goal by dao.goalFlow().collectAsState(null)
    val effectiveGoal = goal ?: NutritionGoal()

    ModuleScaffold(title = "Nutrition", onExit = onExit) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            TabRow(selectedTabIndex = tab) {
                Tab(
                    selected = tab == 0, onClick = { tab = 0 },
                    text = { Text("Today") },
                    modifier = Modifier.testTag("nutrition.tab.today"),
                )
                Tab(
                    selected = tab == 1, onClick = { tab = 1 },
                    text = { Text("History") },
                    modifier = Modifier.testTag("nutrition.tab.history"),
                )
                Tab(
                    selected = tab == 2, onClick = { tab = 2 },
                    text = { Text("Goals") },
                    modifier = Modifier.testTag("nutrition.tab.goals"),
                )
            }
            when (tab) {
                0 -> DiaryTab(dao, effectiveGoal, catalog, accent)
                1 -> HistoryTab(dao, effectiveGoal)
                2 -> GoalsTab(dao, effectiveGoal)
            }
        }
    }
}

@Composable
private fun DiaryTab(
    dao: NutritionDao,
    goal: NutritionGoal,
    catalog: FoodCatalog,
    accent: Color,
) {
    val coroutine = rememberCoroutineScope()
    val startOfDay = remember { startOfDayMillis() }
    val entries by dao.entriesSinceFlow(startOfDay).collectAsState(emptyList())
    var addMeal by remember { mutableStateOf<MealSlot?>(null) }

    val totalKcal    = entries.sumOf { it.kcalPer100g    * it.servingGrams / 100 }
    val totalProtein = entries.sumOf { it.proteinPer100g * it.servingGrams / 100 }
    val totalCarbs   = entries.sumOf { it.carbsPer100g   * it.servingGrams / 100 }
    val totalFat     = entries.sumOf { it.fatPer100g     * it.servingGrams / 100 }
    val budget = NutritionBudget(totalKcal, goal.dailyKcal)

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        item {
            Card(
                modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp)
                    .testTag("nutrition.budgetRing"),
            ) {
                Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        progress = { budget.ringFraction },
                        modifier = Modifier.size(120.dp),
                        color = accent,
                        trackColor = accent.copy(alpha = 0.2f),
                        strokeCap = StrokeCap.Round,
                        strokeWidth = 12.dp,
                    )
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            "${totalKcal.toInt()}",
                            style = MaterialTheme.typography.headlineMedium,
                            fontWeight = FontWeight.Bold,
                        )
                        Text("of ${goal.dailyKcal} kcal", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }

        item {
            Card(
                modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp)
                    .testTag("nutrition.macroBars"),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MacroRow("Protein", totalProtein, goal.proteinG.toDouble(), accent)
                    MacroRow("Carbs",   totalCarbs,   goal.carbsG.toDouble(),   accent)
                    MacroRow("Fat",     totalFat,     goal.fatG.toDouble(),     accent)
                }
            }
        }

        MealSlot.entries.forEach { slot ->
            val slotEntries = entries.filter { it.mealSlot == slot.name }
            item(key = slot.name) {
                Card(
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                        .testTag("nutrition.meal.${slot.name.lowercase()}"),
                ) {
                    Column(Modifier.padding(12.dp)) {
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                slot.name.lowercase().replaceFirstChar { it.uppercaseChar() },
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold,
                            )
                            IconButton(
                                onClick = { addMeal = slot },
                                modifier = Modifier.testTag("nutrition.addFood.${slot.name.lowercase()}"),
                            ) {
                                Icon(Icons.Filled.Add, "Add food")
                            }
                        }
                        slotEntries.forEach { entry ->
                            Row(
                                Modifier.fillMaxWidth().padding(vertical = 2.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(entry.foodName, style = MaterialTheme.typography.bodyMedium)
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        "${(entry.kcalPer100g * entry.servingGrams / 100).toInt()} kcal",
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                    IconButton(
                                        onClick = { coroutine.launch { dao.deleteEntry(entry) } },
                                        modifier = Modifier.size(32.dp),
                                    ) {
                                        Icon(Icons.Filled.Delete, null, Modifier.size(16.dp))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        item {
            Text(
                "Data: Open Food Facts (ODbL) · USDA FDC (Public Domain)",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp, bottom = 16.dp)
                    .testTag("nutrition.attribution"),
            )
        }
    }

    val meal = addMeal
    if (meal != null) {
        AddFoodSheet(
            meal = meal,
            catalog = catalog,
            onDismiss = { addMeal = null },
            onLog = { food, grams ->
                coroutine.launch {
                    dao.insertEntry(
                        FoodLogEntry(
                            foodId         = food.id,
                            foodName       = food.name,
                            brandName      = food.brandName,
                            dataSource     = food.dataSource,
                            mealSlot       = meal.name,
                            servingGrams   = grams,
                            kcalPer100g    = food.kcalPer100g,
                            proteinPer100g = food.proteinPer100g,
                            carbsPer100g   = food.carbsPer100g,
                            fatPer100g     = food.fatPer100g,
                        ),
                    )
                    addMeal = null
                }
            },
        )
    }
}

@Composable
private fun MacroRow(label: String, actual: Double, goal: Double, accent: Color) {
    val fraction = if (goal == 0.0) 0f else (actual / goal).coerceIn(0.0, 1.0).toFloat()
    Column {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, style = MaterialTheme.typography.bodySmall)
            Text("${actual.toInt()}/${goal.toInt()} g", style = MaterialTheme.typography.bodySmall)
        }
        LinearProgressIndicator(
            progress = { fraction },
            modifier = Modifier.fillMaxWidth().height(6.dp).padding(top = 2.dp),
            color = accent,
            trackColor = accent.copy(alpha = 0.2f),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddFoodSheet(
    meal: MealSlot,
    catalog: FoodCatalog,
    onDismiss: () -> Unit,
    onLog: (FoodItem, Double) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(catalog.search("")) }
    var selected by remember { mutableStateOf<FoodItem?>(null) }
    var grams by remember { mutableFloatStateOf(100f) }

    LaunchedEffect(query) { results = catalog.search(query) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        if (selected == null) {
            Column(Modifier.padding(16.dp)) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    label = { Text("Search food") },
                    modifier = Modifier.fillMaxWidth().testTag("nutrition.searchField"),
                    singleLine = true,
                )
                Spacer(Modifier.height(8.dp))
                LazyColumn(Modifier.heightIn(max = 320.dp)) {
                    items(results, key = { it.id }) { food ->
                        ListItem(
                            headlineContent = { Text(food.name) },
                            supportingContent = { Text("${food.kcalPer100g.toInt()} kcal / 100 g") },
                            modifier = Modifier.testTag("nutrition.foodResult")
                                .clickable { selected = food },
                        )
                    }
                }
            }
        } else {
            val food = selected!!
            Column(Modifier.padding(16.dp)) {
                Text(food.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                if (food.brandName.isNotBlank()) {
                    Text(
                        food.brandName,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.height(12.dp))
                Text("Serving: ${grams.toInt()} g", style = MaterialTheme.typography.bodyMedium)
                Slider(
                    value = grams,
                    onValueChange = { grams = it },
                    valueRange = 5f..500f,
                    modifier = Modifier.fillMaxWidth(),
                )
                val kcal    = food.kcalPer100g    * grams / 100
                val protein = food.proteinPer100g * grams / 100
                val carbs   = food.carbsPer100g   * grams / 100
                val fat     = food.fatPer100g     * grams / 100
                Text(
                    "${kcal.toInt()} kcal · P ${protein.toInt()} g · C ${carbs.toInt()} g · F ${fat.toInt()} g",
                    style = MaterialTheme.typography.bodySmall,
                )
                Spacer(Modifier.height(12.dp))
                Button(
                    onClick = { onLog(food, grams.toDouble()) },
                    modifier = Modifier.fillMaxWidth().testTag("nutrition.addToDiary"),
                ) {
                    Text("Add to ${meal.name.lowercase().replaceFirstChar { it.uppercaseChar() }}")
                }
            }
        }
    }
}

@Composable
private fun HistoryTab(dao: NutritionDao, goal: NutritionGoal) {
    val sevenDaysAgo = remember { startOfDayMillis() - 7L * 24 * 3_600_000 }
    val entries by dao.entriesSinceFlow(sevenDaysAgo).collectAsState(emptyList())
    val sdf = remember { SimpleDateFormat("EEE d MMM", Locale.getDefault()) }
    val byDay = entries.groupBy { it.loggedAt / 86_400_000 * 86_400_000 }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 8.dp)
            .testTag("nutrition.history"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item { Text("Last 7 Days", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        byDay.entries.sortedByDescending { it.key }.forEach { (dayMillis, dayEntries) ->
            item(key = dayMillis) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        val kcal = dayEntries.sumOf { it.kcalPer100g * it.servingGrams / 100 }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text(
                                sdf.format(Date(dayMillis)),
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text("${kcal.toInt()} kcal", style = MaterialTheme.typography.bodyMedium)
                        }
                        LinearProgressIndicator(
                            progress = { (kcal / goal.dailyKcal).coerceIn(0.0, 1.0).toFloat() },
                            modifier = Modifier.fillMaxWidth().height(4.dp).padding(top = 4.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun GoalsTab(dao: NutritionDao, goal: NutritionGoal) {
    val coroutine = rememberCoroutineScope()
    var kcal    by remember(goal) { mutableFloatStateOf(goal.dailyKcal.toFloat()) }
    var protein by remember(goal) { mutableFloatStateOf(goal.proteinG.toFloat()) }
    var carbs   by remember(goal) { mutableFloatStateOf(goal.carbsG.toFloat()) }
    var fat     by remember(goal) { mutableFloatStateOf(goal.fatG.toFloat()) }

    Column(
        Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Daily Targets", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        GoalSlider("Calories (kcal)", kcal, 800f..5000f) { kcal = it }
        GoalSlider("Protein (g)",     protein, 20f..400f)  { protein = it }
        GoalSlider("Carbs (g)",       carbs,   20f..600f)  { carbs = it }
        GoalSlider("Fat (g)",         fat,     10f..200f)  { fat = it }
        Button(
            onClick = {
                coroutine.launch {
                    dao.upsertGoal(NutritionGoal(
                        dailyKcal = kcal.toInt(),
                        proteinG  = protein.toInt(),
                        carbsG    = carbs.toInt(),
                        fatG      = fat.toInt(),
                    ))
                }
            },
            modifier = Modifier.fillMaxWidth().testTag("nutrition.saveGoals"),
        ) {
            Text("Save Goals")
        }
    }
}

@Composable
private fun GoalSlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit,
) {
    Column {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            Text(value.toInt().toString(), style = MaterialTheme.typography.bodyMedium)
        }
        Slider(value = value, onValueChange = onChange, valueRange = range, modifier = Modifier.fillMaxWidth())
    }
}

private fun startOfDayMillis(): Long {
    val cal = Calendar.getInstance()
    cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
    cal.set(Calendar.SECOND, 0);      cal.set(Calendar.MILLISECOND, 0)
    return cal.timeInMillis
}
