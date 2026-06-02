package com.snappet.mobile.feature.budget

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.PieChart
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import kotlinx.coroutines.launch

private enum class BudgetScreen { ROOT, CATEGORY, TRENDS }

private val Blue = SnappetAccents.Azure
private val Purple = SnappetAccents.Violet
private val Green = SnappetAccents.Leaf
private val OrangeBar = SnappetAccents.Ember
private val RedBar = SnappetAccents.Tomato

/**
 * Root entry for the Budget mini-app. Scoped to a selected month (prev/next stepper); the summary
 * tiles, spend-by-category donut, and per-category progress all reflect that month. Categories are
 * managed via a modal sheet; per-category transactions (with edit) and a 6-month trends chart are
 * separate screens reached via local state. Mirrors iOS `BudgetRootView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BudgetRoot(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val dao = container.database.budgetDao()
    val core = container.core
    val coroutineScope = rememberCoroutineScope()

    val categories by dao.categoriesFlow().collectAsState(initial = emptyList())
    val transactions by dao.transactionsFlow().collectAsState(initial = emptyList())

    var screen by remember { mutableStateOf(BudgetScreen.ROOT) }
    var selectedCategoryId by remember { mutableStateOf<String?>(null) }
    var month by remember { mutableStateOf(MonthScope.current()) }

    var showAddCategory by remember { mutableStateOf(false) }
    var editingCategory by remember { mutableStateOf<BudgetCategory?>(null) }
    var showAddTransaction by remember { mutableStateOf(false) }

    val selectedCategory = categories.firstOrNull { it.categoryId == selectedCategoryId }

    when (screen) {
        BudgetScreen.TRENDS -> BudgetTrendsScreen(transactions = transactions, onExit = { screen = BudgetScreen.ROOT })

        BudgetScreen.CATEGORY -> {
            if (selectedCategory == null) {
                screen = BudgetScreen.ROOT
            } else {
                BudgetCategoryTransactionsScreen(
                    category = selectedCategory,
                    categories = categories,
                    transactions = transactions,
                    scope = month,
                    onEdit = { txn, cat, amount, note ->
                        coroutineScope.launch {
                            dao.updateTransaction(txn.copy(categoryId = cat.categoryId, amount = amount, note = note))
                            core.log("budget", "edit", "Edited ${amount.asCurrency()} on ${cat.name}", amount)
                        }
                    },
                    onExit = { screen = BudgetScreen.ROOT },
                )
            }
        }

        BudgetScreen.ROOT -> ModuleScaffold(
            title = "Budget",
            onExit = onExit,
            actions = {
                var menuOpen by remember { mutableStateOf(false) }
                IconButton(
                    onClick = { menuOpen = true },
                    enabled = categories.isNotEmpty(),
                    modifier = Modifier.testTag("Add"),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = "Add")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Add Transaction") },
                        onClick = { menuOpen = false; showAddTransaction = true },
                        modifier = Modifier.testTag("budget.addTxn"),
                    )
                    DropdownMenuItem(
                        text = { Text("Add Category") },
                        onClick = { menuOpen = false; showAddCategory = true },
                        modifier = Modifier.testTag("budget.addCategory"),
                    )
                }
            },
        ) { padding ->
            if (categories.isEmpty()) {
                EmptyState(padding) { showAddCategory = true }
            } else {
                BudgetContent(
                    padding = padding,
                    categories = categories,
                    transactions = transactions,
                    month = month,
                    onPrevMonth = { month = month.previous() },
                    onNextMonth = { month = month.next() },
                    onOpenTrends = { screen = BudgetScreen.TRENDS },
                    onOpenCategory = { selectedCategoryId = it.categoryId; screen = BudgetScreen.CATEGORY },
                    onEditCategory = { editingCategory = it },
                )
            }
        }
    }

    if (showAddCategory) {
        ModalBottomSheet(onDismissRequest = { showAddCategory = false }, sheetState = rememberModalBottomSheetState()) {
            BudgetCategoryEditor(existing = null) { name, limit ->
                showAddCategory = false
                coroutineScope.launch {
                    dao.insertCategory(BudgetCategory(name = name, monthlyLimit = limit, createdAt = System.currentTimeMillis()))
                    core.log("budget", "category", "Added category: $name (${limit.asCurrency()}/mo)")
                }
            }
        }
    }

    editingCategory?.let { category ->
        ModalBottomSheet(onDismissRequest = { editingCategory = null }, sheetState = rememberModalBottomSheetState()) {
            BudgetCategoryEditor(existing = category) { name, limit ->
                editingCategory = null
                coroutineScope.launch {
                    dao.updateCategory(category.copy(name = name, monthlyLimit = limit))
                }
            }
        }
    }

    if (showAddTransaction) {
        ModalBottomSheet(onDismissRequest = { showAddTransaction = false }, sheetState = rememberModalBottomSheetState()) {
            AddTransactionSheet(categories = categories, existing = null) { category, amount, note ->
                showAddTransaction = false
                coroutineScope.launch {
                    dao.insertTransaction(
                        BudgetTransaction(
                            categoryId = category.categoryId,
                            amount = amount,
                            note = note,
                            date = System.currentTimeMillis(),
                        ),
                    )
                    core.log("budget", "spend", "Spent ${amount.asCurrency()} on ${category.name}", amount)
                }
            }
        }
    }
}

@Composable
private fun EmptyState(padding: PaddingValues, onAdd: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Filled.PieChart, contentDescription = null, tint = Blue, modifier = Modifier.size(48.dp))
            Text("No categories yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "Add a budget category to start tracking your spending.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = onAdd, modifier = Modifier.testTag("budget.addCategory")) {
                Text("Add Category")
            }
        }
    }
}

@Composable
private fun BudgetContent(
    padding: PaddingValues,
    categories: List<BudgetCategory>,
    transactions: List<BudgetTransaction>,
    month: MonthScope,
    onPrevMonth: () -> Unit,
    onNextMonth: () -> Unit,
    onOpenTrends: () -> Unit,
    onOpenCategory: (BudgetCategory) -> Unit,
    onEditCategory: (BudgetCategory) -> Unit,
) {
    val monthTxns = transactions.filter { month.contains(it.date) }
    fun spent(category: BudgetCategory) =
        monthTxns.filter { it.categoryId == category.categoryId }.sumOf { it.amount }

    val totalLimit = categories.sumOf { it.monthlyLimit }
    val totalSpent = monthTxns.sumOf { it.amount }
    val remaining = totalLimit - totalSpent
    val slices = categories.mapNotNull { c ->
        val amt = spent(c)
        if (amt > 0) CategorySpend(c.name, amt) else null
    }

    LazyColumn(
        Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { MonthHeader(month = month, onPrev = onPrevMonth, onNext = onNextMonth) }
        item { SummaryTiles(totalLimit = totalLimit, totalSpent = totalSpent, remaining = remaining) }
        item { TrendsButton(onClick = onOpenTrends) }
        if (totalSpent > 0) {
            item { SpendByCategoryChart(slices = slices, periodLabel = month.label) }
        }
        item {
            Text("Categories", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
        items(categories, key = { it.categoryId }) { category ->
            CategoryRow(
                name = category.name,
                spent = spent(category),
                limit = category.monthlyLimit,
                onClick = { onOpenCategory(category) },
                onLongClick = { onEditCategory(category) },
            )
        }
    }
}

@Composable
private fun MonthHeader(month: MonthScope, onPrev: () -> Unit, onNext: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onPrev, modifier = Modifier.testTag("budget.prevMonth")) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "Previous month")
        }
        Text(
            month.label,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f).testTag("budget.monthLabel"),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        IconButton(
            onClick = onNext,
            enabled = !month.isCurrent,
            modifier = Modifier.testTag("budget.nextMonth"),
        ) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "Next month")
        }
    }
}

@Composable
private fun SummaryTiles(totalLimit: Double, totalSpent: Double, remaining: Double) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Tile(totalLimit, "Budget", Blue, Modifier.weight(1f).testTag("budget.total"))
        Tile(totalSpent, "Spent", Purple, Modifier.weight(1f).testTag("budget.spent"))
        Tile(remaining, "Remaining", if (remaining < 0) RedBar else Green, Modifier.weight(1f).testTag("budget.remaining"))
    }
}

@Composable
private fun Tile(amount: Double, label: String, tint: Color, modifier: Modifier = Modifier) {
    val reduceMotion = LocalReduceMotion.current
    val animatedAmount by animateFloatAsState(
        targetValue = amount.toFloat(),
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "budgetTile.$label",
    )
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(animatedAmount.toDouble().asCurrency(), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = tint, maxLines = 1)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun TrendsButton(onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .padding(16.dp)
            .testTag("budget.trends"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.BarChart, contentDescription = null, tint = Blue)
        Text("6-month trends", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun CategoryRow(name: String, spent: Double, limit: Double, onClick: () -> Unit, onLongClick: () -> Unit) {
    val fraction = when {
        limit > 0 -> (spent / limit).coerceIn(0.0, 1.0)
        spent > 0 -> 1.0
        else -> 0.0
    }
    val isOver = limit > 0 && spent > limit
    val targetBarTint = when {
        isOver -> RedBar
        fraction >= 0.85 -> OrangeBar
        else -> Blue
    }
    val reduceMotion = LocalReduceMotion.current
    val barTint by animateColorAsState(
        targetValue = targetBarTint,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "budgetBarColor.$name",
    )
    val animatedFraction by animateFloatAsState(
        targetValue = fraction.toFloat(),
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "budgetBarFraction.$name",
    )
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(16.dp)
            .testTag("budget.category.$name"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(
                "${spent.asCurrency()} / ${limit.asCurrency()}",
                style = MaterialTheme.typography.bodyMedium,
                color = if (isOver) RedBar else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        LinearProgressIndicator(
            progress = { animatedFraction },
            modifier = Modifier.fillMaxWidth(),
            color = barTint,
        )
        if (isOver) {
            Text(
                "Over by ${(spent - limit).asCurrency()}",
                style = MaterialTheme.typography.labelSmall,
                color = RedBar,
            )
        }
    }
}
