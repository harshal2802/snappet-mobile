package com.snappet.mobile.feature.expense

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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import com.snappet.mobile.core.SnappetCore
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

private val Green = SnappetAccents.Leaf
private val Red = SnappetAccents.Tomato

/**
 * Root entry for the Split Expenses mini-app. Shows a list of expense groups; tapping one drills
 * into its detail (balances, settle-up plan, expenses) via local-state navigation (no NavHost).
 * Mirrors the iOS `ExpenseRootView` + `ExpenseGroupView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExpenseRoot(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val dao = container.database.expenseDao()
    val core = container.core
    val scope = rememberCoroutineScope()

    val groups by dao.groupsFlow().collectAsState(initial = emptyList())
    val expenses by dao.expensesFlow().collectAsState(initial = emptyList())

    var selectedGroupId by remember { mutableStateOf<String?>(null) }
    var showNewGroup by remember { mutableStateOf(false) }

    val selectedGroup = groups.firstOrNull { it.groupId == selectedGroupId }

    if (selectedGroup != null) {
        GroupDetail(
            group = selectedGroup,
            expenses = expenses.filter { it.groupId == selectedGroup.groupId },
            dao = dao,
            core = core,
            scope = scope,
            onExit = { selectedGroupId = null },
        )
    } else {
        ModuleScaffold(
            title = "Split Expenses",
            onExit = onExit,
            actions = {
                IconButton(onClick = { showNewGroup = true }, modifier = Modifier.testTag("expense.newGroup")) {
                    Icon(Icons.Filled.Add, contentDescription = "New group")
                }
            },
        ) { padding ->
            if (groups.isEmpty()) {
                EmptyGroups(padding) { showNewGroup = true }
            } else {
                GroupList(padding, groups) { selectedGroupId = it.groupId }
            }
        }
    }

    if (showNewGroup) {
        ModalBottomSheet(onDismissRequest = { showNewGroup = false }, sheetState = rememberModalBottomSheetState()) {
            NewGroupSheet(existing = null) { name, participants ->
                showNewGroup = false
                scope.launch {
                    dao.insertGroup(
                        ExpenseGroup(
                            name = name,
                            participantsRaw = ExpenseGroup.joinParticipants(participants),
                            createdAt = System.currentTimeMillis(),
                        )
                    )
                    core.log("expense", "group", "Created group: $name")
                }
            }
        }
    }
}

@Composable
private fun EmptyGroups(padding: PaddingValues, onAdd: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Filled.Group, contentDescription = null, tint = Green, modifier = Modifier.size(48.dp))
            Text("No groups yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "Tap + to create a group and start splitting expenses.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun GroupList(padding: PaddingValues, groups: List<ExpenseGroup>, onOpen: (ExpenseGroup) -> Unit) {
    LazyColumn(
        Modifier.fillMaxSize().padding(padding).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(groups, key = { it.groupId }) { group ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable { onOpen(group) }
                    .padding(16.dp)
                    .testTag("expenseGroupRow"),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(group.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                val count = group.participants.size
                val people = if (count == 1) "person" else "people"
                Text(
                    "$count $people · ${group.participants.joinToString(", ")}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * Group detail: per-participant balances, the greedy settle-up plan, and the expense list. A
 * `expense.groupActions` overflow menu opens "New expense" / "Settle up". Tapping an expense row
 * (its title) opens an edit sheet. Its back arrow returns to the group list. Mirrors iOS
 * `ExpenseGroupView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GroupDetail(
    group: ExpenseGroup,
    expenses: List<ExpenseRecord>,
    dao: ExpenseDao,
    core: SnappetCore,
    scope: CoroutineScope,
    onExit: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    var showNewExpense by remember { mutableStateOf(false) }
    var showSettle by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<ExpenseRecord?>(null) }

    val balances = SettleUp.balances(group.participants, expenses)
    val transfers = SettleUp.transfers(balances)

    ModuleScaffold(
        title = group.name,
        onExit = onExit,
        actions = {
            Box {
                IconButton(onClick = { menuOpen = true }, modifier = Modifier.testTag("expense.groupActions")) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "Group actions")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("New expense") },
                        onClick = { menuOpen = false; showNewExpense = true },
                        modifier = Modifier.testTag("expense.newExpense"),
                    )
                    DropdownMenuItem(
                        text = { Text("Settle up") },
                        onClick = { menuOpen = false; showSettle = true },
                        modifier = Modifier.testTag("expense.settle"),
                    )
                }
            }
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (expenses.isEmpty()) {
                item {
                    Text(
                        "No expenses yet. Use the menu to add the group's first expense.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                item { SectionHeader("Balances") }
                items(balances, key = { it.name }) { balance ->
                    BalanceRow(name = balance.name, net = balance.net)
                }

                item { SectionHeader("Settle Up") }
                if (transfers.isEmpty()) {
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = Green)
                            Text("All settled up", color = Green)
                        }
                    }
                } else {
                    items(transfers, key = { "${it.debtor}->${it.creditor}" }) { t ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("${t.debtor} owes ${t.creditor}", modifier = Modifier.weight(1f))
                            Text(money(t.amount), fontWeight = FontWeight.SemiBold)
                        }
                    }
                }

                item { SectionHeader("Expenses") }
                items(expenses, key = { it.id }) { expense ->
                    ExpenseRow(expense) { editing = expense }
                }
            }
        }
    }

    if (showNewExpense) {
        ModalBottomSheet(onDismissRequest = { showNewExpense = false }, sheetState = rememberModalBottomSheetState()) {
            NewExpenseSheet(group = group, record = null) { title, amount, payer, split ->
                showNewExpense = false
                scope.launch {
                    dao.insertExpense(
                        ExpenseRecord(
                            groupId = group.groupId,
                            title = title,
                            amount = amount,
                            payer = payer,
                            participantsRaw = ExpenseRecord.joinParticipants(split),
                            date = System.currentTimeMillis(),
                        )
                    )
                    core.log("expense", "expense", "Added ${money(amount)} expense", amount)
                }
            }
        }
    }

    editing?.let { record ->
        ModalBottomSheet(onDismissRequest = { editing = null }, sheetState = rememberModalBottomSheetState()) {
            NewExpenseSheet(group = group, record = record) { title, amount, payer, split ->
                editing = null
                scope.launch {
                    dao.updateExpense(
                        record.copy(
                            title = title,
                            amount = amount,
                            payer = payer,
                            participantsRaw = ExpenseRecord.joinParticipants(split),
                        )
                    )
                    core.log("expense", "expense", "Edited ${money(amount)} expense", amount)
                }
            }
        }
    }

    if (showSettle) {
        ModalBottomSheet(onDismissRequest = { showSettle = false }, sheetState = rememberModalBottomSheetState()) {
            RecordSettlementSheet(group = group) { payer, recipient, amount ->
                showSettle = false
                scope.launch {
                    dao.insertExpense(
                        ExpenseRecord(
                            groupId = group.groupId,
                            title = "$payer → $recipient",
                            amount = amount,
                            payer = payer,
                            participantsRaw = ExpenseRecord.joinParticipants(listOf(recipient)),
                            date = System.currentTimeMillis(),
                            isSettlement = true,
                        )
                    )
                    core.log("expense", "settle", "$payer paid $recipient ${money(amount)}", amount)
                }
            }
        }
    }
}

@Composable
private fun BalanceRow(name: String, net: Double) {
    val reduceMotion = LocalReduceMotion.current
    val targetColor = when {
        net > 0.005 -> Green
        net < -0.005 -> Red
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val color by animateColorAsState(
        targetValue = targetColor,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "balanceColor.$name",
    )
    val animatedNet by animateFloatAsState(
        targetValue = net.toFloat(),
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "balanceNet.$name",
    )
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(name, modifier = Modifier.weight(1f))
        Text(
            money(animatedNet.toDouble()),
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun ExpenseRow(expense: ExpenseRecord, onTap: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onTap)
            .padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (expense.isSettlement) {
                Icon(Icons.AutoMirrored.Filled.CompareArrows, contentDescription = null, tint = Green, modifier = Modifier.size(18.dp))
            }
            Text(expense.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(money(expense.amount), fontWeight = FontWeight.SemiBold, color = if (expense.isSettlement) Green else MaterialTheme.colorScheme.onSurface)
        }
        Text(
            detailText(expense),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun detailText(expense: ExpenseRecord): String =
    if (expense.isSettlement) {
        val recipient = expense.participants.firstOrNull() ?: "someone"
        "Settlement · ${expense.payer} paid $recipient"
    } else {
        "${expense.payer} paid · split ${expense.participants.size} ways"
    }

/** Currency-style amount, e.g. "$50.00". Plain formatting keeps the settle-up math display simple. */
private fun money(value: Double): String = "$" + String.format("%.2f", value)
