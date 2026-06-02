package com.snappet.mobile.feature.budget

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Total spend for one calendar month — the unit the trend chart plots. */
data class MonthlySpend(val monthStart: Long, val total: Double) {
    /** A short axis label, e.g. "May". */
    val shortLabel: String get() = monthFmt.format(Date(monthStart))
}

private val monthFmt = SimpleDateFormat("MMM", Locale.getDefault())

/**
 * Pure aggregation for the trend chart: total spend per month for the last [count] months up to and
 * including the month containing [now], oldest → newest. Mirrors iOS `SpendTrend.monthlyTotals`.
 */
object SpendTrend {
    fun monthlyTotals(
        transactions: List<BudgetTransaction>,
        count: Int = 6,
        now: Long = System.currentTimeMillis(),
    ): List<MonthlySpend> {
        val thisMonth = MonthScope.forAnchor(now)
        val months = (count - 1 downTo 0).map { offset ->
            var scope = thisMonth
            repeat(offset) { scope = scope.previous() }
            scope
        }
        return months.map { scope ->
            val total = transactions.filter { scope.contains(it.date) }.sumOf { it.amount }
            MonthlySpend(scope.start, total)
        }
    }
}

/**
 * A 6-month spending-trend bar chart screen. Back returns to the Budget root. Aggregation happens in
 * [SpendTrend]. Mirrors iOS `BudgetTrendsView`.
 */
@Composable
fun BudgetTrendsScreen(transactions: List<BudgetTransaction>, onExit: () -> Unit) {
    val totals = SpendTrend.monthlyTotals(transactions)
    val hasSpend = totals.any { it.total > 0 }

    ModuleScaffold(title = "Trends", onExit = onExit) { padding ->
        if (!hasSpend) {
            Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("No spending yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        "Log some transactions to see your 6-month trend.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                // Still tag a node so the screen is identifiable even when empty.
                Box(Modifier.testTag("budget.trendsChart"))
            }
        } else {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Spending — last 6 months", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                TrendsBarChart(totals)
            }
        }
    }
}

@Composable
private fun TrendsBarChart(totals: List<MonthlySpend>) {
    val maxTotal = (totals.maxOfOrNull { it.total } ?: 0.0).coerceAtLeast(1.0)
    val reduceMotion = LocalReduceMotion.current
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val grow by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "budgetTrendsGrow",
    )
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(16.dp))
            .padding(16.dp)
            .testTag("budget.trendsChart"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Canvas(Modifier.fillMaxWidth().height(220.dp)) {
            val n = totals.size
            val gap = size.width * 0.03f
            val barW = (size.width - gap * (n + 1)) / n
            totals.forEachIndexed { i, m ->
                val h = size.height * (m.total / maxTotal).toFloat() * grow
                val x = gap + i * (barW + gap)
                drawRoundRect(
                    color = SnappetAccents.Azure,
                    topLeft = Offset(x, size.height - h),
                    size = Size(barW, h),
                    cornerRadius = CornerRadius(8f, 8f),
                )
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            totals.forEach { m ->
                Text(m.shortLabel, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
